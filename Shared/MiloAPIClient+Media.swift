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
        func body(forSource source: String) -> [String: Any]? {
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
        var isIdempotent: Bool {
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
        // raison que dans `setGlobalVolume`.
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

    /// Journal de l'appelant, quand il en a un. L'extension y branche le sien.
    nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// Remet à Milō ce que le système vient de demander pour le système Milō.
    ///
    /// Le niveau reste tel quel, entre 0 et 1. C'est l'échelle de la barre, et
    /// c'est celle que Milō accepte sur `volume` : aucune conversion en
    /// décibels sur ce chemin.
    ///
    /// Elle y a été, et c'était la panne. Convertir demandait les bornes de
    /// l'opérateur, donc une copie locale de `volume_limits` — et l'extension
    /// ne rafraîchit jamais la sienne. Elle a converti des mois durant sur
    /// -80…-21 pendant que l'appareil tournait sur -78…-8. Milō normalise
    /// déjà dans l'autre sens pour les mêmes raisons — voir
    /// `core/push/payloads.py`.
    ///
    /// `shown` est ce que nous avions rendu au système, sans l'écart de
    /// confirmation (voir `baseLevel`) : c'est de là qu'un appui se relit.
    ///
    /// `reported` est ce que Milō rapporte, sans valeur optimiste.
    ///
    /// Rend `true` quand l'écrivain que ce rappel a attendu a écrit quelque
    /// chose — il a pu être lancé par un rappel précédent : il y a du neuf à
    /// faire relire, et la valeur optimiste est déjà la dernière demandée.
    static func applyVolume(to target: Float, shown: Float, reported: Float) async -> Bool {
        await VolumeGesture.shared.record(posed: min(max(Double(target), 0), 1),
                                          shown: min(max(Double(shown), 0), 1),
                                          reported: min(max(Double(reported), 0), 1))
    }

    /// L'appareil unique qui représente tout le système Milō sur la carte Now
    /// Playing : son niveau est le global, écrit en absolu au niveau qu'iOS
    /// attend (`setGlobalVolume`), jamais par client. Pas de deux-points :
    /// c'est aussi sa clé « MAC ».
    static let systemDeviceID = "milo-system"

    /// Ce qu'a donné une écriture du volume global.
    enum WriteOutcome: Equatable {
        /// Milō l'a appliquée ; le niveau global qui en résulte (0…1).
        case applied(Double)
        /// Appliquée, mais sans niveau dans la réponse : on attend le push, on
        /// n'invente rien.
        case appliedUnknown
        /// Rien n'a abouti.
        case failed
    }

    /// Le global tel que Milō le tient, 0…1 — `global_volume`, la moyenne
    /// des enceintes que la carte représente. Court : il précède l'écriture
    /// d'un rappel, et les deux tiennent ensemble dans les trois secondes
    /// que `mediaremoted` accorde (`globalWriteTimeout`).
    ///
    /// Rien quand Milō ne compte aucune enceinte : `global_volume` vaut alors
    /// son niveau par défaut, sans rapport avec ce que jouaient les enceintes
    /// (tous les clients qui se reconnectent ensemble, par exemple).
    static func currentGlobalVolume(timeout: TimeInterval = 0.4) async -> Double? {
        guard let data = try? await get(path: "/api/volume/state", timeout: timeout),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let level = (payload["global_volume"] as? NSNumber)?.doubleValue,
              let clients = payload["clients"] as? [String: [String: Any]],
              clients.values.contains(where: {
                  $0["available"] as? Bool ?? true && $0["volume_control"] as? Bool ?? true
              })
        else { return nil }
        return min(max(level, 0), 1)
    }

    /// Ce que l'écriture d'un rappel peut prendre : avec la relecture (0,4 s),
    /// moins que les trois secondes au-delà desquelles `mediaremoted`
    /// abandonne le rappel et l'extension avec.
    static let globalWriteTimeout: TimeInterval = 2.5

    /// Un rappel de la carte : le global, en absolu, au niveau qu'iOS attend
    /// (`SystemVolumeModel.obey`).
    ///
    /// Attendu plutôt que lancé sans suite : c'est l'attente qui garde
    /// l'extension en vie, et la réponse porte le `volume` appliqué (0…1, après
    /// bornage), qu'on affiche aussitôt.
    static func setGlobalVolume(_ level: Double) async -> WriteOutcome {
        guard let url = URL(string: baseURL() + "/api/volume/global") else { return .failed }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = globalWriteTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["volume": min(max(level, 0), 1), "show_bar": true])

        let defaults = UserDefaults(suiteName: appGroupID)
        guard let (data, response) = try? await lanData(for: request) else {
            defaults?.set("global -> réseau", forKey: "milo_volume_write_error")
            return .failed
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            defaults?.set("global -> HTTP \(code)", forKey: "milo_volume_write_error")
            return .failed
        }
        defaults?.removeObject(forKey: "milo_volume_write_error")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let level = (json?["volume"] as? NSNumber)?.doubleValue else { return .appliedUnknown }
        return .applied(min(max(level, 0), 1))
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
    /// Cet écart est **affiché**, jamais **calculé** : un appui se relit à
    /// partir de `baseLevel`. Parti du niveau affiché, l'écart finirait dans la
    /// valeur optimiste, et le rendu suivant l'ajouterait une seconde fois — un
    /// écart qui grossit à chaque rappel.
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
    /// `SystemVolumeModel`.
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

    /// Quand la valeur optimiste de cette enceinte a été posée, s'il y en a une.
    static func optimisticAt(mac: String) -> TimeInterval? {
        let plain = mac.replacingOccurrences(of: ":", with: "")
        return UserDefaults(suiteName: appGroupID)?.object(forKey: optimisticVolumeAtKey(plain)) as? Double
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

    /// Ferme la fenêtre optimiste sans oublier ce qu'on a demandé : Milō
    /// reprend la main sur l'affichage, mais ce qu'il confirme de notre
    /// demande se rend à l'identique, écart compris. Voir `displayedLevel` :
    /// `forgetOptimistic` efface aussi `confirmed`, et le rendu perd alors son
    /// écart hors de toute commande d'iOS.
    static func expireOptimistic(macs: [String]) {
        let defaults = UserDefaults(suiteName: appGroupID)
        for mac in macs {
            let plain = mac.replacingOccurrences(of: ":", with: "")
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

/// Les rappels `onChange` en cours dans ce processus : ce que `devices` rend
/// pendant ce temps, la carte l'affiche mais iOS ne l'adopte pas.
enum VolumeCommand {

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

/// Le volume du système Milō tel qu'iOS le tient, sur la carte à un seul
/// appareil, et le niveau qu'un rappel de sa part attend.
///
/// **Ce qu'iOS fait, mesuré au banc le 12/10/2026** (boutons physiques, écran
/// verrouillé) : un appui engage G = affiché ± 1/16, puis rappelle l'appareil à
/// `référence × G / plafond`, et prend G pour plafond et ce qu'il a posé pour
/// référence. Le rapport référence/plafond ne bouge donc pas d'un appui à
/// l'autre. Il ne change que quand iOS adopte un niveau rendu hors de ses
/// commandes : la référence le prend, le plafond ne monte que s'il est dépassé.
/// Baissé ailleurs de 0,50 à 0,08, ce rapport valait 0,16 au « + » suivant.
/// La barre fait de même avec le doigt : elle saute sous lui, et pose
/// rapport × position (29/10 : doigt en haut, 0,61807793 à chaque rappel).
///
/// Et pendant la seconde qui suit un appui, la carte n'affiche pas notre rendu
/// mais ce qu'iOS vient de poser : le « + » suivant part de là.
///
/// **Un rappel écrit donc le niveau qu'iOS attend** : G pour un appui, la
/// position du doigt (posé ÷ rapport) pour la barre — ce que fait toute
/// enceinte AirPlay. L'appareil atterrit où iOS l'attend, et son rapport ne
/// dérive plus (décision du 29/10, après une journée de mesures).
///
/// Ce qu'on a essayé avant, et pourquoi c'était faux : un cran de Milō
/// (3 dB) par rappel, dont le modèle ne relisait que le sens. Milō s'arrêtait
/// ailleurs que là où iOS l'attendait ; iOS adoptait ce niveau et son rapport
/// dérivait (0,62 le 29/10), d'où des appuis relus à l'envers et une barre qui
/// montait au maximum doigt immobile (17:37:16), puis n'atteignait plus ni le
/// haut ni le bas (17:43). Le bouton physique fait désormais le pas d'iOS,
/// 1/16 de la course, et plus celui du widget.
///
/// Ce qui reste du sens : un appui qu'iOS engage depuis un affichage périmé.
/// Le 12/10 à 23:29:03, la carte montrait encore 0,9995 quand le global était
/// tombé à 0,6667 ailleurs ; un « − » engagé à 0,9375 et écrit tel quel a posé
/// le global à 1 — un client est passé de 0 à 100 %. Un appui reconnu ne va
/// donc jamais à l'envers de Milō : il fait alors un pas d'iOS dans son sens.
///
/// Un rapport ne s'oublie pas sur un push. Le 29/10 à 15:11:52.104, un push
/// tardif a fait perdre au rendu son écart de confirmation (0,321 → 0,3205) :
/// iOS ne l'a pas vu — l'appui suivant part encore de 0,321. Un écart de cet
/// ordre n'est donc pas un changement (`unnoticed`), et le dernier rapport
/// reconnu reste un repère (`anchor`).
///
/// Pur, pour être testé avec les chiffres relevés. Rangé dans le conteneur
/// partagé : l'extension change de processus sans arrêt, iOS garde son état.
struct SystemVolumeModel: Codable, Equatable {

    /// La session dont iOS tient ce rapport ; une autre repart à 1, mais
    /// garde ce que la carte affichait (`observe`).
    var session: String?
    /// Le plafond d'iOS : le G par lequel il divise.
    var ceiling: Double = 0
    /// Le niveau qu'iOS tient pour celui de l'appareil.
    var reference: Double = 0
    /// Le dernier niveau rendu, celui d'avant, et quand il a changé : un
    /// niveau inchangé n'est pas adopté, et un appui parti juste avant un
    /// changement partait encore de l'ancien.
    var lastSeen: Double?
    var previousSeen: Double?
    var seenAt: TimeInterval = 0
    /// Le dernier rappel : ce qu'iOS a posé, le niveau qu'il attendait, et
    /// quand.
    var lastPosed: Double?
    var lastCommit: Double?
    var lastAt: TimeInterval = 0
    /// Le dernier rapport qu'un appui reconnu a montré. Un push ne l'efface
    /// pas : iOS ne change de rapport qu'en adoptant un niveau, et s'il n'a pas
    /// adopté ce que le modèle a adopté, c'est encore le sien.
    ///
    /// Optionnel : un état rangé avant lui se relit tel quel au lieu de
    /// repartir de zéro.
    var anchor: Double?
    /// Le dernier rappel reçu, quel qu'il soit : celui qui le suit de près
    /// vient d'un doigt sur la barre.
    var rawAt: TimeInterval?
    /// Les rapports que supposait le dernier rappel, quand aucun appui ne
    /// l'expliquait : si le suivant en suppose un aussi, c'est celui d'iOS.
    var suspects: [Double]?
    /// Quand le dernier rappel a rendu la main, écriture faite.
    var returnedAt: TimeInterval?

    /// Le cran d'un bouton physique sur une destination externe.
    static let step = 1.0 / 16

    /// Combien de temps après un appui la carte peut encore afficher ce qu'iOS
    /// a posé ou engagé plutôt que notre rendu (≈ 1,07 s mesurés, marge comprise).
    static let shownFor: TimeInterval = 1.5

    /// Combien de temps un niveau qu'on vient de changer peut ne pas encore
    /// être à l'écran : à 23:29:03.231 le rendu a changé une milliseconde avant
    /// le rappel d'un appui parti de l'ancien.
    static let renderLag: TimeInterval = 0.5

    /// En deçà, deux rappels viennent d'un doigt sur la barre. Mesuré le 29/10
    /// (17:36:59–17:37:24, 118 rappels) : 50–75 ms pendant un glissement, 150
    /// à 200 ms pour un bouton maintenu, et deux appuis du doigt ne sont
    /// jamais engagés à moins de ~230 ms (26/09).
    static let dragGap: TimeInterval = 0.11

    /// iOS envoie le rappel suivant d'un glissement ~11 ms après le retour du
    /// précédent ; un bouton maintenu, pas avant ~120 ms après son départ.
    static let returnGap: TimeInterval = 0.04

    /// Une seconde sans rappel : les pushes de nos écritures sont arrivés, et
    /// ce que Milō rapporte est son niveau.
    static let settled: TimeInterval = 1

    /// L'écart relatif toléré entre le rapport qu'un appui suppose et celui
    /// qu'on suit. Le « + » et le « − » d'un même affichage supposent des
    /// rapports dans un facteur (affiché + 1/16) / (affiché − 1/16), jamais
    /// moins de 1,13 : les confondre demanderait trois fois cet écart.
    static let tolerance = 0.04

    /// En dessous, un G engagé est nul : iOS y garde ses rapports.
    static let silent = 0.0001

    /// Un écart de rendu qu'iOS ne remarque pas : à 15:11:52.104 le rendu est
    /// passé de 0,321 à 0,3205 hors commande, et l'appui suivant partait
    /// encore de 0,321 (0,16529 = 0,43101 × (0,321 + 1/16)). Celui de
    /// confirmation est 0,0005 ; Milō confirme notre demande à 0,001 près.
    static let unnoticed = MiloAPIClient.confirmationTolerance

    /// Un appui reconnu : son sens, le G qu'iOS a engagé, et le rapport par
    /// lequel il l'a multiplié — qui manque à zéro.
    struct Reading: Equatable {
        var up: Bool
        var commit: Double?
        var ratio: Double?
    }

    /// Ce qu'un rappel demande.
    struct Command: Equatable {
        /// Le niveau où iOS attend l'appareil : G pour un appui, le doigt pour
        /// la barre.
        var expected: Double
        /// Le niveau à écrire : le doigt, ou un pas d'iOS depuis Milō.
        var level: Double
        /// L'appui reconnu ; rien pour un doigt sur la barre.
        var press: Reading?
        /// L'appui a donné le rapport d'iOS ; sinon il n'a fait que son pas.
        var learned = false
        /// Le rapport par lequel iOS a multiplié `expected`.
        var ratio: Double
    }

    var ratio: Double {
        guard ceiling > Self.silent, reference > Self.silent else { return 1 }
        return min(reference / ceiling, 1)
    }

    /// Ce qu'iOS vient de lire dans `devices`. `duringCommand` : lu pendant un
    /// rappel `onChange`, que la carte affiche sans l'adopter.
    mutating func observe(_ level: Double, session id: String, duringCommand: Bool,
                          now: TimeInterval) {
        if session != id { self = carried(to: id) }
        let changed = lastSeen.map { abs($0 - level) > Self.unnoticed } ?? true
        if changed {
            previousSeen = lastSeen
            lastSeen = level
            seenAt = now
        }
        guard ceiling > Self.silent else {
            ceiling = level
            reference = level
            return
        }
        guard changed, !duringCommand else { return }
        reference = level
        ceiling = max(ceiling, level)
    }

    /// Une autre session : le rapport repart à 1, pas l'affichage.
    ///
    /// iOS ne repart pas de zéro avec la session : le 30/10 à 11:35:15,663,
    /// sur `b37c8445` qu'une ré-annonce venait de reconstruire, il a engagé un
    /// « − » depuis 0,0785 — ce que la carte de l'autre session affichait —
    /// quand le rendu de la nouvelle disait 0,01. Remis à zéro, le modèle ne
    /// connaissait plus 0,0785, a lu un doigt et écrit 0,016 en absolu : le
    /// volume monté sur Milo-Mac juste avant est retombé au plancher.
    private func carried(to id: String) -> SystemVolumeModel {
        var next = SystemVolumeModel(session: id)
        next.lastSeen = lastSeen
        next.previousSeen = previousSeen
        next.seenAt = seenAt
        next.lastPosed = lastPosed
        next.lastCommit = lastCommit
        next.lastAt = lastAt
        next.rawAt = rawAt
        next.returnedAt = returnedAt
        return next
    }

    /// Le rappel ouvrirait-il un geste, loin de toute écriture ? Alors la
    /// carte a pu rester sur un niveau périmé, et Milō vaut d'être relu.
    func opensGesture(at now: TimeInterval) -> Bool {
        let following = rawAt.map { now - $0 < Self.dragGap } == true
            || returnedAt.map { now - $0 < Self.returnGap } == true
        return !following && now - lastAt > Self.settled
    }

    /// Le niveau qu'un rappel demande : `posed` est ce qu'iOS pose, `shown` ce
    /// que nous lui avions rendu, sans l'écart de confirmation, et `reported`
    /// ce que Milō rapporte, sans notre valeur optimiste.
    ///
    /// Un doigt sur la barre écrit posé ÷ rapport : la barre suit le doigt
    /// d'un bout à l'autre. Un appui écrit **un pas d'iOS depuis Milō**, dans
    /// son sens : au régime normal, c'est exactement le G d'iOS ; quand iOS
    /// engage depuis un affichage périmé, c'est ce qui empêche un « − » de
    /// monter (12/10, 23:29:03) ou trois « − » rapprochés de couper le son
    /// (G parti de ce qu'iOS venait de poser, 0,436 → 0 en 0,9 s au rejeu).
    mutating func obey(posed: Double, shown base: Double, reported: Double? = nil,
                       now: TimeInterval) -> Command {
        // Un doigt : le rappel suit le précédent de près, ou le retour du
        // précédent de quelques millisecondes — iOS attend ce retour, et une
        // écriture lente espacerait sinon les rappels d'un glissement au-delà
        // de `dragGap`.
        let following = rawAt.map { now - $0 < Self.dragGap } == true
            || returnedAt.map { now - $0 < Self.returnGap } == true
        rawAt = now

        // La carte affiche le rendu, écart compris, et iOS engage à partir de
        // lui : à cet écart près, c'est le dernier rendu vu. En bas de course,
        // 0,0005 de trop suffisait à écarter le bon « − » (rapport > 1,04).
        let shown = displayed(base)
        let finger = { (ratio: Double) in min(max(posed / ratio, 0), 1) }
        let candidates = following ? [] : Self.candidates(posed, among: displays(shown, now: now))

        // L'appui qui s'accorde au rapport suivi fait foi. Un autre rapport —
        // le dernier reconnu, 1, ou ce qu'a supposé le rappel d'avant — peut
        // aussi venir d'un doigt qui touche la barre au bon endroit : le 29/10,
        // au rejeu, un toucher à 0,475 sous un rapport de 0,5 se lisait « − »
        // sous 1, et le glissement qui suivait plafonnait à 0,5. Un tel appui
        // fait son pas, mais ne change le rapport que confirmé par le suivant.
        var press = recognize(candidates, priors: [ratio])
        var learned = press != nil
        // Lu à tort en appui, un doigt ne coûte qu'un pas ; lu à tort en doigt,
        // un appui sous un rapport faux irait n'importe où.
        if press == nil, let other = recognize(candidates,
                                               priors: [remembered, 1].compactMap { $0 } + (suspects ?? [])) {
            press = other
            learned = (suspects ?? []).contains { suspect in
                other.ratio.map { abs($0 - suspect) / suspect <= Self.tolerance } ?? false
            }
        }
        // Un rapport faux qui n'est ni le dernier reconnu ni 1 ne reconnaîtrait
        // plus aucun appui : le rejeu du 17/10 à 00:50:25 (vrai rapport 0,909,
        // modèle à 1) plafonnait vers 0,62. Deux appuis isolés qui supposent le
        // même rapport le donnent.
        suspects = learned || candidates.isEmpty ? nil
            : press.flatMap { $0.ratio.map { [$0] } } ?? candidates.compactMap(\.ratio)

        let expected = press.map { $0.commit ?? 0 } ?? finger(ratio)
        if learned, let ratio = press?.ratio { anchor = ratio }

        // iOS vient de prendre `expected` pour plafond et ce qu'il a posé pour
        // référence, sauf à zéro, où il garde ses rapports. Un appui non
        // confirmé n'apprend rien : si c'était un doigt, iOS garde le rapport
        // suivi.
        if expected > Self.silent, press == nil || learned {
            ceiling = expected
            reference = posed
        }
        lastPosed = posed
        lastCommit = expected

        var level = expected
        if let press {
            // Milō, sauf si le rapport de Milō dit autre chose depuis plus d'une
            // seconde sans geste de notre part : une valeur optimiste encore
            // fraîche pouvait cacher un changement fait ailleurs.
            var from = base
            if let reported, now - lastAt > Self.settled, abs(reported - base) > Self.step {
                from = reported
            }
            level = min(max(from + (press.up ? Self.step : -Self.step), 0), 1)
        }
        lastAt = now
        // Un appui reconnu vient de poser plafond et référence : `ratio` est déjà le sien.
        return Command(expected: expected, level: level, press: press, learned: learned, ratio: ratio)
    }

    /// Le retour du rappel, écriture faite : c'est de lui que se mesure le
    /// suivant.
    mutating func returned(at now: TimeInterval) {
        returnedAt = now
    }

    /// Ce que la carte pouvait afficher quand l'appui est parti : notre rendu ;
    /// celui d'avant s'il vient de changer ; et, juste après un rappel, ce
    /// qu'iOS a posé ou attendait.
    private func displays(_ shown: Double, now: TimeInterval) -> [Double] {
        var displays = [shown]
        if now - seenAt < Self.renderLag, let previousSeen { displays.append(previousSeen) }
        if now - lastAt < Self.shownFor { displays += [lastCommit, lastPosed].compactMap { $0 } }
        return displays
    }

    /// Ce que la carte affiche pour `shown` : le dernier rendu, écart de
    /// confirmation compris, quand c'est lui.
    private func displayed(_ shown: Double) -> Double {
        lastSeen.flatMap { abs($0 - shown) <= Self.unnoticed ? $0 : nil } ?? shown
    }

    /// Chaque appui qui a pu poser `posed` : une carte, un sens, et le rapport
    /// qu'il suppose — jamais au-delà de 1, qu'iOS n'emploie pas.
    private static func candidates(_ posed: Double, among displays: [Double]) -> [Reading] {
        displays.flatMap { card in
            [true, false].compactMap { up -> Reading? in
                let commit = min(max(card + (up ? step : -step), 0), 1)
                // Engagé à zéro, iOS pose zéro et garde son rapport.
                guard commit > silent else { return posed <= silent ? Reading(up: up, commit: 0) : nil }
                let ratio = posed / commit
                guard ratio > silent, ratio <= 1 + tolerance else { return nil }
                return Reading(up: up, commit: commit, ratio: ratio)
            }
        }
    }

    /// L'appui qui s'accorde au rapport suivi, au dernier reconnu — qu'un push
    /// a pu faire oublier au premier —, à 1, si iOS est reparti de zéro sans
    /// qu'on le voie (point d'accès recréé), ou à l'un des `suspects`.
    ///
    /// Le critère est le **rapport**, pas le niveau : à rapport faux, l'écart
    /// en niveau grandit avec le niveau, et une tolérance en niveau laissait
    /// passer un rapport de 1 pour 0,909 en bas de course puis le perdait plus
    /// haut (17/10, 00:50:25).
    private func recognize(_ candidates: [Reading], priors: [Double]) -> Reading? {
        for prior in priors {
            if let best = candidates.min(by: { error($0, prior) < error($1, prior) }),
               error(best, prior) <= Self.tolerance {
                return best
            }
        }
        return nil
    }

    /// `anchor`, ou pour un état rangé avant lui, le rapport de son dernier
    /// appui reconnu.
    private var remembered: Double? {
        if let anchor { return anchor }
        guard let lastPosed, let lastCommit, lastPosed > Self.silent, lastCommit > Self.silent
        else { return nil }
        return min(lastPosed / lastCommit, 1)
    }

    /// L'écart relatif d'un appui au rapport `prior` ; nul pour un appui engagé
    /// à zéro, qui s'accorde à tous.
    private func error(_ reading: Reading, _ prior: Double) -> Double {
        reading.ratio.map { abs($0 - prior) / prior } ?? 0
    }
}

extension SystemVolumeModel {

    static let storeKey = "milo_system_volume_model_v1"
    private static let storeLock = NSLock()

    /// Lit, modifie et range l'état, sous verrou : `devices` et l'envoi y
    /// touchent tous deux.
    @discardableResult
    static func update<T>(_ body: (inout SystemVolumeModel) -> T) -> T {
        storeLock.lock()
        defer { storeLock.unlock() }
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)
        var model = defaults?.data(forKey: storeKey)
            .flatMap { try? JSONDecoder().decode(SystemVolumeModel.self, from: $0) }
            ?? SystemVolumeModel()
        let result = body(&model)
        if let data = try? JSONEncoder().encode(model) {
            defaults?.set(data, forKey: storeKey)
        }
        return result
    }
}

extension SystemVolumeModel.Command {
    var summary: String {
        func r(_ level: Double) -> String { String(format: "%.4f", level) }
        var what = press.map { "appui \($0.up ? "+" : "−")\(learned ? "" : " non confirmé")" } ?? "doigt"
        what += " (r=\(r(ratio))) → \(r(level))"
        if abs(level - expected) > 0.000_1 { what += ", iOS attendait \(r(expected))" }
        return what
    }
}

/// Écrit le niveau que chaque rappel attend, le dernier d'abord.
///
/// La carte n'a qu'un appareil, le système Milō : un rappel porte un seul
/// niveau, celui qu'iOS demande pour lui.
private actor VolumeGesture {
    static let shared = VolumeGesture()

    /// Le dernier niveau demandé et pas encore écrit, l'écrivain en cours, et
    /// le dernier niveau écrit avec son heure.
    private var target: Double?
    private var writer: Task<Bool, Never>?
    /// La lecture du dernier rappel arrivé : le suivant l'attend.
    private var intake: Task<Void, Never>?
    private var written: (level: Double, at: TimeInterval)?

    /// Un doigt immobile : iOS rappelle toutes les ~65 ms à quelques
    /// millièmes près (17:37:17, de 0,5708 à 0,5722). Le même niveau, écrit
    /// il y a moins d'une seconde, ne repart pas.
    private static let sameLevel = 0.000_5
    private static let sameFor: TimeInterval = 1

    /// Relit le rappel, demande son niveau, **et attend qu'il soit écrit**.
    ///
    /// L'attente n'est pas une question de style : c'est elle qui garde
    /// l'extension en vie. `mediaremoted` la termine quelques millisecondes
    /// après l'avoir lue — mesuré le 19/09/2026, six millisecondes entre la
    /// lecture et le `RBSTerminateRequest`. Une écriture posée dans une tâche
    /// détachée que personne n'attend meurt donc avec le processus, et c'est la
    /// **dernière** valeur du geste qui se perdait ainsi : celle qui compte.
    ///
    /// Aucune pause avant d'écrire : iOS n'envoie le rappel suivant qu'une fois
    /// celui-ci rendu, et attendre 110 ms espaçait les rappels d'un doigt à
    /// ~150 ms (29/10, 17:56:02).
    ///
    /// Rend `true` quand l'écrivain que ce rappel a attendu a écrit quelque
    /// chose : il y a du neuf à faire relire.
    func record(posed: Double, shown: Double, reported: Double) async -> Bool {
        // L'arrivée du rappel, prise avant la relecture : chaque fenêtre du
        // modèle — rendu d'avant, ce qu'iOS vient de poser — se mesure à
        // partir d'elle. Prise après, une relecture d'une demi-seconde faisait
        // oublier l'affichage d'où iOS était parti, et l'appui redevenait un
        // doigt écrit en absolu.
        let now = Date().timeIntervalSince1970

        // À la file : la relecture suspend l'acteur, et un rappel arrivé
        // pendant ce temps aurait pu passer `obey` avant celui-ci — qui se
        // serait alors lu « doigt », dans le sillage de l'autre. Chacun
        // attend que le précédent ait été lu.
        let previous = intake
        let reading = Task { () -> SystemVolumeModel.Command in
            await previous?.value
            var reported = reported
            // Le niveau de Milō, relu au début d'un geste : celui des
            // attributs ne vaut que ce que vaut le dernier push, et le 30/10
            // aucun n'arrivait plus — un appui reconnu serait parti du
            // plancher au lieu du volume monté sur Milo-Mac. Un aller-retour
            // sur le LAN, une fois par geste ; en cas d'échec, on garde celui
            // des attributs.
            if SystemVolumeModel.update({ $0.opensGesture(at: now) }),
               let fresh = await MiloAPIClient.currentGlobalVolume() {
                if abs(fresh - reported) > SystemVolumeModel.step {
                    MiloAPIClient.trace?("Milō relu à \(Self.rounded(fresh)), carte à \(Self.rounded(reported))")
                }
                reported = fresh
            }
            return SystemVolumeModel.update {
                $0.obey(posed: posed, shown: shown, reported: reported, now: now)
            }
        }
        intake = Task { _ = await reading.value }
        let command = await reading.value
        MiloAPIClient.trace?(command.summary)

        // Posé avant le réseau : un push parti avant l'écriture ne doit pas
        // ramener la carte en arrière sous le doigt.
        MiloAPIClient.noteOptimistic(mac: MiloAPIClient.systemDeviceID, level: command.level)
        target = command.level
        let wrote: Bool
        if let writer {
            wrote = await writer.value
        } else {
            let writer = Task { [weak self] () -> Bool in
                await self?.drain() ?? false
            }
            self.writer = writer
            wrote = await writer.value
        }
        let end = Date().timeIntervalSince1970
        SystemVolumeModel.update { $0.returned(at: end) }
        return wrote
    }

    /// Écrit le dernier niveau demandé tant qu'il en arrive. Un seul écrivain
    /// à la fois : un niveau dépassé en route n'est jamais écrit.
    private func drain() async -> Bool {
        var wrote = false
        let system = MiloAPIClient.systemDeviceID
        while let level = target {
            target = nil
            let now = Date().timeIntervalSince1970
            if let written, abs(written.level - level) < Self.sameLevel,
               now - written.at < Self.sameFor { continue }
            let outcome = await MiloAPIClient.setGlobalVolume(level)
            written = (level, now)
            wrote = true
            switch outcome {
            case .applied(let applied):
                // Un niveau plus récent est déjà posé : il ne faut pas
                // l'écraser par celui-ci.
                if target == nil { MiloAPIClient.noteOptimistic(mac: system, level: applied) }
                MiloAPIClient.trace?("Milō → \(Self.rounded(applied))")
            case .appliedUnknown:
                MiloAPIClient.trace?("Milō → niveau à venir par le push")
            case .failed:
                written = nil
                if target == nil { MiloAPIClient.forgetOptimistic(macs: [system]) }
                MiloAPIClient.trace?("Milō → \(Self.rounded(level)) : échec")
            }
        }
        // Sans `await` depuis le dernier test : une demande arrivée entre-temps
        // aurait trouvé l'écrivain et l'attendrait sans être écrite.
        writer = nil
        return wrote
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
/// détachées, puis ne l'a plus appelé du tout. Aujourd'hui, deux appelants y
/// touchent en même temps dans l'app : la boucle de sondage, et le préchargement
/// des logos de favorites (`primeFavoriteStationArtwork`), lancé dans sa propre
/// tâche à côté d'elle. L'acteur est donc ce qui sépare leurs mutations.
///
/// Il resterait même s'il n'y en avait plus qu'un. Deux mutations concurrentes
/// d'un `Dictionary` Swift ne donnent pas une valeur périmée, elles corrompent
/// la mémoire : c'est une panne dont le coût ne se compare pas à celui d'un
/// acteur, et une invariante de sûreté n'a pas à dépendre de la liste des
/// appelants qui existent ce matin.
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
    /// pas. La vérification de présence ne regardait alors que la taille, et ces
    /// entrées auraient été réutilisées pour toujours. Elle juge désormais le
    /// cache sur ses octets d'en-tête (`cacheArtwork`), qui écarteraient aussi
    /// un WebP ; la purge reste pour le cache que ces versions ont laissé.
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
