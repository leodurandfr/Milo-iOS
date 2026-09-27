import CoreGraphics
import Foundation
import ImageIO

/// L'identifiant de piste des cartes : `<source>:<titre>`.
///
/// Milō l'écrit de son côté (`payloads.build_attributes`), l'app du sien
/// (`MiloNowPlayingBridge.buildAttributes`), et l'extension en relit la source
/// pour adresser chaque commande. C'est désormais le **seul** lien entre un
/// bouton et la source qui le reçoit — d'où une seule définition, testée.
enum MiloTrackID {
    static func make(source: String, title: String) -> String {
        source + ":" + title
    }

    /// La source que l'identifiant nomme ; `nil` pour `none`, qui ne reçoit
    /// aucune commande, et pour un identifiant sans préfixe.
    static func source(of id: String) -> String? {
        guard let separator = id.firstIndex(of: ":"), separator > id.startIndex else { return nil }
        let source = String(id[id.startIndex..<separator])
        return source == "none" ? nil : source
    }
}

/// Ce que l'écran verrouillé renvoie vers Milō.
///
/// Tout part en HTTP sur le LAN. APNs ne porte que l'état descendant : rien de
/// ce qui suit n'emprunte Internet, et rien n'a besoin que Milō soit joignable
/// de l'extérieur.
extension MiloAPIClient {

    enum TransportCommand {
        case play, pause, playPause, next, previous

        /// Chaque source a sa propre table de commandes, et la radio ne partage
        /// pas celle des autres pour la lecture : lui envoyer `pause` ou
        /// `resume` la laissait inerte, puisqu'une commande inconnue est
        /// simplement refusée.
        ///
        /// Un flux ne se met pas en pause, il s'arrête : mettre `stop` derrière
        /// le bouton pause est ce que l'appareil fait déjà de son côté, et la
        /// reprise relance la station.
        ///
        /// `next` et `prev`, en revanche, portent désormais le même nom qu'aux
        /// autres sources : Milō les accepte en radio. Ce n'est pas un changement
        /// de piste — un flux live n'en a pas — mais un saut dans la liste des
        /// stations favorites, que l'appareil fait boucler dans les deux sens.
        func name(forSource source: String) -> String? {
            let isRadio = source == "radio"
            switch self {
            case .play: return isRadio ? "resume_playback" : "resume"
            case .pause: return isRadio ? "stop" : "pause"
            // Seul `playpause` n'a pas d'équivalent en radio.
            case .playPause: return isRadio ? nil : "playpause"
            case .next: return "next"
            case .previous: return "prev"
            }
        }

        /// Rejouer cette commande donne-t-il le même résultat que la jouer une
        /// fois ?
        ///
        /// La question se pose parce qu'un délai dépassé ne dit pas que Milō n'a
        /// rien fait : la requête a pu aboutir et seule la réponse se perdre. Un
        /// `resume_playback` rejoué laisse la lecture en cours ; un `next`
        /// rejoué saute deux stations, et l'utilisateur n'a appuyé qu'une fois.
        var isIdempotent: Bool {
            switch self {
            case .play, .pause: return true
            case .playPause, .next, .previous: return false
            }
        }
    }

    /// Ce que l'écran verrouillé envoie à Milō : une commande de transport, un
    /// déplacement absolu de la tête de lecture, ou un saut relatif.
    ///
    /// Un seul type, pour que le nom qu'active un bouton (`name(forSource:)`,
    /// comparé à `controls`) et le nom qui part sur le réseau (`body`) ne
    /// puissent pas diverger.
    enum ControlCommand {
        case transport(TransportCommand)
        /// Milō attend des millisecondes ; le système, lui, raisonne en secondes.
        case seek(to: TimeInterval)
        /// Signé : les boutons −15 / +30 du podcast.
        case skip(by: TimeInterval)

        /// Les noms de `seek` et `skip` ne dépendent ni de la source ni de la
        /// valeur : l'extension les demande sans fabriquer de commande.
        static let seekName = "seek"
        static let skipName = "skip"

        /// Le nom exact que Milō donne à cette commande pour `source` — celui
        /// que `controls` liste. `nil` : elle n'a pas d'équivalent là.
        func name(forSource source: String) -> String? {
            switch self {
            case .transport(let command): return command.name(forSource: source)
            case .seek: return Self.seekName
            case .skip: return Self.skipName
            }
        }

        /// `nil` aussi pour une valeur non finie : `Int(.nan * 1000)` fait
        /// planter le processus, et `JSONSerialization` lève une exception
        /// Objective-C sur un `Double` infini.
        fileprivate func body(forSource source: String) -> [String: Any]? {
            guard let name = name(forSource: source) else { return nil }
            switch self {
            case .transport:
                return ["command": name]
            case .seek(let position):
                guard position.isFinite else { return nil }
                return ["command": name, "data": ["position_ms": Int(position * 1000)]]
            case .skip(let seconds):
                guard seconds.isFinite else { return nil }
                return ["command": name, "data": ["seconds": seconds]]
            }
        }

        /// Rejouer après un délai dépassé donne-t-il le même résultat ?
        ///
        /// Un `seek` porte une position absolue : le rejouer vise le même point.
        /// Un `skip` est relatif, comme Milō l'attend — deux appuis rapprochés
        /// s'additionnent là où un `seek` calculé depuis le dernier ancrage
        /// viserait deux fois la même seconde — et un +30 dont seule la réponse
        /// s'est perdue ferait donc sauter 60 s pour un seul appui.
        fileprivate var isIdempotent: Bool {
            switch self {
            case .transport(let command): return command.isIdempotent
            case .seek: return true
            case .skip: return false
            }
        }

        fileprivate func label(forSource source: String) -> String {
            switch self {
            case .skip(let seconds): return "skip \(Int(seconds))"
            default: return name(forSource: source) ?? "\(self)"
            }
        }
    }

    /// Délai d'une requête partie d'un rappel de commande.
    ///
    /// Sous les trois secondes que le système accorde, pour qu'un échec soit
    /// *consigné* avant que le processus ne meure plutôt que de disparaître
    /// avec lui. Ce n'est pas une marge de confort : c'est la différence entre
    /// une trace et un silence.
    static let commandTimeout: TimeInterval = 2.5

    /// Envoie une commande à la source qui la reçoit.
    ///
    /// `/api/audio/control/{source}` s'adresse à une source précise : il n'existe
    /// pas de « commande au système ». **La source vient de l'appelant, jamais
    /// d'une relecture de `/api/audio/state`.** Relire la faisait échouer :
    /// `mediaremoted` accorde trois secondes à un rappel de commande (mesuré le
    /// 19/09/2026 — `Completed command (3.0s)`), et quand la résolution mDNS
    /// partait sur la mauvaise interface cet aller-retour consommait tout le
    /// budget. Il était devenu un repli pour une carte qui ne nommait pas sa
    /// source ; depuis que chacune la porte (`MiloTrackID`), et qu'un bouton
    /// n'est actif que si `controls` liste sa commande, ce repli n'était plus
    /// jamais atteint, et il a été retiré le 25/09/2026.
    ///
    /// Une unité qui refuse la commande répond HTTP 400 : un refus propre, et
    /// consigné — un bouton qui ne fait rien ne disait pas s'il avait été
    /// refusé, s'il avait expiré, ou s'il n'était jamais parti.
    static func fire(_ command: ControlCommand, source: String?) async {
        guard let source else {
            noteCommand("\(command) : aucune source connue")
            return
        }
        guard let body = command.body(forSource: source) else {
            noteCommand("\(command) : sans équivalent en \(source)")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            noteCommand("\(command) → \(source) : corps illisible")
            return
        }
        await sendControl(source: source, body: data, label: command.label(forSource: source),
                          retryable: command.isIdempotent)
    }

    /// L'envoi lui-même, tracé à l'entrée comme à la sortie.
    ///
    /// Tracer seulement le succès ne prouve rien : c'est ce qui a fait conclure
    /// deux fois « la fermeture n'est jamais appelée » alors qu'elle l'était et
    /// mourait en route.
    private static func sendControl(source: String, body: Data, label: String,
                                    retryable: Bool) async {
        let timeout = commandTimeout
        guard let url = URL(string: baseURL() + "/api/audio/control/\(source)") else {
            noteCommand("\(label) → \(source) : URL inconstructible")
            return
        }
        noteCommand("\(label) → \(source) : envoi")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // La requête est faite ici plutôt que par `post(path:)`, qui jette la
        // réponse : un 400 — le refus qu'une unité oppose à une commande qu'elle
        // ne connaît pas — y devenait indiscernable d'un succès, et c'est
        // précisément la distinction pour laquelle cette trace existe. Même
        // raison que dans `writeClientVolume`.
        // Deux essais courts plutôt qu'un long — quand c'est possible et licite.
        //
        // L'échec mesuré n'est pas un refus : c'est une connexion qui n'aboutit
        // jamais et consomme tout le délai — zéro chemin `ready` à 19:39:21,
        // puis un chemin qui passe à 19:40:35 sans rien changer d'autre. Un
        // second tirage est donc exactement ce qui peut le sauver.
        //
        // Deux conditions, chacune pour une raison différente :
        //
        // - **`retryable`**, parce qu'un délai dépassé ne dit pas que Milō n'a
        //   rien fait. La requête a pu aboutir et seule la réponse se perdre :
        //   rejouer un `next` ferait alors sauter deux stations pour un seul
        //   appui. Seules les commandes dont le résultat ne dépend pas du
        //   nombre de fois qu'on les envoie sont rejouées.
        // - **le budget**, parce que deux tentatives trop courtes échouent là
        //   où une seule aboutissait. En dessous du seuil, on garde une seule
        //   tentative longue.
        //
        // Un `HTTP 400` n'est jamais rejoué non plus : c'est le refus d'une
        // source à une commande qu'elle ne connaît pas, et le répéter ne ferait
        // que le répéter plus lentement.
        let minimumPerAttempt: TimeInterval = 1.1
        let attempts = (retryable && timeout >= 2 * minimumPerAttempt) ? 2 : 1
        let each = timeout / Double(attempts)
        for attempt in 1...attempts {
            request.timeoutInterval = each
            do {
                let (data, response) = try await lanData(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let status = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0?["status"] as? String } ?? "?"
                noteCommand("\(label) → \(source) : HTTP \(code) \(status)"
                            + (attempt == 1 ? "" : " (2e essai)"))
                return
            } catch {
                let code = (error as NSError).code
                noteCommand("\(label) → \(source) : réseau \(code) (essai \(attempt)/\(attempts))")
                if attempt == attempts { return }
                // Rien d'autre à faire avant de retenter : la boucle rouvre une
                // connexion, et c'est précisément le nouveau tirage qu'on veut.
                // Une requête concurrente de plus ne ferait que se disputer un
                // budget qui n'en a pas les moyens.
            }
        }
    }

