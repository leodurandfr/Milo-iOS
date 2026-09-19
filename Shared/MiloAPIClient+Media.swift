import Foundation

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

        let ids = stations.compactMap { $0["id"] as? String }
        guard let index = ids.firstIndex(of: currentID) else { return }

        // Modulo plutôt que borne : arrivé au bout de la liste, on revient au
        // début. Un bouton qui ne fait rien une fois sur vingt-deux serait pris
        // pour une panne.
        let next = (index + (forward ? 1 : -1) + ids.count) % ids.count
        let body = try? JSONSerialization.data(withJSONObject: [
            "command": "play_station",
            "data": ["station_id": ids[next], "station": stations[next]]
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

        await VolumeWriter.shared.schedule(mac: plain, db: db)
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

    func schedule(mac: String, db: Double) {
        tasks[mac]?.cancel()
        tasks[mac] = Task {
            try? await Task.sleep(for: Self.quietPeriod)
            guard !Task.isCancelled else { return }
            await MiloAPIClient.writeClientVolume(mac: mac, db: db)
        }
    }
}
