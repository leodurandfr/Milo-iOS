import CoreGraphics
import Foundation
import ImageIO

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

    /// Source active du moment, telle que `/api/audio/state` la nomme.
    ///
    /// `/api/audio/control/{source}` s'adresse à une source précise : il n'existe
    /// pas de « commande au système ».
    ///
    /// **Chemin de repli, plus le chemin nominal.** Cet aller-retour-là était
    /// posé devant chaque commande, et c'est lui qui les faisait échouer :
    /// `mediaremoted` accorde trois secondes à un rappel de commande (mesuré le
    /// 19/09/2026 — `Completed command (3.0s)`, puis `Allowing extra 1.0s`), et
    /// deux requêtes de trois secondes chacune n'y tiennent pas. Quand la
    /// résolution mDNS de `milo.local` partait scopée sur la mauvaise interface
    /// — `getaddrinfo start -- ifindex: 12`, jamais de réponse, contre 2 à 33 ms
    /// pour `ifindex: 0` — celle-ci consommait le budget entier et le `POST` ne
    /// partait jamais. Play échouait, Pause passait, sans rien qui les
    /// distingue : une course, perdue une fois sur deux.
    ///
    /// L'appelant connaît déjà la source — les attributs de session la portent
    /// dans `currentTrack.id`, sous la forme `<source>:<titre>`. On ne relit ici
    /// que lorsqu'il n'en a aucune à donner.
    private static func activeSource() async -> String? {
        guard let data = try? await get(path: "/api/audio/state", timeout: sourceReadTimeout),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["active_source"] as? String
    }

    /// Délai d'une requête partie d'un rappel de commande.
    ///
    /// Sous les trois secondes que le système accorde, pour qu'un échec soit
    /// *consigné* avant que le processus ne meure plutôt que de disparaître
    /// avec lui. Ce n'est pas une marge de confort : c'est la différence entre
    /// une trace et un silence.
    static let commandTimeout: TimeInterval = 2.5

    /// Ce qu'on accorde à la relecture de la source, quand l'appelant n'en
    /// connaît aucune.
    ///
    /// Elle précède le POST au lieu de le remplacer : les deux délais
    /// s'additionnent, et deux fois `commandTimeout` faisait cinq secondes dans
    /// un budget de trois — le repli ne pouvait pas aboutir précisément dans le
    /// cas pour lequel il existe. Ce qu'on retire ici est retiré du POST qui
    /// suit, de sorte que la somme reste sous `commandTimeout`.
    static let sourceReadTimeout: TimeInterval = 1

    /// Envoie une commande de transport. Sans effet si aucune source n'est active.
    ///
    /// `source` est celle que l'appelant connaît déjà ; `nil` déclenche la
    /// relecture, qui coûte un aller-retour et le budget qui va avec.
    ///
    /// Une unité qui ne connaît pas encore `next`/`prev` en radio répond HTTP
    /// 400 : un refus propre. Il est désormais consigné — un bouton qui ne fait
    /// rien ne disait pas s'il avait été refusé, s'il avait expiré, ou s'il
    /// n'était jamais parti, et ce sont trois corrections différentes.
    static func fireTransport(_ command: TransportCommand, source: String? = nil) async {
        // `??` prend son côté droit en autoclosure, qui ne peut rien attendre :
        // la relecture s'écrit donc en clair.
        var resolved = source
        var budget = commandTimeout
        if resolved == nil {
            resolved = await activeSource()
            budget -= sourceReadTimeout
        }
        guard let source = resolved else {
            noteCommand("\(command) : aucune source active")
            return
        }
        guard let name = command.name(forSource: source) else {
            noteCommand("\(command) : sans équivalent en \(source)")
            return
        }
        let body = try? JSONSerialization.data(withJSONObject: ["command": name])
        await sendControl(source: source, body: body, label: name, timeout: budget,
                          retryable: command.isIdempotent)
    }

    /// Déplace la tête de lecture. Milō attend des millisecondes ; le système,
    /// lui, raisonne en secondes.
    static func fireSeek(toSeconds position: TimeInterval, source: String? = nil) async {
        var resolved = source
        var budget = commandTimeout
        if resolved == nil {
            resolved = await activeSource()
            budget -= sourceReadTimeout
        }
        guard let source = resolved, source != "radio" else { return }
        let body = try? JSONSerialization.data(withJSONObject: [
            "command": "seek",
            "data": ["position_ms": Int(position * 1000)]
        ])
        // Un `seek` porte une position absolue : le rejouer vise le même point.
        await sendControl(source: source, body: body, label: "seek", timeout: budget,
                          retryable: true)
    }

    /// L'envoi lui-même, tracé à l'entrée comme à la sortie.
    ///
    /// Tracer seulement le succès ne prouve rien : c'est ce qui a fait conclure
    /// deux fois « la fermeture n'est jamais appelée » alors qu'elle l'était et
    /// mourait en route.
    private static func sendControl(source: String, body: Data?, label: String,
                                    timeout: TimeInterval = commandTimeout,
                                    retryable: Bool) async {
        guard let url = URL(string: baseURL() + "/api/audio/control/\(source)") else {
            noteCommand("\(label) → \(source) : URL inconstructible")
            return
        }
        noteCommand("\(label) → \(source) : envoi")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

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
        //   où une seule aboutissait. `fireTransport` retire déjà
        //   `sourceReadTimeout` quand il a dû relire la source : couper en deux
        //   ce qui reste donnerait 750 ms par essai. En dessous du seuil, on
        //   garde une seule tentative longue.
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
                let (data, response) = try await lan.data(for: request)
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
    static func setClientVolume(mac: String, normalized level: Float) async {
        let limits = volumeLimits()
        let clamped = min(max(Double(level), 0), 1)
        let db = limits.min + clamped * (limits.max - limits.min)

        // Valeur optimiste posée tout de suite, elle : la session est rafraîchie
        // en boucle depuis Milō, et une lecture partie avant que l'écriture
        // atterrisse repousserait l'ancien niveau — le curseur reculerait sous
        // le doigt. Même remède que `lastInteractionKey` côté widget.
        let plain = mac.replacingOccurrences(of: ":", with: "")
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(db, forKey: optimisticVolumeKey(plain))
        defaults?.set(Date().timeIntervalSince1970, forKey: optimisticVolumeAtKey(plain))

        await VolumeWriter.shared.write(mac: plain, db: db)
    }

    /// L'écriture elle-même, une fois le geste retombé.
    fileprivate static func writeClientVolume(mac plain: String, db: Double) async {
        guard let url = URL(string: baseURL() + "/api/volume/client/mac/\(plain)")
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["volume_db": db])

        // Le code est lu, contrairement aux commandes de transport. La route
        // répond 400 hors des bornes au lieu de borner, et un curseur qui revient
        // en place sans rien dire est précisément comment l'encodage du MAC est
        // resté invisible.
        let defaults = UserDefaults(suiteName: appGroupID)
        do {
            let (_, response) = try await lan.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 {
                defaults?.removeObject(forKey: "milo_volume_write_error")
            } else {
                defaults?.set("volume \(plain) -> HTTP \(code)", forKey: "milo_volume_write_error")
            }
        } catch {
            defaults?.set("volume \(plain) -> réseau : \(error.localizedDescription)",
                          forKey: "milo_volume_write_error")
        }
    }

    // MARK: - Valeur optimiste

    /// Durée pendant laquelle l'affichage préfère ce qu'on vient de demander à ce
    /// que Milō rapporte. Assez longue pour couvrir l'aller-retour et le cycle de
    /// rafraîchissement, assez courte pour qu'un refus du serveur redevienne
    /// visible plutôt que d'être masqué indéfiniment.
    static let optimisticVolumeWindow: TimeInterval = 3

    static func optimisticVolumeKey(_ mac: String) -> String { "milo_opt_vol_\(mac)" }
    static func optimisticVolumeAtKey(_ mac: String) -> String { "milo_opt_at_\(mac)" }

    /// Le niveau qu'on vient de demander pour cette enceinte, s'il est assez
    /// récent pour faire autorité sur ce que Milō rapporte.
    static func optimisticVolume(mac: String) -> Double? {
        let plain = mac.replacingOccurrences(of: ":", with: "")
        let defaults = UserDefaults(suiteName: appGroupID)
        guard let at = defaults?.object(forKey: optimisticVolumeAtKey(plain)) as? Double,
              Date().timeIntervalSince1970 - at < optimisticVolumeWindow,
              let db = defaults?.object(forKey: optimisticVolumeKey(plain)) as? Double
        else { return nil }
        return db
    }
}