    /// Clé dédiée aux commandes : le journal partagé est un tableau réécrit par
    /// des écrivains concurrents, assez sollicité pour en chasser ce qu'on
    /// cherche avant qu'on le lise.
    private static func noteCommand(_ message: String) {
        UserDefaults(suiteName: appGroupID)?.set(message, forKey: "milo_command_trace")
    }

    /// Applique un niveau de curseur à une enceinte.
    ///
    /// Le curseur donne 0…1, Milō stocke des dB : on refait le chemin que Milō a
    /// fait dans l'autre sens, avec les mêmes bornes. Écriture **absolue** — un
    /// delta serait une lecture-modification-écriture en course contre l'encodeur
    /// rotatif de l'appareil et son propre écran, ce que ces routes existent
    /// précisément pour éviter.
    ///
    /// L'envoi est différé, pas immédiat. Pendant un glissement iOS tire des
    /// rafales — mesuré : jusqu'à trois enceintes par rafale, plusieurs rafales
    /// par seconde, et **pas toujours les mêmes enceintes**. Envoyer chaque
    /// événement noyait Milō sous des écritures concurrentes dont la dernière
    /// oubliait une enceinte, qui restait alors au niveau d'avant et cassait
    /// l'équilibre entre les pièces. Ne garder que la dernière valeur par
    /// enceinte suffit, et c'est la seule qui décrive l'intention du geste.
    ///
    /// Différé, mais **attendu** : voir `VolumeWriter.write`. Rendre la main
    /// avant que l'écriture soit partie laissait le système terminer l'extension
    /// entre-temps, et c'est justement la dernière valeur du geste qui
    /// disparaissait.
    /// Journal de l'appelant, quand il en a un. L'extension y branche le sien.
    nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// Applique à une enceinte le niveau que le système vient de demander.
    ///
    /// Le niveau reste tel quel, entre 0 et 1. C'est l'échelle du curseur, et
    /// c'est désormais celle que Milō accepte sur `volume` : plus aucune
    /// conversion en décibels sur ce chemin.
    ///
    /// Elle y était, et c'était la panne. Convertir demandait les bornes de
    /// l'opérateur, donc une copie locale de `volume_limits` — et l'extension
    /// ne rafraîchit jamais la sienne. Elle a converti des mois durant sur
    /// -80…-21 pendant que l'appareil tournait sur -78…-8 : un curseur poussé
    /// en haut demandait 13 dB de moins que le haut, un geste de 43 % à 60 %
    /// montait de 3 dB au lieu de 12, il fallait tirer jusqu'à 54 % pour ne
    /// rien changer du tout, et le curseur redescendait tout seul à
    /// l'expiration de la fenêtre optimiste. Milō normalise déjà dans l'autre
    /// sens pour les mêmes raisons — voir `core/push/payloads.py`.
    ///
    /// `snapshot` est ce que nous avons rendu au système pour **toutes** les
    /// enceintes, pas seulement celle-ci : il faut les autres pour reconstituer
    /// la moyenne qu'un geste global vise, y compris quand la rafale ne les a
    /// pas toutes touchées. Sans l'écart de confirmation : voir `baseLevel`.
    ///
    /// Rend `true` si c'est cet appel qui a posé des niveaux optimistes et mené
    /// son écriture à terme, `false` s'il a été absorbé par une rafale plus
    /// récente ou n'avait rien à envoyer : seul le premier a quelque chose de
    /// neuf à faire relire.
    static func applyVolume(mac: String, to target: Float,
                            snapshot: [String: Float]) async -> Bool {
        var levels: [String: Double] = [:]
        for (id, level) in snapshot {
            levels[id.replacingOccurrences(of: ":", with: "")] =
                min(max(Double(level), 0), 1)
        }

        return await VolumeGesture.shared.record(
            mac: mac.replacingOccurrences(of: ":", with: ""),
            target: min(max(Double(target), 0), 1),
            snapshot: levels)
    }

    /// Le niveau global que vise un geste, ou `nil` s'il n'y a rien à viser.
    ///
    /// La moyenne des niveaux **après** le geste : les enceintes touchées à leur
    /// cible, les autres là où elles sont. C'est exactement la définition du
    /// global de Milō — la moyenne de ses clients, vérifiée contre
    /// `/api/volume/state` — et `set_volume_db` décale ensuite tout le monde du
    /// même écart sous `_volume_lock`. On garde donc le niveau voulu **et**
    /// l'équilibre entre les pièces.
    ///
    /// Compléter avec les enceintes non touchées est ce qui rend une rafale
    /// partielle juste au lieu de suspecte : une enceinte qu'elle ne mentionne
    /// pas n'a pas bougé, et sa place dans la moyenne est son niveau actuel.
    ///
    /// Il existe une dilution théorique : pour `m` enceintes citées sur `n`, la
    /// moyenne rend `1+(m/n)(k−1)` au lieu du facteur `k` demandé — à deux sur
    /// trois, un ×1,57 deviendrait ×1,38.
    ///
    /// **Elle ne peut pas se produire ici, et c'est mesuré.** Journal de
    /// l'extension du 22/09/2026, 945 rappels sur 46 minutes et cinq processus,
    /// rejoués à travers la coalescence (180 ms à l'époque) : **315 envois sur 315
    /// portaient les trois enceintes**. Aucune rafale partielle, aucune rafale
    /// d'une seule enceinte. Et ce n'est pas de justesse — iOS émet ses trois
    /// rappels en **2 ms au pire** (médiane 1 ms), la rafale suivante n'arrive
    /// jamais avant **212 ms**. Le seuil, passé de 180 à 30 ms le 27/09/2026,
    /// tombe dans ce vide : quinze fois la rafale la plus longue d'un côté, sept
    /// fois moins que l'écart entre deux rafales de l'autre.
    ///
    /// Ne pas « corriger » ça sans avoir d'abord remesuré ce ratio. Mémoriser
    /// les cibles du geste pour combler les absentes a été essayé deux fois et
    /// retiré deux fois : ça déplace le biais sur les changements de direction
    /// en cours de geste, et le garde-fou qui l'accompagnait détournait un vrai
    /// geste de pièce fait moins de 600 ms après un geste global.
    ///
    /// **On envoie le niveau visé, pas un facteur.** Le système multiplie bien
    /// les niveaux qu'on lui rend par un facteur commun, mais le relire comme un
    /// gain `20·log₁₀(k)` produisait 33 % là où il en demandait 43, et les
    /// extrémités devenaient inatteignables par construction.
    static func globalTarget(touched: [String: Double],
                             snapshot: [String: Double]) -> Double? {
        guard !snapshot.isEmpty else { return nil }
        let sum = snapshot.reduce(0.0) { $0 + (touched[$1.key] ?? $1.value) }
        return min(max(sum / Double(snapshot.count), 0), 1)
    }

    /// Cette rafale est-elle un geste sur le curseur global ?
    ///
    /// Deux enceintes suffisent à trancher : dans le Centre de contrôle, un
    /// doigt ne tient qu'un curseur de pièce à la fois. Une rafale qui en porte
    /// plusieurs vient donc du curseur maître, qui les pousse tous.
    ///
    /// L'ancienne règle exigeait en plus que **toutes** les enceintes soient
    /// touchées et que leurs rapports concordent à 1 %. Les deux échouaient en
    /// silence — les rafales mesurées ne portent pas toujours les mêmes
    /// enceintes, et un rapport n'a plus de sens sous une base quasi nulle — et
    /// chaque échec repassait en écritures par enceinte, qui écartent les pièces
    /// un peu plus à chaque geste. Le prix de la règle courte est qu'un geste
    /// sur un seul curseur pendant qu'un autre bouge serait lu comme global ;
    /// il faudrait deux doigts sur deux poignées à moins de 30 ms d'écart.
    static func isGlobalGesture(touched: Int, deviceCount: Int) -> Bool {
        deviceCount >= 2 && touched >= 2
    }

    /// L'écriture par enceinte, une fois le geste retombé.
    ///
    /// Sur l'échelle du curseur, un niveau ne peut plus déclencher le 400 que
    /// cette route renvoie hors bornes : entre 0 et 1, il tombe dans les bornes
    /// par construction.
    fileprivate static func writeClientVolume(mac plain: String, level: Double) async -> Double? {
        await writeVolume(path: "/api/volume/client/mac/\(plain)",
                          body: ["volume": level],
                          label: "volume \(plain)")
    }

    /// Le volume global, en une requête.
    ///
    /// Milō décale tous les clients du même écart sous `_volume_lock`, ce qui est
    /// le seul endroit où ça peut être atomique. Trois écritures absolues
    /// concurrentes aboutissaient aussi — vérifié — mais chacune posait un
    /// niveau calculé de son côté, et l'équilibre entre les pièces s'écartait à
    /// chaque geste.
    /// Ce qu'a donné un appui envoyé comme « un cran ».
    enum StepOutcome: Equatable {
        /// Milō a appliqué son pas ; le niveau global qui en résulte (0…1).
        case applied(Double)
        /// Appliqué, mais sans niveau dans la réponse (un Milō d'avant le
        /// 27/09) : on attend le push, on n'invente rien.
        case appliedUnknown
        /// Rien n'a abouti.
        case failed
    }

    /// Un appui sur un bouton physique, en « un cran » de Milō.
    ///
    /// Le propriétaire veut qu'un bouton physique fasse exactement le pas des
    /// boutons − / + du widget, et non le 1/16 d'iOS (~4,4 dB sur -78…-8, que les
    /// arrondis affichaient tantôt -4, tantôt -5 ou -6 dB). D'où **le même appel
    /// que le widget** (`fireAdjustVolume`) : `/api/volume/adjust` avec
    /// ±`step_mobile_db`, la valeur que l'app et le widget synchronisent depuis
    /// `/api/settings/bulk`. Même route, même valeur : le même pas, par
    /// construction. Choix de la session du Pi, le 27/09/2026.
    ///
    /// Un delta, et non une écriture absolue : Milō l'applique sous le verrou
    /// du volume, sans rien lire côté iPhone, donc sans course contre le bouton
    /// rotatif. Le curseur, lui, reste une écriture absolue.
    ///
    /// Attendu plutôt que lancé sans suite : c'est l'attente qui garde
    /// l'extension en vie, et la réponse porte le `volume` appliqué (0…1, après
    /// bornage), qu'on affiche aussitôt.
    static func stepVolume(up: Bool) async -> StepOutcome {
        let step = volumeStep()
        guard let url = URL(string: baseURL() + "/api/volume/adjust") else { return .failed }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["delta_db": up ? step : -step, "show_bar": true])

