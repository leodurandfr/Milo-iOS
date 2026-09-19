import Foundation
import NowPlaying

/// Ouvre et entretient la session Now Playing pendant que l'app tourne.
///
/// C'est le chemin **sans APNs** : `RemoteMediaSession.update(_:)` est un appel
/// local, et tant que l'app est au premier plan il n'y a aucune raison de passer
/// par Apple pour un état qu'on peut lire directement sur le LAN.
///
/// Le push reste indispensable pour la suite — quand l'app est tuée, seule
/// l'extension réveillée par APNs peut entretenir la session. Mais les deux
/// chemins aboutissent au même endroit : le système demande à l'extension de
/// construire la session, ici comme là.
@available(iOS 27, *)
@MainActor
enum MiloNowPlayingBridge {

    private static var session: RemoteMediaSession<MiloSessionAttributes>?

    /// Trace du dernier essai, lisible depuis le Mac via le conteneur de l'app.
    /// Sans elle, un `start` refusé est indiscernable d'un `start` jamais tenté.
    private static let statusKey = "milo_nowplaying_status"

    private static var pump: Task<Void, Never>?

    /// Ce qui, dans les attributs, change réellement ce qui est affiché.
    private static var lastSignature = ""

    /// Dernière position connue, l'instant qu'elle décrivait, et si ça jouait.
    /// Sert uniquement à `positionJumped(_:)`.
    private static var lastElapsed: TimeInterval?
    private static var lastCapturedAt = Date.distantPast
    private static var lastWasPlaying = false

    /// Au-delà de trois secondes, l'écart ne s'explique plus par le temps qui
    /// passe ni par la gigue du réseau.
    private static let seekTolerance: TimeInterval = 3

    /// La position a-t-elle bougé autrement qu'en avançant toute seule ?
    ///
    /// La position est exclue de `displaySignature`, et c'est justifié : elle
    /// change en permanence, et l'annoncer à chaque passe ferait reconstruire la
    /// session toutes les deux secondes pour ne rien dire de neuf.
    ///
    /// Mais un `seek` fait **ailleurs** — depuis l'app, l'écran de Milō, un
    /// autre client — la déplace d'un coup sans toucher à aucun autre champ.
    /// Rien ne l'annonçait, et la tête de lecture continuait d'interpoler depuis
    /// un horodatage périmé jusqu'au changement de piste. On compare donc la
    /// position reçue à celle qu'on extrapolait.
    ///
    /// **Met à jour son propre état de suivi** : à appeler exactement une fois
    /// par passe, et avant toute sortie anticipée.
    private static func positionJumped(_ a: MiloSessionAttributes) -> Bool {
        defer {
            lastElapsed = a.elapsedTime
            lastCapturedAt = a.capturedAt
            lastWasPlaying = a.isPlaying
        }
        guard let previous = lastElapsed else { return false }

        // Un flux n'a pas de tête de lecture : `duration` y vaut 0 et
        // `elapsedTime` reste à zéro pour toujours. L'extrapolation, elle,
        // continue d'avancer — si bien que toute passe un peu espacée
        // (arrière-plan, réseau lent) serait lue comme un saut et
        // reconstruirait la session pour rien, exactement ce que la signature
        // est là pour éviter. Rien à comparer, donc rien à annoncer.
        guard (a.currentTrack?.duration ?? 0) > 0 else { return false }

        // À l'arrêt, rien ne doit avoir avancé. Une bascule lecture/pause change
        // déjà la signature, donc elle pousse de toute façon.
        let advance = lastWasPlaying ? a.capturedAt.timeIntervalSince(lastCapturedAt) : 0
        return abs(a.elapsedTime - (previous + advance)) > seekTolerance
    }

    private static func displaySignature(_ a: MiloSessionAttributes) -> String {
        let track = a.currentTrack
        let speakers = a.devices
            .map { "\($0.id)=\(Int(($0.volume * 1000).rounded()))" }
            .joined(separator: ",")
        return [
            a.isPlaying ? "1" : "0",
            track?.id ?? "-",
            track?.title ?? "-",
            track?.artist ?? "-",
            track?.album ?? "-",
            track?.artworkURL ?? "-",
            String(Int((track?.duration ?? 0).rounded())),
            speakers
        ].joined(separator: "|")
    }

