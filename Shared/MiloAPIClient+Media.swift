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

        /// Chaque source a sa propre table de commandes, et la radio n'a rien de
        /// commun avec les autres : elle n'accepte que `play_station`, `stop` et
        /// `resume_playback`. Lui envoyer `pause` ou `resume` la laissait inerte,
        /// puisqu'une commande inconnue est simplement refusée.
        ///
        /// Un flux ne se met pas en pause, il s'arrête : mettre `stop` derrière
        /// le bouton pause est ce que l'appareil fait déjà de son côté, et la
        /// reprise relance la station.
        func name(forSource source: String) -> String? {
            guard source == "radio" else {
                switch self {
                case .play: return "resume"
                case .pause: return "pause"
                case .playPause: return "playpause"
                case .next: return "next"
                case .previous: return "prev"
                }
            }
            switch self {
            case .play: return "resume_playback"
            case .pause: return "stop"
            // `playpause` n'existe pas côté radio, et `next`/`previous` n'y sont
            // pas des commandes : ils changent de station, ce qui passe par
            // `play_station` et se traite ailleurs.
            case .playPause, .next, .previous: return nil
            }
        }
    }

    /// Source active du moment, telle que `/api/audio/state` la nomme.
    ///
    /// `/api/audio/control/{source}` s'adresse à une source précise : il n'existe
    /// pas de « commande au système ». On relit donc la source courante juste
    /// avant, plutôt que de mémoriser celle du dernier push — elle peut avoir
    /// changé sous nos pieds, et la session survit justement à ce changement.
    private static func activeSource() async -> String? {
        guard let data = try? await get(path: "/api/audio/state"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["active_source"] as? String
    }

    /// Envoie une commande de transport. Sans effet si aucune source n'est active.
    static func fireTransport(_ command: TransportCommand) async {
        guard let source = await activeSource() else { return }

        // En radio, précédent et suivant ne sont pas des commandes de transport :
        // ils font défiler les stations favorites.
        if source == "radio", command == .next || command == .previous {
            await stepFavoriteStation(forward: command == .next)
            return
        }

        guard let name = command.name(forSource: source) else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["command": name])
        _ = try? await post(path: "/api/audio/control/\(source)", body: body)
    }

    /// Passe à la station favorite voisine, en boucle.
    ///
    /// Un flux n'a ni piste précédente ni piste suivante ; les deux boutons
    /// resteraient donc morts. Les faire défiler les favoris leur rend un sens
    /// évident depuis l'écran verrouillé, là où ouvrir l'app pour changer de
    /// station coûte bien plus cher.
    private static func stepFavoriteStation(forward: Bool) async {
        async let stateTask = get(path: "/api/audio/state")
        async let listTask = get(path: "/api/radio/stations?favorites_only=true", timeout: 6)

        guard let stateData = try? await stateTask,
              let state = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
              let metadata = state["metadata"] as? [String: Any],
              let currentID = metadata["station_id"] as? String,
              let listData = try? await listTask,
              let list = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let stations = list["stations"] as? [[String: Any]],
              !stations.isEmpty
        else { return }

        // Filtrer les stations elles-mêmes, plutôt que d'en extraire une liste
        // d'identifiants à côté.
        //
        // Un `compactMap` sur les seuls `id` donne une liste plus courte que
        // `stations` dès qu'un favori n'en porte pas, et les deux sont ensuite
        // indexées du même entier : on enverrait alors l'identifiant d'une
        // station avec le corps d'une autre — et Milō jouerait la mauvaise.
        // Garder un seul tableau rend le décalage impossible à écrire.
        let usable = stations.filter { $0["id"] is String }
        guard let index = usable.firstIndex(where: { $0["id"] as? String == currentID })
        else { return }

        // Modulo plutôt que borne : arrivé au bout de la liste, on revient au
        // début. Un bouton qui ne fait rien une fois sur vingt-deux serait pris
        // pour une panne.
        let station = usable[(index + (forward ? 1 : -1) + usable.count) % usable.count]
        guard let nextID = station["id"] as? String else { return }
        let body = try? JSONSerialization.data(withJSONObject: [
            "command": "play_station",
            "data": ["station_id": nextID, "station": station]
        ])
        _ = try? await post(path: "/api/audio/control/radio", body: body, timeout: 6)
    }

    /// Déplace la tête de lecture. Milō attend des millisecondes ; le système,
    /// lui, raisonne en secondes.
    static func fireSeek(toSeconds position: TimeInterval) async {
        guard let source = await activeSource(), source != "radio" else { return }
        let body = try? JSONSerialization.data(withJSONObject: [
            "command": "seek",
            "data": ["position_ms": Int(position * 1000)]
        ])
        _ = try? await post(path: "/api/audio/control/\(source)", body: body)
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
            let (_, response) = try await URLSession.shared.data(for: request)
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

// MARK: - Pochettes en cache

extension MiloAPIClient {

    /// Dossier partagé où l'app dépose les pochettes pour l'extension.
    static func artworkCacheDirectory() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return nil }
        let dir = container.appendingPathComponent("artwork", isDirectory: true)
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
        // Présence et taille suffisent : le contenu est garanti affichable au
        // moment où on l'écrit, pas relu ici. Cette fonction repasse toutes les
        // deux secondes ; y relire chaque pochette pour en inspecter trois
        // octets se paierait sans rien apprendre.
        if let size = (try? FileManager.default
            .attributesOfItem(atPath: file.path)[.size]) as? Int, size > 0 {
            note("déjà en cache (\(size) o) \(file.path)")
            return true
        }

        let absolute = urlString.hasPrefix("/") ? baseURL() + urlString : urlString
        guard let url = URL(string: absolute) else {
            note("URL invalide : \(absolute)"); return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, !data.isEmpty else {
                note("HTTP \(code), \(data.count) o"); return false
            }
            // Un format qu'ImageIO ne sait pas décoder — un SVG, par exemple —
            // est déposé tel quel. Il ne s'affichera pas, mais rien ne le
            // rendrait affichable, et **ne rien écrire rouvrirait la boucle** :
            // le cache resterait vide, et cette fonction retéléchargerait la
            // même image toutes les deux secondes, indéfiniment.
            let payload = jpegNormalized(data) ?? data
            try payload.write(to: file, options: .atomic)
            note("déposé \(payload.count) o dans \(file.path)"
                 + (payload.count == data.count && !isJPEG(payload) ? " (non converti)" : ""))
            return true
        } catch {
            note("échec \(url.lastPathComponent) : \(error.localizedDescription)")
            return false
        }
    }

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
        guard defaults?.integer(forKey: artworkCacheGenerationKey) != 1,
              let dir = artworkCacheDirectory()
        else { return }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        defaults?.set(1, forKey: artworkCacheGenerationKey)
    }

    /// Les trois octets d'en-tête d'un JFIF/Exif.
    private static func isJPEG(_ data: Data) -> Bool {
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