        let defaults = UserDefaults(suiteName: appGroupID)
        guard let (data, response) = try? await lanData(for: request) else {
            defaults?.set("adjust -> réseau", forKey: "milo_volume_write_error")
            return .failed
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            defaults?.set("adjust -> HTTP \(code)", forKey: "milo_volume_write_error")
            return .failed
        }
        defaults?.removeObject(forKey: "milo_volume_write_error")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let level = (json?["volume"] as? NSNumber)?.doubleValue else { return .appliedUnknown }
        return .applied(min(max(level, 0), 1))
    }

    fileprivate static func writeGlobalVolume(level: Double) async -> Double? {
        await writeVolume(path: "/api/volume/global",
                          body: ["volume": level, "show_bar": true],
                          label: "global")
    }

    /// Rend le niveau **appliqué** que Milō renvoie, ou `nil` si rien n'a abouti.
    ///
    /// Le niveau appliqué n'est pas toujours celui demandé : la route globale
    /// borne au lieu de refuser, et une enceinte déjà en butée absorbe moins
    /// que les autres sans que Milō redistribue la différence. Le lire est ce
    /// qui évite de tenir trois secondes un affichage que le son n'a pas suivi.
    private static func writeVolume(path: String, body: [String: Any],
                                    label: String) async -> Double? {
        guard let url = URL(string: baseURL() + path) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Le code est lu, contrairement aux commandes de transport : un curseur
        // qui revient en place sans rien dire est précisément comment
        // l'encodage du MAC est resté invisible.
        let defaults = UserDefaults(suiteName: appGroupID)
        do {
            let (data, response) = try await lanData(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                defaults?.set("\(label) -> HTTP \(code)", forKey: "milo_volume_write_error")
                return nil
            }
            defaults?.removeObject(forKey: "milo_volume_write_error")
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (json?["volume"] as? NSNumber)?.doubleValue
        } catch {
            // Une écriture annulée n'est pas une écriture en panne :
            // `flush?.cancel()` abandonne délibérément celle qu'une rafale plus
            // récente vient de remplacer, et c'est le délestage qui fait que la
            // dernière valeur du geste est la seule à partir. L'enregistrer ici
            // faisait passer ce délestage pour une coupure réseau dans le seul
            // journal qui en parle.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return nil
            }
            defaults?.set("\(label) -> réseau : \(error.localizedDescription)",
                          forKey: "milo_volume_write_error")
            return nil
        }
    }

    // MARK: - Valeur optimiste

    /// Durée pendant laquelle l'affichage préfère ce qu'on vient de demander à ce
    /// que Milō rapporte. Assez longue pour couvrir l'aller-retour et le cycle de
    /// rafraîchissement, assez courte pour qu'un refus du serveur redevienne
    /// visible plutôt que d'être masqué indéfiniment.
    static let optimisticVolumeWindow: TimeInterval = 3

    /// Plancher du niveau qu'on **rend** au système.
    ///
    /// Le curseur maître de la carte n'a pas d'API à lui : iOS le synthétise en
    /// multipliant les niveaux qu'on lui rend par un facteur commun — mesuré le
    /// 22/09/2026, trois enceintes, une rafale à ×1,57 puis ×1,36 puis ×1,27.
    /// Rendu à zéro, il devient **inerte** : `0 × facteur = 0` quelle que soit
    /// la poignée, et plus aucun geste ne peut remonter le son. Ce n'est pas une
    /// course rabotée, c'est une panne franche.
    ///
    /// Un pour cent de la course vaut moins d'un décibel au-dessus du plancher
    /// du limiteur : inaudible, indiscernable de zéro sur un curseur, et il
    /// suffit à garder un facteur exploitable.
    ///
    /// Partagé entre l'extension et l'app : deux définitions du niveau rendu
    /// donneraient deux bases au même curseur selon que l'app est devant ou
    /// endormie, et c'est la base qui décide du facteur.
    static let renderedFloor = 0.01

    static func renderedLevel(_ raw: Double) -> Double {
        min(max(raw, renderedFloor), 1)
    }

    /// Écart entre ce qu'on confirme au système et ce qu'il a demandé.
    ///
    /// Cinq dix-millièmes de la course, soit 0,035 dB sur -78…-8 : inaudible, et
    /// invisible sur un curseur.
    static let acknowledgedOffset = 0.0005

    /// Le niveau à rendre pour une enceinte : ce qu'on vient de demander tant que
    /// c'est frais, sinon ce que Milō rapporte — puis le plancher.
    ///
    /// **Une valeur fraîche n'est jamais rendue telle quelle**, et ce n'est pas du
    /// bruit : c'est ce qui fait suivre le curseur de la carte aux boutons
    /// physiques. Mesuré le 26/09/2026, trois enceintes au même niveau, écran
    /// verrouillé : six appuis à −1/16 arrivent bien, l'extension rend bien
    /// 0,477 → … → 0,165 après chaque push, et le curseur reste à 0,54 — si bien
    /// que le doigt, en le touchant, remonte le son d'un coup à 0,5398643, la
    /// valeur exacte d'avant les appuis. Un changement venu du Mac, lui, le
    /// recale aussitôt.
    ///
    /// Ce qui ne remonte pas, c'est une valeur **égale à celle que le système
    /// vient de demander** : il la tient déjà pour sa copie du modèle, n'y voit
    /// aucun changement, et ne prévient pas la carte. Or la valeur optimiste
    /// *est* la cible demandée. Un écart minuscule suffit à en faire une
    /// nouvelle valeur. Il va vers le haut, et vers le bas seulement là où il
    /// dépasserait 1,0 : l'ordre des niveaux est préservé partout sauf dans ce
    /// dernier demi-millième. Une première version basculait à 0,5 et
    /// intervertissait deux enceintes de part et d'autre.
    ///
    /// Cet écart est **affiché**, jamais **calculé** : l'instantané qui sert à
    /// reconstituer un geste global part de `baseLevel`. Parti du niveau
    /// affiché, `noteShift` l'aurait rangé dans la valeur optimiste, et le rendu
    /// suivant l'aurait ajouté une seconde fois — un écart qui grossit à chaque
    /// rafale pour deux enceintes de part et d'autre de la butée.
    ///
    /// Ce que la panne coûtait en plus de l'affichage : le curseur maître
    /// multiplie les niveaux par (position ÷ position affichée). Une carte restée
    /// en haut pendant que les enceintes étaient descendues à 0,0855 ramenait
    /// toute sa course à 0…0,0855, soit -78…-72 dB — chaque appui vers le haut
    /// ajoutait de moins en moins et plafonnait là (mesuré à 12:30 le même jour).
    ///
    /// Pure, et partagée entre l'extension et l'app : deux définitions du niveau
    /// rendu donneraient deux bases au même curseur.
    ///
    /// **Et l'écart reste quand Milō confirme.** `confirmed` est ce qu'on a demandé
    /// en dernier, même passé la fenêtre optimiste. Tant que Milō rapporte ce
    /// niveau-là, on garde exactement le même rendu : sinon l'expiration de la
    /// fenêtre ferait bouger la valeur de 0,0005 **hors** d'une commande d'iOS,
    /// et iOS pourrait l'adopter comme nouvelle base — ou non, ce n'est pas
    /// mesuré. Un rendu qui ne bouge pas ne pose pas la question. Voir
    /// `GroupVolumeMirror`.
    static func displayedLevel(optimistic: Double?, reported: Double,
                               confirmed: Double? = nil) -> Double {
        guard let level = requestedLevel(optimistic: optimistic, reported: reported,
                                         confirmed: confirmed)
        else { return renderedLevel(reported) }
        let raised = level + acknowledgedOffset
        return renderedLevel(raised <= 1 ? raised : level - acknowledgedOffset)
    }

    /// Le même niveau, sans l'écart de confirmation : celui sur lequel se
    /// calcule un geste. Voir `displayedLevel`.
    static func baseLevel(optimistic: Double?, reported: Double,
                          confirmed: Double? = nil) -> Double {
        renderedLevel(requestedLevel(optimistic: optimistic, reported: reported,
                                     confirmed: confirmed) ?? reported)
    }

    /// Ce que Milō confirme à cet écart près est encore notre demande : sa
    /// normalisation aller-retour ne s'en écarte que de quelques millionièmes,
    /// et l'app lui rend nos niveaux avec l'écart de confirmation (0,0005).
    static let confirmationTolerance = 0.001

    private static func requestedLevel(optimistic: Double?, reported: Double,
                                       confirmed: Double?) -> Double? {
        if let optimistic { return optimistic }
        guard let confirmed, abs(confirmed - reported) <= confirmationTolerance else { return nil }
        return confirmed
    }

    /// Oublie ce qu'on avait promis pour ces enceintes.
    ///
    /// À n'appeler que quand l'écriture a échoué. Sans cela, l'affichage tient
    /// trois secondes pleines un niveau que Milō n'a jamais appliqué — ce que
    /// la lecture du niveau appliqué existe précisément pour éviter, et qui ne
    /// servait à rien tant que le cas « pas de réponse du tout » n'était pas
    /// traité.
    static func forgetOptimistic(macs: [String]) {
        let defaults = UserDefaults(suiteName: appGroupID)
        for mac in macs {
            let plain = mac.replacingOccurrences(of: ":", with: "")
            defaults?.removeObject(forKey: optimisticLevelKey(plain))
            defaults?.removeObject(forKey: optimisticVolumeAtKey(plain))
        }
    }

    /// Pose le niveau optimiste d'une enceinte (MAC déjà sans deux-points).
    ///
    /// Il est posé **avant** l'écriture réseau : la session est rafraîchie en
    /// boucle depuis Milō, et une lecture partie avant que l'écriture atterrisse
    /// repousserait l'ancien niveau — le curseur reculerait sous le doigt, et le
    /// système recalculerait son facteur sur une base périmée.
    static func noteOptimistic(mac plain: String, level: Double) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(min(max(level, 0), 1), forKey: optimisticLevelKey(plain))
        defaults?.set(Date().timeIntervalSince1970, forKey: optimisticVolumeAtKey(plain))
    }

    /// `lvl` et non `vol` : la clé précédente rangeait des décibels. Un -47,8
    /// relu comme un niveau se bornerait à 0, soit trois secondes de silence
    /// affiché par enceinte au premier lancement suivant la mise à jour. Un
    /// nom neuf laisse l'ancienne valeur là où elle est, ignorée.
    static func optimisticLevelKey(_ mac: String) -> String { "milo_opt_lvl_\(mac)" }
    static func optimisticVolumeAtKey(_ mac: String) -> String { "milo_opt_at_\(mac)" }

    /// Le dernier niveau demandé pour cette enceinte, quel que soit son âge :
    /// ce que Milō confirme ensuite se rend à l'identique. Voir `displayedLevel`.
    static func lastRequestedLevel(mac: String) -> Double? {
        let plain = mac.replacingOccurrences(of: ":", with: "")
        return UserDefaults(suiteName: appGroupID)?.object(forKey: optimisticLevelKey(plain)) as? Double
    }

    /// Le niveau qu'on vient de demander pour cette enceinte, s'il est assez
    /// récent pour faire autorité sur ce que Milō rapporte.
    static func optimisticLevel(mac: String) -> Double? {
        let plain = mac.replacingOccurrences(of: ":", with: "")
        let defaults = UserDefaults(suiteName: appGroupID)
        guard let at = defaults?.object(forKey: optimisticVolumeAtKey(plain)) as? Double,
              Date().timeIntervalSince1970 - at < optimisticVolumeWindow,
              let level = defaults?.object(forKey: optimisticLevelKey(plain)) as? Double
        else { return nil }
        return level
    }
}