    /// Entretient la session tant que l'app est au premier plan.
    ///
    /// Sans ça, la session gardait ce qui était vrai au lancement : on voyait
    /// encore la piste Spotify d'avant pendant que la bibliothèque musicale
    /// jouait. Le vrai entretien, à terme, ce sont les `update` poussés par
    /// Milō ; cette boucle est ce qui tient pendant que l'app est ouverte, et
    /// elle s'arrête dès qu'elle ne l'est plus — interroger Milō toutes les deux
    /// secondes depuis l'arrière-plan ne servirait qu'à vider la batterie.
    ///
    /// `startPump` part de **deux** endroits — `didFinishLaunching` et
    /// `sceneDidBecomeActive` — et les deux se suivent de près au démarrage à
    /// froid. Annuler la boucle précédente ne suffit pas : l'annulation n'arrête
    /// pas un `refresh()` déjà engagé au-delà de ses `await`, si bien que deux
    /// passes pouvaient se chevaucher — deux `RemoteMediaSession.start`
    /// concurrents, ou un balayage des sessions résiduelles qui ferme celle que
    /// l'autre venait tout juste de stocker.
    ///
    /// La nouvelle boucle attend donc que l'ancienne ait vraiment rendu la main
    /// avant de commencer. `refresh()` n'est jamais réentrant.
    static func startPump() {
        let previous = pump
        // Annulée ici, de façon synchrone, et pas depuis la nouvelle tâche : un
        // `stopPump()` immédiat annulerait celle-ci avant qu'elle n'exécute sa
        // première ligne, et l'ancienne boucle tournerait alors pour toujours.
        previous?.cancel()

        pump = Task {
            await previous?.value

            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    static func stopPump() {
        pump?.cancel()
        // `pump` n'est **pas** remis à nil : c'est la référence dont le prochain
        // `startPump` a besoin pour attendre que cette boucle-ci ait vraiment
        // rendu la main. L'oublier ici rouvrait la fenêtre de chevauchement à
        // chaque aller-retour arrière-plan → premier plan, qui est de loin le
        // chemin le plus fréquent — bien plus que le double départ au lancement.
        // Une tâche terminée ne coûte que sa référence.
    }

    static func refresh() async {
        guard let attributes = await buildAttributes() else {
            note("pas d'état exploitable depuis Milō")
            return
        }

        // Ne pousser que ce qui change l'affichage.
        //
        // Pousser toutes les deux secondes faisait reconstruire la session à
        // chaque fois — mesuré, quatre fois en deux secondes — et chaque
        // reconstruction jette l'objet `Artwork` en cours avec son
        // téléchargement : la pochette n'avait jamais le temps d'arriver.
        //
        // La position n'entre pas dans la signature, délibérément : elle change
        // en permanence, et `MediaPlaybackSnapshot` porte déjà un horodatage à
        // partir duquel le système interpole. L'annoncer à chaque seconde ne
        // dirait rien de plus et coûterait tout.
        // `positionJumped` met à jour son propre suivi : l'appeler une fois par
        // passe, avant toute sortie anticipée.
        let jumped = positionJumped(attributes)
        let signature = displaySignature(attributes)
        if session != nil, signature == lastSignature, !jumped { return }

        do {
            if let session {
                do {
                    try await session.update(attributes)
                } catch {
                    // Une session que Milō ou le système a close continue de
                    // refuser chaque `update`. La garder rendait la branche
                    // `start` inatteignable pour toujours : l'écran verrouillé
                    // restait vide jusqu'au prochain lancement de l'app. On la
                    // lâche, et la passe suivante en rouvre une.
                    Self.session = nil
                    lastSignature = ""
                    note("update refusé, session lâchée : \(error)")
                    return
                }
                lastSignature = signature
                note("update ok (\(attributes.id))")
            } else {
                // Terminer ce qui traîne avant d'ouvrir. Le framework met en
                // cache les sessions rendues par l'extension et leur route les
                // mises à jour suivantes : une session ouverte par un lancement
                // précédent survit, et le système continue de parler à
                // l'instance d'alors — avec le code d'alors. En développement ça
                // fait exécuter une version périmée de l'extension ; en usage
                // normal ça laisse une session orpheline que plus personne
                // n'entretient.
                for stale in try await RemoteMediaSession<MiloSessionAttributes>.sessions() {
                    try? await stale.end()
                }

                let fresh = try await RemoteMediaSession.start(attributes: attributes)
                session = fresh
                // Ne vaut que depuis le premier plan : en arrière-plan la
                // demande est ignorée, sans erreur.
                try await fresh.requestToBecomeSystemPrimary()
                lastSignature = signature
                note("start ok (\(attributes.id)), primary demandé")
            }
        } catch {
            note("échec : \(error)")
        }
    }

    /// Ferme la session. Milō décide normalement de sa fin, mais une session
    /// ouverte localement doit pouvoir l'être aussi.
    static func end() async {
        guard let session else { return }
        try? await session.end()
        self.session = nil
    }

    // MARK: - Construction

    private static func buildAttributes() async -> MiloSessionAttributes? {
        guard let audioData = try? await MiloAPIClient.get(path: "/api/audio/state"),
              let audio = try? JSONSerialization.jsonObject(with: audioData) as? [String: Any]
        else { return nil }

        let metadata = audio["metadata"] as? [String: Any]
        let isPlaying = metadata?["is_playing"] as? Bool ?? false

        // Millisecondes côté Milō, secondes côté framework.
        let positionMS = metadata?["position"] as? Double ?? 0
        let durationMS = metadata?["duration"] as? Double ?? 0

        var track: MiloSessionAttributes.Track?
        if let metadata, !metadata.isEmpty {
            // Le modèle de Milō définit un socle commun — title, artist, album,
            // album_art_url — présenté comme le contrat entre sources. Toutes ne
            // le remplissent pas : la radio laisse ces quatre champs vides et
            // fait voyager le morceau en extras (`track_title`, `track_artist`,
            // `station_name`, `favicon`). D'où cette lecture en cascade, qui ne
            // nomme aucune source en particulier : elle prend le socle quand il
            // est là, et se rabat sinon sur les noms observés à côté.
            //
            // À retirer le jour où toutes les sources remplissent le socle. Ce
            // n'est pas une préférence de style : tant qu'elle est là, chaque
            // client réimplémente la même cascade, ce que le socle existe
            // justement pour éviter.
            func first(_ keys: String...) -> String? {
                for key in keys {
                    if let value = metadata[key] as? String, !value.isEmpty { return value }
                }
                return nil
            }

            let title = first("title", "track_title", "station_name")
            track = MiloSessionAttributes.Track(
                // L'identifiant change avec ce qui est affiché : sans ça, le
                // système garde la pochette et le titre précédents, faute de
                // savoir que le contenu a changé.
                id: (audio["active_source"] as? String ?? "milo") + ":" + (title ?? "-"),
                title: title,
                artist: first("artist", "track_artist"),
                album: first("album", "station_name"),
                duration: durationMS / 1000,
                artworkURL: first("album_art_url", "track_artwork", "favicon")
            )

            // La déposer avant d'annoncer la session : l'extension la lira sur
            // disque, sans réseau ni délai.
            if let artwork = track?.artworkURL {
                await MiloAPIClient.cacheArtwork(from: artwork)
            }
        }

        return MiloSessionAttributes(
            // Stable tant que l'app vit : la session survit au changement de
            // piste et de source, elle ne se rouvre pas à chaque morceau.
            id: sessionID,
            isPlaying: isPlaying,
            elapsedTime: positionMS / 1000,
            timestamp: ISO8601DateFormatter().string(from: .now),
            currentTrack: track,
            devices: await buildDevices()
        )
    }

    private static let sessionID = UUID().uuidString

    /// Un device par client snapcast, avec son vrai nom.
    ///
    /// Les noms ne sont pas dans `/api/volume/state` — seules les zones y sont
    /// nommées, si bien que deux enceintes d'une même zone s'appelaient toutes
    /// deux « Salon ». Ils vivent dans `/api/multiroom/state`, qui donne aussi
    /// `online` et `volume_control` : une enceinte éteinte n'a rien à faire dans
    /// la liste, et une enceinte sans contrôle de volume ne doit pas afficher un
    /// curseur qui ne fera rien.
    private static func buildDevices() async -> [MiloSessionAttributes.Device] {
        async let volumeTask = MiloAPIClient.get(path: "/api/volume/state")
        async let roomsTask = MiloAPIClient.get(path: "/api/multiroom/state")

        guard let volumeData = try? await volumeTask,
              let volumeJSON = try? JSONSerialization.jsonObject(with: volumeData) as? [String: Any],
              let payload = volumeJSON["data"] as? [String: Any],
              let clients = payload["clients"] as? [String: [String: Any]]
        else { return [] }

        let rooms = (try? await roomsTask)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0?["clients"] as? [String: [String: Any]] } ?? [:]

        let limits = MiloAPIClient.volumeLimits()
        let span = limits.max - limits.min

        return clients.keys.sorted().compactMap { mac -> MiloSessionAttributes.Device? in
            let room = rooms[mac]
            guard room?["online"] as? Bool ?? true else { return nil }
            guard room?["volume_control"] as? Bool ?? true else { return nil }

            // Ce qu'on vient de demander l'emporte sur ce que Milō rapporte
            // pendant quelques secondes : sinon cette boucle repousse un niveau
            // lu avant l'écriture, et le curseur recule sous le doigt.
            let db = MiloAPIClient.optimisticVolume(mac: mac)
                ?? clients[mac]?["volume_db"] as? Double ?? limits.min
            let normalized = span > 0 ? (db - limits.min) / span : 0
            return MiloSessionAttributes.Device(
                id: mac,
                name: room?["name"] as? String ?? "Milō \(mac.suffix(5))",
                type: "speaker",
                volume: Float(min(max(normalized, 0), 1))
            )
        }
    }

    private static func note(_ message: String) {
        UserDefaults(suiteName: MiloAPIClient.appGroupID)?
            .set(message, forKey: statusKey)
    }
}