/// Ne garde que la dernière valeur demandée par enceinte.
///
/// Une tâche par enceinte, annulée et remplacée à chaque nouvel événement : au
/// repos du geste, une seule écriture part par enceinte, avec la valeur que le
/// doigt a laissée. Les enceintes ne se gênent pas entre elles — une rafale qui
/// en oublie une ne doit pas empêcher les autres d'aboutir.
private actor VolumeWriter {
    static let shared = VolumeWriter()

    private var tasks: [String: Task<Void, Never>] = [:]

    /// Assez long pour absorber une rafale, assez court pour que le son suive le
    /// doigt d'assez près.
    private static let quietPeriod = Duration.milliseconds(180)

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
    /// Les entrées de `tasks` ne sont pas retirées : le dictionnaire est indexé
    /// par enceinte, donc borné par leur nombre. Le nettoyer demanderait de
    /// distinguer sa propre tâche de celle qui l'a remplacée, pour rien.
    func write(mac: String, db: Double) async {
        tasks[mac]?.cancel()
        let task = Task {
            try? await Task.sleep(for: Self.quietPeriod)
            guard !Task.isCancelled else { return }
            await MiloAPIClient.writeClientVolume(mac: mac, db: db)
        }
        tasks[mac] = task
        await task.value
    }
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