/// Le volume de groupe qu'iOS tient caché sous le curseur principal de la carte,
/// reconstitué de ce côté pour relire ses demandes.
///
/// **Ce qu'iOS fait, relevé dans `mediaremoted`** (26 et 27/09/2026) : un
/// engagement G sur le curseur principal pose chaque enceinte à
/// `référence × G / plafond`. Le plafond est le max du dernier G engagé et des
/// niveaux adoptés depuis : il ne redescend que par un geste d'iOS. Baisser le
/// son ailleurs (bouton rotatif, dock, Milo-Mac) fait donc tomber le rapport
/// référence/plafond sous 1 pour de bon. Le 26/09 à 20:03, un plafond resté à
/// 0,45 a fait **baisser** le son sur un « + » (0,1214 → 0,0496).
///
/// **Ce qu'iOS adopte, et ce qu'il n'adopte pas** (27/09, 01:21:36 → 01:21:44) :
/// - un niveau rendu **hors** de ses commandes de volume (un push de Milō, un
///   changement fait ailleurs) devient la référence de l'enceinte, et relève le
///   plafond s'il le dépasse ;
/// - un niveau rendu **pendant** une commande — entre l'appel du rappel
///   `onChange` et son retour — est affiché par la carte ≈ 1,07 s après l'appui,
///   mais n'est jamais adopté : la référence reste ce qu'iOS a posé lui-même.
///   Supposer l'inverse a fait lire un « + » comme un « − » à 01:21:41.
///
/// Et la carte calcule un appui depuis ce qu'elle **affiche** : G = affiché ±
/// 1/16, affiché compris l'écart de confirmation de +0,0005.
///
/// On relit donc chaque rafale pour retrouver le G engagé, puis ce que
/// l'utilisateur voulait. Tant qu'iOS est sain, rien ne change. Si iOS recrée
/// son point d'accès sans prévenir (vu le 26/09 sur une installation), la
/// signature « affiché ± 1/16 » d'un appui départage l'état suivi d'un état
/// sain ; un glissement retient l'hypothèse qui garde la continuité du doigt.
///
/// Pur et sans barrière `@available`, pour être testé avec les chiffres relevés.
/// Rangé dans le conteneur partagé par `update` : l'extension change de
/// processus sans arrêt, iOS garde son état.
struct GroupVolumeMirror: Codable, Equatable {

    /// Le plafond d'iOS : le G par lequel il divise.
    var ceiling: Double = 0

    /// Le niveau qu'iOS tient pour base, par enceinte (MAC sans deux-points).
    var reference: [String: Double] = [:]

    /// Ce que la carte affiche, par enceinte : c'est de là qu'un appui part.
    var card: [String: Double] = [:]

    /// Le dernier niveau principal voulu, et quand : l'ancre d'un glissement.
    var lastIntended: Double?
    var lastAt: TimeInterval = 0

    /// Le dernier G engagé par iOS. Pendant ≈ 1,07 s après un appui, c'est lui
    /// que la carte affiche — et d'où iOS calcule l'appui suivant — avant que
    /// notre rendu ne le remplace (27/09, 02:07:44 → 02:07:46 : 0,2451 → 0,1826
    /// → 0,1201 → 0,0576, chaque fois « dernier G − 1/16 »).
    var lastSystemLevel: Double?

    /// La dernière rafale relue était-elle un glissement ? Optionnel pour relire
    /// l'état rangé par une version qui ne le connaissait pas.
    var lastWasSlide: Bool?

    /// De combien, au plus, le plafond suivi peut dépasser celui d'iOS, en
    /// fraction. Nul quand un appui l'a recalé sans ambiguïté. Optionnel pour
    /// la même raison que `lastWasSlide`.
    ///
    /// Quand des niveaux **inégaux** montent au-dessus du plafond, iOS n'adopte
    /// pas forcément le plus haut : le 27/09 à 18:46:44, rendu 0,5274 / 0,5204 /
    /// 0,5274, iOS a pris 0,5204 et le miroir 0,5274 (règle inconnue ; à sa
    /// recréation, 18:42:24, iOS avait pris le plus haut). Et un appui du Centre
    /// de contrôle relu sur ce plafond-là tombe à la fois sur l'exact et sur le
    /// tronqué (0,3756 lu, 0,37 engagé à 18:47:00) : 1,5 % d'écart, que les
    /// glissements gardent. À 1 % de marge fixe, le « + » de 18:49:10 n'était
    /// plus reconnu. Une marge large en permanence, elle, prend un glissement
    /// de ×1,05 pour un appui.
    var slack: Double?

    /// Comment la carte résume des niveaux inégaux. Inconnu tant qu'aucun appui
    /// ne l'a montré : ce n'est pas encore mesuré. Pour des niveaux égaux, la
    /// question ne se pose pas.
    var cardRule: CardRule?

    enum CardRule: String, Codable, CaseIterable {
        case loudest, mean

        func level(_ levels: some Collection<Double>) -> Double {
            guard !levels.isEmpty else { return 0 }
            switch self {
            case .loudest: return levels.max() ?? 0
            case .mean: return levels.reduce(0, +) / Double(levels.count)
            }
        }
    }

    /// Ce qu'une rafale voulait dire.
    struct Reading: Equatable {
        enum Kind: Equatable { case button(up: Bool), slider }
        var kind: Kind
        /// L'hypothèse retenue sur l'état d'iOS, pour la trace.
        var hypothesis: String
        /// Le G qu'iOS a engagé.
        var systemLevel: Double
        /// Le niveau principal voulu, sur l'échelle d'iOS. Pour un bouton, c'est
        /// le repli quand Milō ne sait pas faire « un cran ».
        var intended: Double
        /// La cible corrigée de chaque enceinte de la rafale.
        var targets: [String: Double]
    }

    /// Le pas d'un bouton physique sur une destination externe : 1/16, relevé
    /// sur chaque appui des journaux (0,5349 → 0,5979 → 0,6609).
    static let buttonStep = 1.0 / 16

    /// Combien de temps le dernier G engagé peut encore être l'affiché : la
    /// carte adopte notre rendu ≈ 1,07 s après l'appui ; marge comprise.
    static let systemLevelShownFor: TimeInterval = 1.5

    /// Au-delà, une rafale ouvre un nouveau geste : la rafale suivante d'un
    /// glissement n'arrive jamais avant 212 ms, plus les 30 ms de regroupement.
    static let gestureGap: TimeInterval = 0.8

    /// Un glissement commence sous le doigt, donc près du niveau affiché. Une
    /// lecture qui en partirait plus loin est une hypothèse fausse : on
    /// n'invente pas un saut, on laisse faire iOS.
    static let sliderJump = 0.25

    /// Des niveaux plus proches que ça sont « égaux » : la règle de la carte n'y
    /// change rien.
    static let evenSpread = 0.005

    /// Jusqu'où l'estimation d'un appui exact peut s'écarter d'« affiché ±
    /// 1/16 », en plus de `slack`. Synchronisé avec iOS, le miroir tombe à 1e-6
    /// près.
    static let buttonTolerance = 0.01

    /// Au-delà, `slack` ne veut plus rien dire : le prochain appui tranchera.
    static let maxSlack = 0.1

    /// En dessous, un G engagé est nul : iOS n'y perd pas ses rapports
    /// (0,72207 avant et après le zéro de 18:49:42, le 27/09), le miroir non plus.
    static let silentLevel = 0.0001

    /// Ce qu'iOS vient de lire dans `devices`, tel qu'il l'a reçu (écart de
    /// confirmation compris). `duringCommand` : lu pendant qu'un rappel
    /// `onChange` était en cours — la carte l'affichera, iOS ne l'adoptera pas.
    mutating func observe(_ displayed: [String: Double], duringCommand: Bool) {
        reference = reference.filter { displayed[$0.key] != nil }
        card = card.filter { displayed[$0.key] != nil }
        let unseeded = ceiling <= 0 || reference.isEmpty
        let previousCeiling = ceiling
        var adopted: [Double] = []
        for (id, level) in displayed {
            let previous = card[id]
            card[id] = level
            // Un niveau qui n'a pas bougé n'est pas un changement : iOS n'a
            // rien vu passer, et garde sa référence.
            let changed = previous.map { abs($0 - level) > 0.000_001 } ?? true
            guard unseeded || (changed && !duringCommand) else { continue }
            reference[id] = level
            ceiling = max(ceiling, level)
            adopted.append(level)
        }
        // Un niveau adopté remplace sur la carte le dernier G d'iOS, zéro compris.
        if !unseeded, !adopted.isEmpty { lastSystemLevel = nil }
        // Monté au-dessus du plafond : iOS en a pris un entre le plus bas des
        // niveaux montés et le plus haut. Voir `slack`.
        guard !unseeded, ceiling > previousCeiling, let lowest = adopted.min() else { return }
        let spread = (ceiling - max(previousCeiling, lowest)) / ceiling
        slack = min(lowest > previousCeiling ? spread : max(slack ?? 0, spread), Self.maxSlack)
    }

    /// Un curseur de pièce, dans le Centre de contrôle : iOS pose ce niveau-là
    /// tel quel, la carte l'affiche aussitôt.
    mutating func notePerDevice(_ burst: [String: Double]) {
        for (id, level) in burst {
            reference[id] = level
            card[id] = level
            ceiling = max(ceiling, level)
        }
    }

    /// Relit une rafale du curseur principal. `burst` est ce qu'iOS demande par
    /// enceinte, `shown` ce que nous lui avions rendu, sans l'écart de
    /// confirmation (MAC sans deux-points). `nil` : aucune lecture sûre, on
    /// laisse passer ce qu'iOS demande — le comportement d'avant, jamais pire.
    mutating func interpret(burst: [String: Double], shown: [String: Double],
                            now: TimeInterval) -> Reading? {
        let touched = burst.filter { shown[$0.key] != nil }
        guard !touched.isEmpty, let loudest = shown.values.max(), loudest > 0 else { return nil }
        let even = loudest - (shown.values.min() ?? loudest) <= Self.evenSpread
        let rules: [CardRule] = even ? [.loudest] : cardRule.map { [$0] } ?? CardRule.allCases
        let display = card.merging(shown) { seen, _ in seen }

        struct Hypothesis {
            let name: String
            let reference: [String: Double]
            let level: Double
        }
        func hypothesis(_ name: String, ceiling: Double,
                        reference: [String: Double]) -> Hypothesis? {
            guard ceiling > 0 else { return nil }
            let reference = reference.merging(display) { known, _ in known }
            let levels = touched.compactMap { id, requested -> Double? in
                guard let base = reference[id], base > 0.0001 else { return nil }
                return requested * ceiling / base
            }.sorted()
            guard !levels.isEmpty else { return nil }
            return Hypothesis(name: name, reference: reference,
                              level: min(levels[levels.count / 2], 1))
        }

        let hypotheses = [
            hypothesis("suivie", ceiling: ceiling, reference: reference),
            // iOS a recréé son point d'accès : il repart de ce qu'il affiche.
            hypothesis("saine", ceiling: display.values.max() ?? 0, reference: display),
        ].compactMap { $0 }
        guard !hypotheses.isEmpty else { return nil }

        func clamp(_ level: Double) -> Double { min(max(level, 0), 1) }

        // Un bouton : G vaut l'affiché ± 1/16. Exactement sur l'écran
        // verrouillé, à quatre à six décimales près. **Tronqué au centième**
        // dans le Centre de contrôle : 0,20 → 0,26 → 0,32 → 0,38 → 0,44 puis
        // 0,37, 0,30… pour cinq « + » et cinq « − » (27/09, 02:02:36). La
        // troncature se lit aussi sur l'affiché sans l'écart de confirmation,
        // qui peut faire passer le centième.
        //
        // Un glissement en cours reste un glissement : d'une rafale à l'autre, le
        // doigt peut parcourir 1/16 en 212 ms, et la marge des appuis le prendrait
        // pour un bouton.
        typealias Match = (hypothesis: Hypothesis, rule: CardRule, up: Bool, level: Double, error: Double)
        var matches: [Match] = []
        let margin = slack ?? 0
        // À zéro, la carte garde le 0 d'iOS tant que rien d'autre n'est adopté :
        // un « − » de plus au plancher ne nous rappelle même pas, et le « + »
        // suivant part de 0 (27/09, 20:40:50 → 20:40:57 : engagé 0,0625).
        let recentSystemLevel = lastSystemLevel.flatMap {
            now - lastAt < Self.systemLevelShownFor || $0 <= Self.silentLevel ? $0 : nil
        }
        let sliding = lastWasSlide == true && now - lastAt < Self.gestureGap
        for candidate in hypotheses where !sliding {
            for rule in rules {
                for shownOnCard in [rule.level(display.values), recentSystemLevel].compactMap({ $0 }) {
                for up in [true, false] {
                    let step = up ? Self.buttonStep : -Self.buttonStep
                    let exact = clamp(shownOnCard + step)
                    let truncated = [shownOnCard, shownOnCard - MiloAPIClient.acknowledgedOffset]
                        .map { clamp((($0 + step) * 100).rounded(.down) / 100) }
                    let signatures = [(exact, max(0.0015, (Self.buttonTolerance + margin) * exact))]
                        + truncated.map { ($0, 0.0006 + margin * $0) }
                    for (expected, tolerance) in signatures {
                        let error = abs(candidate.level - expected)
                        guard error <= tolerance else { continue }
                        matches.append((candidate, rule, up, expected, error))
                    }
                }
                }
            }
        }

        let best = matches.min { $0.error < $1.error }
        // Ce qu'un appui laisse d'incertitude : l'écart aux autres signatures
        // qu'il pouvait aussi être.
        let ambiguity = best.map { best in
            matches.map { abs($0.level - best.level) / max(best.level, Self.silentLevel) }.max() ?? 0
        }
        let chosen: Hypothesis
        let systemLevel: Double
        let intended: Double
        let kind: Reading.Kind
        let rule: CardRule
        if let best {
            chosen = best.hypothesis
            systemLevel = best.level
            rule = best.rule
            intended = clamp(rule.level(shown.values)
                             + (best.up ? Self.buttonStep : -Self.buttonStep))
            kind = .button(up: best.up)
            if !even { cardRule = rule }
        } else {
            // Un glissement : sans règle connue pour des niveaux inégaux, on ne
            // sait pas où était la poignée.
            guard let known = even ? .loudest : cardRule else {
                forget(burst: touched, now: now)
                return nil
            }
            rule = known
            let anchor = lastIntended.flatMap { now - lastAt < Self.gestureGap ? $0 : nil }
                ?? rule.level(display.values)
            // L'état suivi d'abord, tant qu'il reste près du doigt. Choisir
            // l'hypothèse la plus proche donnait « saine » dès qu'iOS tenait un
            // rapport un peu sous 1 : la rafale se lisait bien, mais le rapport du
            // miroir retombait à 1, et plus aucun appui n'était reconnu (27/09,
            // 18:49:10). « Saine » ne sert qu'à un point d'accès recréé, où l'état
            // suivi part loin du doigt.
            //
            // Sauf un centième rond, pile : c'est ce que pose le Centre de
            // contrôle, qui saute où le doigt touche le curseur (27/09, 20:40:33 :
            // 0,4600 lu depuis 0,035, que « saine » ramenait à 0,023). Pas une
            // lecture bornée à 1, qui tombe toujours pile.
            func onAHundredth(_ level: Double) -> Bool {
                level < 1 && abs(level * 100 - (level * 100).rounded()) < 0.003
            }
            guard let plausible = hypotheses.first(where: {
                abs($0.level - anchor) <= Self.sliderJump
                    || ($0.name == "suivie" && onAHundredth($0.level))
            }) else {
                forget(burst: touched, now: now)
                return nil
            }
            chosen = plausible
            systemLevel = plausible.level
            intended = clamp(plausible.level)
            kind = .slider
        }

        // Ce que nous montrions, porté au niveau voulu : l'équilibre entre les
        // pièces est gardé, et c'est `globalTarget` qui en fera la moyenne.
        let base = rule.level(shown.values)
        var targets: [String: Double] = [:]
        for id in touched.keys {
            targets[id] = base > 0 ? clamp(shown[id]! * intended / base) : intended
        }

        // iOS vient d'engager `systemLevel` : c'est son nouveau plafond, ce qu'il
        // a posé devient sa référence, et la carte l'affiche aussitôt.
        //
        // Sauf à zéro : iOS y garde ses rapports, et le « + » suivant pose le même
        // rapport × G qu'avant. Un plafond nul faisait adopter au miroir le
        // plancher rendu (0,0100) comme référence ET plafond, un rapport de 1
        // contre 0,72207 chez iOS : les « + » de 18:52:11 → 18:52:15 partaient en
        // glissements.
        var posed = chosen.reference
        for (id, level) in touched {
            posed[id] = level
            card[id] = level
        }
        if systemLevel > Self.silentLevel {
            ceiling = systemLevel
            reference = posed
            if let ambiguity { slack = min(ambiguity, Self.maxSlack) }
        }
        lastIntended = intended
        lastSystemLevel = systemLevel
        lastAt = now
        lastWasSlide = kind == .slider

        return Reading(kind: kind, hypothesis: chosen.name, systemLevel: systemLevel,
                       intended: intended, targets: targets)
    }

    /// Aucune lecture sûre : on repart d'un état sain, avec ce qu'iOS vient de
    /// poser pour référence. Le prochain appui dira si c'était juste.
    private mutating func forget(burst: [String: Double], now: TimeInterval) {
        for (id, level) in burst {
            card[id] = level
        }
        // Une rafale nulle ne dit rien des rapports d'iOS : on garde ceux qu'on a.
        if (burst.values.max() ?? 0) > Self.silentLevel {
            reference.merge(burst) { _, posed in posed }
            ceiling = reference.values.max() ?? 0
        }
        lastIntended = nil
        lastSystemLevel = nil
        lastWasSlide = nil
        lastAt = now
    }
}

extension GroupVolumeMirror {

    static let storeKey = "milo_group_volume_mirror_v2"
    private static let storeLock = NSLock()

    /// Lit, modifie et range l'état, sous verrou : `devices` (fil principal) et
    /// l'envoi des rafales (un acteur) y touchent tous deux, et c'est une
    /// lecture-modification-écriture.
    @discardableResult
    static func update<T>(_ body: (inout GroupVolumeMirror) -> T) -> T {
        storeLock.lock()
        defer { storeLock.unlock() }
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)
        var mirror = defaults?.data(forKey: storeKey)
            .flatMap { try? JSONDecoder().decode(GroupVolumeMirror.self, from: $0) }
            ?? GroupVolumeMirror()
        let result = body(&mirror)
        if let data = try? JSONEncoder().encode(mirror) {
            defaults?.set(data, forKey: storeKey)
        }
        return result
    }

    /// Combien de rappels `onChange` sont en cours dans ce processus. Ce que
    /// `devices` rend pendant ce temps, iOS ne l'adopte pas.
    private static let commandLock = NSLock()
    nonisolated(unsafe) private static var commandsInFlight = 0
    nonisolated(unsafe) private static var lastCommandEnd: TimeInterval = 0

    /// La relecture que déclenche notre écho tombe à quelques millisecondes du
    /// retour du rappel, d'un côté ou de l'autre — 5 ms avant `Completed volume`
    /// le 27/09 à 01:21:39.897, et iOS l'a traitée comme faisant partie de la
    /// commande. Un changement venu d'ailleurs dans cette fenêtre est rare.
    static let commandGrace: TimeInterval = 0.3

    static func beginCommand() {
        commandLock.lock(); commandsInFlight += 1; commandLock.unlock()
    }

    static func endCommand() {
        commandLock.lock()
        commandsInFlight = max(0, commandsInFlight - 1)
        lastCommandEnd = Date().timeIntervalSince1970
        commandLock.unlock()
    }

    static var commandInFlight: Bool {
        commandLock.lock(); defer { commandLock.unlock() }
        return commandsInFlight > 0
            || Date().timeIntervalSince1970 - lastCommandEnd < commandGrace
    }
}

extension GroupVolumeMirror.Reading {
    /// Une ligne de trace : ce qu'iOS a engagé, dans quel état, et ce qui part.
    var summary: String {
        func r(_ level: Double) -> String { String(format: "%.4f", level) }
        let what: String
        switch kind {
        case .button(let up): what = up ? "bouton +" : "bouton −"
        case .slider: what = "glissement"
        }
        return "iOS \(what) (\(hypothesis)) G=\(r(systemLevel)) → voulu \(r(intended))"
    }
}

/// Ne garde que la dernière intention du geste, et décide de sa nature.
///
/// Une seule échéance pour toutes les enceintes, et non plus une par enceinte :
/// c'est ce qui permet de voir une rafale **comme un tout**. Trois rappels
/// portant le même rapport sont un geste sur le curseur global ; un seul rappel
/// est un curseur individuel. Rendus séparément, ils étaient indiscernables.
private actor VolumeGesture {
    static let shared = VolumeGesture()

    /// La dernière cible demandée pour chaque enceinte, sur l'échelle du curseur.
    private var pending: [String: Double] = [:]

    /// Numéro du dernier envoi parti.
    ///
    /// L'acteur est réentrant sur l'await réseau : sans ce numéro, un envoi lent
    /// qui reprend repose les niveaux d'un instantané périmé par-dessus ceux
    /// qu'un envoi plus récent vient d'écrire, et la base rendue au système
    /// recule en plein geste — donc le facteur suivant se calcule sur un niveau
    /// qui n'est plus le bon.
    private var generation: UInt64 = 0

    /// Ce que nous avons rendu au système pour **toutes** les enceintes, dans sa
    /// version la plus récente. Il sert deux fois : à compléter la moyenne d'un
    /// geste global avec les enceintes qu'une rafale n'a pas touchées, et à
    /// répartir le résultat en niveaux optimistes.
    ///
    /// Remplacé, et sans purger `pending` au passage. Les cibles sont des
    /// niveaux absolus, pas des écarts : un instantané plus récent ne les périme
    /// pas. Il ne périme que les niveaux des enceintes restées immobiles,
    /// qu'on veut justement les plus frais possible.
    ///
    /// Ça suffisait tant que rien ne relisait cette base **après** un aller-retour
    /// réseau. Ce n'est plus vrai : la correction post-écriture, elle, s'exécute
    /// de l'autre côté d'un await sur lequel l'acteur est réentrant, et c'est
    /// `generation` qui l'empêche de reposer un instantané d'avant.
    private var snapshot: [String: Double] = [:]
    private var flush: Task<Bool, Never>?

    /// Le dernier « cran » parti : le suivant l'attend. Milō applique chaque
    /// delta au niveau qu'il tient à l'arrivée, mais en multiroom deux
    /// changements arrivés dans les mêmes quelques dizaines de millisecondes
    /// peuvent se fondre en un (session du Pi, 27/09/2026) : deux appuis
    /// n'en feraient qu'un.
    private var lastStep: Task<MiloAPIClient.StepOutcome, Never>?

    /// Assez long pour réunir les rappels d'une rafale, et pas davantage.
    ///
    /// Une rafale, c'est un rappel par enceinte, émis en **2 ms au pire**
    /// (médiane 1 ms) ; la suivante n'arrive pas avant **212 ms** pendant un
    /// glissement (315 envois relus le 22/09/2026), et deux appuis sur un bouton
    /// sont engagés à ~230 ms d'écart au plus serré (26/09). Elle valait 180 ms :
    /// assez pour fondre deux appuis rapides en un seul envoi depuis qu'un appui
    /// part en « un cran » — un cran perdu, et un engagement d'iOS que
    /// `GroupVolumeMirror` n'aurait jamais vu. 30 ms gardent quinze fois la
    /// rafale la plus longue (11 appuis sur 11 réunis, mesuré le 26/09).
    private static let quietPeriod = Duration.milliseconds(30)

    /// Programme l'écriture, **et l'attend**.
    ///
    /// L'attente n'est pas une question de style : c'est elle qui garde
    /// l'extension en vie. `mediaremoted` la termine quelques millisecondes
    /// après l'avoir lue — mesuré le 19/09/2026, six millisecondes entre la
    /// lecture et le `RBSTerminateRequest`. Une écriture posée dans une tâche
    /// détachée que personne n'attend meurt donc avec le processus, et c'est la
    /// **dernière** valeur du geste qui se perdait ainsi : celle qui compte,
    /// laissant une enceinte au niveau d'avant.
    ///
    /// Tant que l'appelant attend, le système tient son rappel pour en cours et
    /// laisse le processus vivre.
    ///
    /// La coalescence est préservée : un événement plus récent annule le
    /// précédent, dont l'attente se dénoue aussitôt — `Task.sleep` jette à
    /// l'annulation, et la garde qui suit rend la main sans écrire.
    ///
    /// Ce que cette annulation coûte, et qu'elle coûtait déjà : `send` a vidé
    /// `pending` avant de partir, si bien qu'une enceinte citée par la rafale
    /// abandonnée et pas par la suivante n'est jamais réécrite. Sur le chemin
    /// global c'est sans effet — une seule requête porte tout le monde — et sur
    /// le chemin par enceinte l'écart se referme au geste suivant. Le corriger
    /// demanderait de ne retirer de `pending` que ce qui est réellement parti,
    /// ce qui n'a pas paru valoir le risque tant que le geste maître aboutit.
    ///
    /// Rend ce que rend `send`, ou `false` quand une rafale plus récente a
    /// annulé cette tâche avant qu'elle parte.
    func record(mac: String, target: Double, snapshot: [String: Double]) async -> Bool {
        pending[mac] = target
        self.snapshot = snapshot

        flush?.cancel()
        let task = Task { [weak self] () -> Bool in
            try? await Task.sleep(for: Self.quietPeriod)
            guard !Task.isCancelled, let self else { return false }
            return await self.send()
        }
        flush = task
        return await task.value
    }

    /// Une rafale coalescée part d'ici, et d'ici seulement.
    ///
    /// Rend `true` quand cet envoi a posé des niveaux optimistes et qu'aucun
    /// plus récent ne l'a remplacé en route — y compris sur un échec, où
    /// l'affichage vient d'être rendu à Milō : dans les deux cas il y a du neuf
    /// à relire. `false` quand il n'y avait rien à envoyer, ou qu'une rafale
    /// plus récente a pris la main pendant l'aller-retour : faire relire alors
    /// rendrait en plein geste des niveaux déjà dépassés.
    private func send() async -> Bool {
        let entries = pending
        let shown = snapshot
        pending = [:]
        guard !entries.isEmpty, !shown.isEmpty else { return false }

        generation &+= 1
        let mine = generation

        // Une enceinte que l'instantané ne connaît pas ne peut pas peser dans
        // une moyenne indexée sur lui : elle ne compte pas pour décider de la
        // nature du geste. C'est bien un compte à part et non un filtre sur
        // `entries` : une rafale d'une seule enceinte connue sur deux rendues
        // était lue comme globale, alors qu'un doigt ne tient qu'un curseur de
        // pièce à la fois.
        //
        // Sa cible à elle est perdue si la rafale part quand même en global —
        // mais une enceinte absente de ce qu'on a rendu n'a pas de place dans
        // le décalage que Milō va appliquer, et elle reviendra avec le prochain
        // instantané.
        let seen = entries.filter { shown[$0.key] != nil }
        let global = MiloAPIClient.isGlobalGesture(touched: seen.count, deviceCount: shown.count)

        // Ce que le geste voulait dire, et non ce qu'iOS en a déduit : sous un
        // plafond resté haut, iOS demande moins que l'appui — voire moins que
        // le niveau d'avant sur un « + ». Une enceinte seule passe aussi par
        // là, son curseur principal ayant le même plafond (0,909 mesuré le
        // 26/09 avec un seul appareil). Un curseur de pièce, lui, pose sa
        // valeur telle quelle. Voir `GroupVolumeMirror`.
        var wanted = entries
        var reading: GroupVolumeMirror.Reading?
        if global || shown.count == 1 {
            reading = GroupVolumeMirror.update {
                $0.interpret(burst: seen, shown: shown, now: Date().timeIntervalSince1970)
            }
            if let reading {
                wanted.merge(reading.targets) { _, corrected in corrected }
                MiloAPIClient.trace?(reading.summary)
            } else {
                MiloAPIClient.trace?("iOS : rafale non relue, telle quelle")
            }
        } else {
            GroupVolumeMirror.update { $0.notePerDevice(seen) }
        }

        // Un bouton physique fait le pas de Milō, comme les boutons du widget.
        // Pas de repli sur le niveau absolu : un échec n'y gagnerait rien, et un
        // envoi qui aurait abouti sans réponse deviendrait un second changement.
        if case .button(let up)? = reading?.kind {
            let previous = lastStep
            let step = Task { () -> MiloAPIClient.StepOutcome in
                _ = await previous?.value
                return await MiloAPIClient.stepVolume(up: up)
            }
            lastStep = step
            let outcome = await step.value
            guard !Task.isCancelled, generation == mine else { return false }
            switch outcome {
            case .applied(let level):
                let mean = shown.values.reduce(0, +) / Double(shown.count)
                noteShift(shown: shown, to: level, from: mean)
                MiloAPIClient.trace?("cran Milō \(up ? "+" : "−") → \(Self.rounded(level))")
            case .appliedUnknown:
                // L'affichage revient à ce que Milō rapporte : le push suit.
                MiloAPIClient.forgetOptimistic(macs: Array(shown.keys))
                MiloAPIClient.trace?("cran Milō \(up ? "+" : "−") → niveau à venir par le push")
            case .failed:
                MiloAPIClient.forgetOptimistic(macs: Array(shown.keys))
                MiloAPIClient.trace?("cran Milō \(up ? "+" : "−") : échec")
            }
            return true
        }

        if global, let target = MiloAPIClient.globalTarget(touched: wanted, snapshot: shown) {
            // Les niveaux optimistes décrivent ce que Milō va **appliquer** —
            // le même écart pour tout le monde — et non les cibles brutes du
            // système, qui écarteraient les pièces à l'affichage avant même que
            // l'état réel les remette d'accord.
            let mean = shown.values.reduce(0, +) / Double(shown.count)
            noteShift(shown: shown, to: target, from: mean)
            MiloAPIClient.trace?(
                "geste global → \(Self.rounded(target)) (\(seen.count)/\(shown.count))")

            let applied = await MiloAPIClient.writeGlobalVolume(level: target)

            // Annulé, ou déjà remplacé : une rafale plus récente a posé ses
            // propres niveaux et lancé sa propre écriture. Toucher à quoi que
            // ce soit ici l'écraserait avec un instantané d'avant, et la base
            // rendue au système reculerait en plein geste.
            guard !Task.isCancelled, generation == mine else { return false }

            guard let applied else {
                // Sans cette branche, l'affichage tenait trois secondes pleines
                // un niveau que Milō n'avait jamais appliqué — exactement ce
                // que la lecture du niveau appliqué existe pour éviter.
                MiloAPIClient.forgetOptimistic(macs: Array(shown.keys))
                MiloAPIClient.trace?("global échoué, affichage rendu à Milō")
                return true
            }
            if abs(applied - target) > 0.001 {
                noteShift(shown: shown, to: applied, from: mean)
                MiloAPIClient.trace?("global appliqué → \(Self.rounded(applied))")
            }
            return true
        }

        for (mac, target) in wanted {
            MiloAPIClient.noteOptimistic(mac: mac, level: target)
        }
        MiloAPIClient.trace?("par enceinte (\(wanted.count)/\(shown.count))")
        await withTaskGroup(of: Void.self) { group in
            for (mac, target) in wanted {
                group.addTask {
                    let applied = await MiloAPIClient.writeClientVolume(mac: mac, level: target)
                    guard !Task.isCancelled, await self.isCurrent(mine) else { return }
                    guard let applied else {
                        MiloAPIClient.forgetOptimistic(macs: [mac])
                        return
                    }
                    if abs(applied - target) > 0.001 {
                        MiloAPIClient.noteOptimistic(mac: mac, level: applied)
                    }
                }
            }
        }
        return !Task.isCancelled && generation == mine
    }

    /// Cet envoi est-il toujours le dernier parti ?
    ///
    /// La même garde que sur le chemin global, mais lisible depuis la tâche
    /// enfant du groupe, qui n'est pas isolée sur l'acteur.
    private func isCurrent(_ number: UInt64) -> Bool { generation == number }

    /// Répartit un niveau global sur les enceintes en les décalant toutes du
    /// même écart — la règle que `set_volume_db` applique côté Milō.
    private func noteShift(shown: [String: Double], to target: Double, from mean: Double) {
        let delta = target - mean
        for (mac, level) in shown {
            MiloAPIClient.noteOptimistic(mac: mac, level: level + delta)
        }
    }

    private static func rounded(_ level: Double) -> Double { (level * 1000).rounded() / 1000 }
}

/// Quand chaque URL de pochette a échoué pour la dernière fois.
///
/// Un acteur, et non une table `nonisolated(unsafe)`. Celle-ci ne tenait que par
/// un argument sur les appelants du moment — « ce qui sérialise les accès, c'est
/// la boucle de sondage, qui n'est pas réentrante » — et cet argument a déjà
/// changé deux fois dans la même journée : l'extension a appelé `cacheArtwork`
/// depuis `update(_:)`, plusieurs fois par processus et dans des tâches
/// détachées, puis ne l'a plus appelé du tout. Aujourd'hui seule la boucle de
/// l'app y touche, et l'acteur est donc théoriquement de trop.
///
/// Il reste. Deux mutations concurrentes d'un `Dictionary` Swift ne donnent pas
/// une valeur périmée, elles corrompent la mémoire : c'est une panne dont le
/// coût ne se compare pas à celui d'un acteur, et une invariante de sûreté n'a
/// pas à dépendre de la liste des appelants qui existent ce matin.
private actor ArtworkQuarantine {
    static let shared = ArtworkQuarantine()

    private var failures: [String: Date] = [:]

    /// Depuis combien de temps cette URL est écartée, si elle l'est encore.
    func held(_ url: String) -> TimeInterval? {
        guard let at = failures[url] else { return nil }
        let since = Date().timeIntervalSince(at)
        return since < MiloAPIClient.artworkRetryDelay ? since : nil
    }

    /// Retient l'échec, et oublie ceux que l'accalmie a déjà couverts : sans
    /// cette purge, la table grossirait d'une entrée par URL morte pour toute
    /// la vie du processus.
    func hold(_ url: String) {
        let now = Date()
        failures = failures.filter {
            now.timeIntervalSince($0.value) < MiloAPIClient.artworkRetryDelay
        }
        failures[url] = now
    }

    func release(_ url: String) {
        failures[url] = nil
    }
}

// MARK: - Pochettes en cache

extension MiloAPIClient {

    /// Dossier partagé où l'app dépose les pochettes pour l'extension.
    ///
    /// Sous `Library/Caches`, et pas à la racine du conteneur, pour une raison
    /// d'outillage : `devicectl device copy from` refuse tout ce qui est hors de
    /// `Library`, `Documents` et `tmp` — « Access restricted: … is outside the
    /// allowed container directories ». Tant que ce dossier était à la racine,
    /// le seul moyen de savoir ce qu'il contenait vraiment était de le déduire,
    /// et c'est précisément la question qui compte ici : les octets déposés
    /// sont-ils du JPEG affichable ou du WebP qui ne s'affichera pas. Sous
    /// `Library`, on peut aller les lire et arrêter de déduire.
    ///
    /// `Caches` est aussi l'endroit juste au sens du système : ce qui est ici se
    /// retélécharge, et iOS a le droit de le reprendre quand le disque se remplit.
    static func artworkCacheDirectory() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return nil }
        let dir = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Nom de fichier stable pour une URL de pochette.
    static func artworkCacheFile(for urlString: String) -> URL? {
        guard let dir = artworkCacheDirectory() else { return nil }
        // Empreinte simple : le nom doit être stable et sans caractère interdit,
        // pas résistant aux collisions volontaires.
        var hash: UInt64 = 5381
        for byte in urlString.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return dir.appendingPathComponent(String(hash, radix: 36))
    }

    /// Télécharge la pochette depuis l'app et la dépose pour l'extension.
    ///
    /// C'est l'app qui va la chercher, jamais l'extension, et pour deux raisons
    /// mesurées dans les journaux système :
    ///
    /// - le système relance un **processus neuf** à chaque demande de pochette,
    ///   qui doit refaire la résolution mDNS de `milo.local` depuis zéro, et il
    ///   abandonne au bout de dix secondes (`playbackQueueRequest timed out
    ///   after 10s`, puis `Catalog returned nil image`) ;
    /// - ses connexions sortantes sont de toute façon refusées — `Path was
    ///   denied by NECP policy` — parce qu'une extension ne peut pas demander
    ///   l'autorisation d'accès au réseau local, faute d'écran.
    ///
    /// L'app, elle, tourne déjà, a l'autorisation, et entretient la session.
    /// Lire un fichier local est instantané et ne peut pas expirer.
    @discardableResult
    static func cacheArtwork(from urlString: String) async -> Bool {
        // Chaque étape est tracée : cinq `guard` qui retournent `false` ne
        // disent pas lequel a échoué, et c'est exactement ce qui a fait perdre
        // le plus de temps aujourd'hui.
        func note(_ step: String) {
            UserDefaults(suiteName: appGroupID)?.set(step, forKey: "milo_cache_trace")
        }

        purgeLegacyArtworkCacheOnce()

        guard let file = artworkCacheFile(for: urlString) else {
            note("pas de conteneur partagé"); return false
        }
        // Le cache est jugé sur ses **octets d'en-tête**, pas sur sa taille.
        //
        // « Le contenu est garanti affichable au moment où on l'écrit » n'était
        // vrai que de cette fonction-ci. L'extension écrit dans le même dossier,
        // et son repli réseau y déposait les octets bruts sans les convertir :
        // mesuré le 19/09/2026 au soir, quatre WebP de station (5 526, 10 416,
        // 11 494 et 11 618 o) au milieu de vingt JPEG. Un contrôle de taille les
        // déclarait valides, cette fonction sortait aussitôt, et la conversion
        // n'avait plus jamais lieu — la station restait sans image pour de bon.
        //
        // Lire quatre octets coûte moins qu'un `attributesOfItem`, qui ouvrait
        // déjà le fichier. La cadence de deux secondes n'est donc pas un
        // argument contre, et elle ne l'était pas non plus.
        if let head = artworkHead(of: file), isDisplayableArtwork(head) {
            note("déjà en cache (\(isJPEG(head) ? "JPEG" : "PNG")) \(file.path)")
            return true
        }

        let absolute = urlString.hasPrefix("/") ? baseURL() + urlString : urlString
        guard let url = URL(string: absolute) else {
            note("URL invalide : \(absolute)"); return false
        }

        // Cette fonction est attendue avant l'annonce de la session, et le
        // sondage repasse toutes les deux secondes. Une pochette qui n'arrive
        // pas ne doit donc rien retenir : avec les 60 s par défaut d'une
        // `URLSession`, un CDN muet gelait position, titre et volume pendant
        // une minute entière. Six secondes suffisent à `mzstatic` sur un
        // Wi-Fi médiocre, et bornent la perte à une cadence.
        //
        // Toutes les autres requêtes du projet bornent déjà la leur ; celle-ci
        // était la seule à ne pas le faire.
        var request = URLRequest(url: url)
        request.timeoutInterval = artworkTimeout
        // Ce qu'on sait afficher, dit plutôt que supposé. `jpegNormalized`
        // rattraperait un WebP ici, mais le dire évite la conversion **et**
        // aligne l'app sur l'extension, qui ne peut pas se le permettre.
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")

        // Et une fois qu'elle a échoué, ne pas la redemander au tour suivant.
        // Rien n'est écrit en cas d'échec, donc la boucle revient ici deux
        // secondes plus tard pour réattendre six secondes, indéfiniment — le
        // scénario que la remarque sur le SVG, plus bas, cherchait déjà à
        // éviter. On laisse passer une accalmie avant de retenter la même URL.
        //
        // La quarantaine est tenue **par URL**, et non comme un créneau unique
        // que le premier succès venu effacerait : en radio, deux URL alternent.
        // Une piste reconnue donne `track_artwork` sur `mzstatic`, qui passe
        // par Internet et peut expirer ; les trous de reconnaissance donnent
        // `favicon`, servi par Milō sur le LAN, qui réussit presque toujours.
        // Un créneau unique se serait donc fait effacer par chaque favicon, et
        // la piste suivante aurait repayé les six secondes en entier.
        if let since = await ArtworkQuarantine.shared.held(absolute) {
            note("en quarantaine depuis \(Int(since)) s : \(absolute)")
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, !data.isEmpty else {
                await ArtworkQuarantine.shared.hold(absolute)
                note("HTTP \(code), \(data.count) o"); return false
            }
            // Un format qu'ImageIO ne sait pas décoder — un SVG, par exemple —
            // n'est **pas** déposé, et c'est la quarantaine qui empêche la
            // boucle.
            //
            // Le déposer tel quel était le remède d'avant, quand la présence se
            // jugeait sur la taille : un fichier non vide passait pour valide et
            // la boucle s'arrêtait là. Depuis que les deux côtés jugent sur les
            // octets d'en-tête, ce même dépôt rouvre la boucle par l'autre bout
            // — le fichier est écrit, relu, refusé, retéléchargé, toutes les
            // deux secondes. Et l'extension paierait un aller-retour réseau à
            // chaque demande de pochette, dans le budget qu'elle n'a pas.
            //
            // `hold` donne trente secondes de répit à cette URL, ce qui borne
            // les reprises sans rien écrire qu'il faudrait ensuite rejeter.
            guard let payload = jpegNormalized(data) ?? (isDisplayableArtwork(data) ? data : nil)
            else {
                await ArtworkQuarantine.shared.hold(absolute)
                note("format non affichable, rien déposé : \(url.lastPathComponent)")
                return false
            }
            try payload.write(to: file, options: .atomic)
            note("déposé \(payload.count) o dans \(file.path)")
            await ArtworkQuarantine.shared.release(absolute)
            return true
        } catch {
            await ArtworkQuarantine.shared.hold(absolute)
            note("échec \(url.lastPathComponent) : \(error.localizedDescription)")
            return false
        }
    }

    /// Dépose d'avance les logos des stations favorites.
    ///
    /// Ce que ça répare : on change de station depuis la carte de l'écran
    /// verrouillé, l'app dort, et le nouveau logo n'est dans aucun cache. Il ne
    /// reste alors que le repli réseau de l'extension — épinglé sur
    /// `milo.local`, dans un processus que `mediaremoted` peut terminer, et
    /// c'est exactement le tirage qu'on cherche à ne plus jouer. Les favoris
    /// sont les seules stations entre lesquelles on bascule, et il y en a cinq
    /// pour trois cents stations : les déposer coûte cinq fichiers.
    ///
    /// **Seuls les logos hébergés par Milō** sont concernés — ceux qui commencent
    /// par `/`. Les autres sont des URL publiques que l'extension atteint par
    /// Internet sans toucher au LAN, donc sans rien tirer au sort ; les
    /// précharger ne réparerait rien et remplirait le cache pour rien.
    ///
    /// Appelée au passage au premier plan, pas dans la boucle : même réduit à
    /// huit kilooctets, un aller-retour de plus n'a rien à faire dans un sondage
    /// de deux secondes. `cacheArtwork` juge ensuite sur les octets d'en-tête et
    /// sort aussitôt pour ce qui est déjà là.
    ///
    /// `favorites_only=true` et pas la liste nue : **`/api/radio/stations` est
    /// une vue de parcours**, trois cents stations dont cinq seulement portent
    /// `is_favorite: true`. Les favoris sont vingt-deux. Mesuré le 20/09/2026 :
    /// 300 stations et 112 ko sans le paramètre, 22 stations et 8 ko avec — et
    /// les dix-sept manquantes incluaient `6239161eaee1.webp`, la station même
    /// dont l'absence de logo a ouvert cette enquête. Se fier au drapeau de la
    /// liste nue, c'est précharger un favori sur cinq.
    static func primeFavoriteStationArtwork() async {
        guard await StationPriming.shared.begin() else { return }
        defer { Task { await StationPriming.shared.end() } }

        let defaults = UserDefaults(suiteName: appGroupID)
        let primedAt = defaults?.object(forKey: stationPrimeAtKey) as? Double ?? 0
        guard Date().timeIntervalSince1970 - primedAt >= stationPrimeInterval else { return }

        guard let data = try? await get(path: "/api/radio/stations?favorites_only=true",
                                        timeout: artworkTimeout),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stations = payload["stations"] as? [[String: Any]]
        else {
            // Milō injoignable au moment où l'app passe devant, ce qui est
            // banal : ne rien inscrire, pour ne pas s'interdire dix minutes de
            // préchargement sur un échec qui n'a rien appris. Le verrou
            // ci-dessus suffit à empêcher les deux départs de `startPump` de se
            // marcher dessus, et il ne survit pas au processus — ce qui est
            // exactement la portée qu'on veut.
            return
        }

        // Inscrit après coup : c'est la réussite qui ouvre le créneau, pas la
        // tentative.
        defaults?.set(Date().timeIntervalSince1970, forKey: stationPrimeAtKey)

        for favicon in stationArtworkToPrime(in: stations) {
            await cacheArtwork(from: favicon)
        }
    }

    /// Empêche deux préchargements simultanés.
    ///
    /// Le créneau de dix minutes ne suffisait pas : le lire puis l'écrire n'est
    /// pas atomique, et `startPump` part de `didFinishLaunching` **et** de
    /// `sceneDidBecomeActive`, qui se suivent de quelques millisecondes au
    /// lancement à froid. Les deux passaient la garde avant que l'une ait écrit.
    private actor StationPriming {
        static let shared = StationPriming()
        private var inFlight = false

        func begin() -> Bool {
            guard !inFlight else { return false }
            inFlight = true
            return true
        }

        func end() { inFlight = false }
    }

    /// Les logos qui valent d'être déposés d'avance, parmi ce que Milō annonce.
    ///
    /// Extraite pour être testable sans réseau — c'est la seule partie du
    /// préchargement qui porte une décision.
    ///
    /// Le tri « favori » appartient à l'appelant, qui interroge une route déjà
    /// restreinte. On ne le refait **pas** ici sur `is_favorite` : ce drapeau
    /// est celui de la vue de parcours, et s'y fier a déjà coûté dix-sept
    /// favoris sur vingt-deux.
    ///
    /// Ce qui est filtré ici : **hébergé par Milō**, parce qu'un logo servi par
    /// Internet n'a jamais eu besoin du LAN et n'a donc rien à gagner à être
    /// déposé. Et dédupliqué, parce que deux stations peuvent partager un logo.
    ///
    /// `primeLimit` est un garde-fou, pas une règle de gestion : il borne ce
    /// qu'une route mal restreinte pourrait faire télécharger. Vingt-deux
    /// favoris mesurés le 20/09/2026, contre trois cents stations au catalogue —
    /// la différence entre les deux est précisément ce qu'on ne veut pas payer.
    static func stationArtworkToPrime(in stations: [[String: Any]]) -> [String] {
        var wanted: [String] = []
        for station in stations {
            guard let favicon = station["favicon"] as? String,
                  favicon.hasPrefix("/"), !wanted.contains(favicon) else { continue }
            wanted.append(favicon)
            if wanted.count == primeLimit { break }
        }
        return wanted
    }

    /// Plafond de sécurité du préchargement — voir `stationArtworkToPrime`.
    private static let primeLimit = 40

    /// Quand les logos des favoris ont été déposés pour la dernière fois.
    ///
    /// Une station qu'on ajoute aux favoris n'apparaît donc qu'au prochain
    /// créneau. C'est assumé : le repli réseau de l'extension la couvre entre
    /// temps, et refaire la liste à chaque passage au premier plan coûterait
    /// cent kilooctets par aller-retour d'app.
    private static let stationPrimeAtKey = "milo_station_prime_at"
    private static let stationPrimeInterval: TimeInterval = 600

    /// Ce qu'on accorde au CDN des pochettes avant de rendre la main au
    /// sondage, et le répit qu'on s'accorde après un échec.
    private static let artworkTimeout: TimeInterval = 6
    fileprivate static let artworkRetryDelay: TimeInterval = 30

    private static let artworkCacheGenerationKey = "milo_artwork_cache_generation"

    /// Vide une fois pour toutes le cache laissé par les versions antérieures.
    ///
    /// Elles y déposaient les octets d'origine, donc du WebP pour les images de
    /// station, que le consommateur de `ArtworkRepresentation(data:)` n'affiche
    /// pas. Comme la vérification de présence ne regarde plus le contenu, ces
    /// entrées seraient réutilisées pour toujours.
    ///
    /// Une purge unique plutôt qu'un suffixe de génération dans le nom de
    /// fichier : le suffixe abandonnerait un orphelin par pochette dans le
    /// conteneur partagé, sans que rien ne vienne jamais le ramasser. Ce qui est
    /// effacé ici est retéléchargé à la demande.
    private static func purgeLegacyArtworkCacheOnce() {
        let defaults = UserDefaults(suiteName: appGroupID)
        guard defaults?.integer(forKey: artworkCacheGenerationKey) != 3,
              let dir = artworkCacheDirectory()
        else { return }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []

        // Génération 3 : ne retirer que ce qui ne s'affichera pas, au lieu de
        // tout vider. Les WebP déposés par l'extension sont la panne ; les JPEG
        // à côté d'eux sont bons, et les rejeter coûterait un téléchargement par
        // pochette pour rien.
        //
        // Les garde-fous du dessus rendent déjà ces fichiers inertes — un
        // fichier non-JPEG est traité comme un cache manquant des deux côtés.
        // Ce balayage est ce qui fait que « le cache ne contient que du JPEG »
        // est vrai maintenant, et pas seulement à la prochaine lecture de
        // chaque station. Une invariante qu'on peut aller vérifier vaut mieux
        // qu'une qui s'établira peut-être.
        for file in files where !isDisplayableArtwork(artworkHead(of: file) ?? Data()) {
            try? FileManager.default.removeItem(at: file)
        }

        // Le dossier a déménagé sous `Library/Caches` à la génération 2.
        // L'ancien, à la racine du conteneur, ne sera plus jamais consulté — il
        // part entier, sinon il resterait là pour toujours sans que rien ne le
        // ramasse. Sans effet une fois qu'il n'existe plus.
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            try? FileManager.default.removeItem(
                at: container.appendingPathComponent("artwork", isDirectory: true))
        }
        defaults?.set(3, forKey: artworkCacheGenerationKey)
    }

    /// Les premiers octets d'un fichier, sans le charger en entier.
    ///
    /// `Data(contentsOf:)` lirait le mégaoctet d'une pochette pour en regarder
    /// quatre. Ici on ne lit que ce qu'on inspecte.
    private static func artworkHead(of file: URL, count: Int = 8) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }

    /// Ces octets s'afficheront-ils une fois rendus au système ?
    ///
    /// **JPEG et PNG, pas seulement JPEG.** Ce qui a été mesuré le 19/09/2026,
    /// c'est que le WebP arrive intact et n'affiche rien ; rien n'a jamais
    /// incriminé le PNG, et les pochettes `mzstatic` en `.png` s'affichaient
    /// très bien. Un verdict limité au JPEG refusait une image parfaitement
    /// valide et la faisait retélécharger à chaque passe.
    ///
    /// Partagé avec l'extension : c'est le même verdict des deux côtés qui rend
    /// le cache homogène. Deux définitions de « affichable » en donneraient deux
    /// contenus, et c'est déjà arrivé.
    static func isDisplayableArtwork(_ data: Data) -> Bool {
        isJPEG(data) || isPNG(data)
    }

    /// Les huit octets de signature d'un PNG.
    static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return Array(data.prefix(signature.count)) == signature
    }

    /// Les trois octets d'en-tête d'un JFIF/Exif.
    static func isJPEG(_ data: Data) -> Bool {
        data.count > 3 && data[data.startIndex] == 0xFF
            && data[data.startIndex + 1] == 0xD8
            && data[data.startIndex + 2] == 0xFF
    }

    /// Ramène n'importe quelle image au JPEG, en gardant ses dimensions.
    ///
    /// Le consommateur de `ArtworkRepresentation(data:)` n'accepte pas le WebP :
    /// mesuré le 19/09/2026, les quatre images de station servies par Milō sont
    /// des WebP VP8 1024×1024, elles arrivent intactes jusqu'au système et
    /// n'affichent rien, quand tout ce qui s'affiche — pochettes Shazam,
    /// in-band, Spotify, bibliothèque musicale — est du JPEG sans exception.
    ///
    /// La conversion vit dans l'app, et c'est tout l'intérêt : l'extension, elle,
    /// est tuée quelques millisecondes après avoir été lue, et ne peut pas se
    /// permettre de décoder quoi que ce soit. L'app tourne, elle a le temps.
    ///
    /// Les dimensions sont conservées telles quelles, délibérément : le format
    /// et la taille étaient confondus dans les observations (le WebP en 1024, le
    /// JPEG en 600), et redimensionner en même temps qu'on convertit aurait
    /// laissé les deux hypothèses indistinctes une fois de plus.
    ///
    /// Un JPEG est rendu sans être touché — le ré-encoder ne ferait que perdre
    /// de la qualité pour rien.
    private static func jpegNormalized(_ data: Data) -> Data? {
        if isJPEG(data) { return data }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                  out, "public.jpeg" as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
