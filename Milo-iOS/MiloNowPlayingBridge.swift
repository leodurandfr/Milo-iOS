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

    /// Les sessions dont on a constaté qu'elles refusent leurs `update`.
    ///
    /// Un ensemble, et pas un seul identifiant : `sessions()` peut en énumérer
    /// plusieurs mortes à la fois, et n'en écarter qu'une ferait reprendre la
    /// suivante au tour d'après. Vidé dès qu'un `update` aboutit — un
    /// identifiant écarté pour toujours interdirait de reprendre une session
    /// que le système aurait légitimement rouverte sous le même nom.
    private static var disowned: Set<String> = []

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
    /// jouait.
    ///
    /// Cette boucle ne tient que pendant que l'app est ouverte, et elle s'arrête
    /// dès qu'elle ne l'est plus — interroger Milō toutes les deux secondes
    /// depuis l'arrière-plan ne servirait qu'à vider la batterie. Le relais,
    /// c'est le push : Milō pousse ses `update` à la session, et c'est ce qui
    /// tient l'écran verrouillé. Tant que ce relais était muet, l'arrêt de cette
    /// boucle *était* le gel de l'affichage — voir `reconcileSession`, qui est
    /// la moitié de ce qui l'empêchait de fonctionner.
    ///
    /// `startPump` part de **deux** endroits — `didFinishLaunching` et
    /// `sceneDidBecomeActive` — et les deux se suivent de près au démarrage à
    /// froid. Annuler la boucle précédente ne suffit pas : l'annulation n'arrête
    /// pas un `refresh()` déjà engagé au-delà de ses `await`, si bien que deux
    /// passes pouvaient se chevaucher, et se disputer la session qu'elles
    /// tiennent.
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
        // Ce que l'extension n'a pas pu enregistrer elle-même — voir
        // `MiloAPIClient.pendingSessionTokenKey`. Sans token, Milō ne peut pas
        // pousser ses `update` à la session, la déclare inadressable, et en
        // ouvre une rivale que le système n'affiche pas.
        await MiloAPIClient.drainPendingSessionToken()

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

        // Réconcilier d'abord, et à **chaque** passe.
        //
        // L'app se contentait d'adopter quand elle ne tenait rien, puis gardait
        // sa prise pour toujours. Milō, lui, termine et rouvre des sessions
        // selon ce qui joue : l'app restait alors accrochée à une session morte
        // de son côté pendant que la vivante, invisible, recevait tout.
        await reconcileSession()

        // Personne n'a ouvert ? On ouvre, si quelque chose joue.
        if session == nil {
            await openSession(attributes)
        }

        guard let session else {
            note("aucune session, et rien à ouvrir")
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
        if signature == lastSignature, !jumped { return }

        do {
            // L'identifiant est celui de la session, jamais le nôtre :
            // `update(_:)` refuse des attributs qui n'en portent pas le sien.
            try await session.update(attributes.with(id: session.id))
            lastSignature = signature
            disowned.removeAll()
            note("update ok (\(session.id))")
        } catch {
            // Une session que Milō ou le système a close continue de refuser
            // chaque `update`. On la lâche, et son identifiant est retenu :
            // `sessions()` peut continuer de l'énumérer, et la réconciliation
            // la reprendrait au tour suivant — on refuserait alors en boucle.
            Self.session = nil
            disowned.insert(session.id)
            lastSignature = ""
            note("update refusé, session lâchée : \(error)")
        }
    }

    /// Aligne ce qu'on tient sur ce que le système tient, et réclame l'écran.
    ///
    /// **L'app n'ouvre plus de session.** Elle l'a fait, et c'était la rivalité
    /// qu'on croyait supprimer : mesuré le 19/09/2026 à 17:46:30, deux sessions
    /// vivantes en même temps — `9AA6ACC5`, ouverte ici, principale et donc
    /// seule visible, mais que Milō avait déjà terminée de son côté ; et
    /// `7e148d0e`, ouverte par le push de Milō, qui recevait tous les `update`
    /// sans que personne ne les voie. Une session ouverte par push ne peut pas
    /// réclamer l'écran elle-même — `requestToBecomeSystemPrimary()` exige le
    /// premier plan, et quand elle naît l'app dort. La seule qui pouvait le
    /// faire était donc celle qu'il ne fallait pas.
    ///
    /// Milō est propriétaire du cycle de vie ; l'app ne fait que suivre, et
    /// pousse ses `update` sur le LAN tant qu'elle est ouverte parce que c'est
    /// plus rapide qu'un aller-retour par Apple. Quand rien n'est ouvert, il n'y
    /// a rien à afficher et rien à faire : Milō pousse un `start` dès que la
    /// lecture reprend.
    /// Le système tient-il **une** session, même lâchée par l'app ?
    ///
    /// Distinct de `session != nil` : une session écartée dans `disowned` reste
    /// vivante côté système. Ouvrir alors en créerait une seconde — exactement
    /// la panne du 19/09.
    private static var systemHoldsAny = false

    /// Dernière tentative d'ouverture. Sans ce frein, un refus relancerait une
    /// ouverture toutes les deux secondes.
    private static var lastStartAttempt = Date.distantPast
    private static let startRetryDelay: TimeInterval = 10

    /// Ouvre une session quand personne ne l'a fait et que la lecture est en cours.
    ///
    /// **C'est le retour d'un chemin retiré le 19/09/2026, et ce n'est pas un
    /// oubli de l'avoir retiré.** Ce qui avait cassé n'était pas l'ouverture :
    /// c'était d'ouvrir *pendant* que Milō en ouvrait une autre par push. Deux
    /// sessions vivantes, la visible déjà morte côté Milō, l'autre recevant tout
    /// sans être vue.
    ///
    /// Trois gardes, et la première est celle qui manquait alors :
    ///
    /// - **le système ne tient rien** — `sessions()` vide, pas seulement « l'app
    ///   n'en tient pas » ; c'est la distinction qui a coûté la panne ;
    /// - **quelque chose joue**, sinon il n'y a rien à afficher et la carte
    ///   resterait vide sur l'écran verrouillé ;
    /// - **un essai toutes les dix secondes** au plus.
    ///
    /// Et l'app peut ce que le push ne peut pas : `requestToBecomeSystemPrimary()`
    /// exige le premier plan. Une session née d'un push naît pendant que l'app
    /// dort, donc elle ne peut jamais réclamer l'écran elle-même. Celle-ci, si.
    ///
    /// Ça ne remplace pas le `start` de Milō, qui reste le seul chemin quand
    /// l'app n'a jamais été lancée. Ça couvre le cas où la musique jouait déjà
    /// avant qu'on ouvre l'app — où rien n'ouvrait de session, puisque Milō
    /// n'envoie un `start` que sur un événement de lecture.
    private static func openSession(_ attributes: MiloSessionAttributes) async {
        guard !systemHoldsAny, attributes.isPlaying,
              Date().timeIntervalSince(lastStartAttempt) > startRetryDelay
        else { return }
        lastStartAttempt = Date()

        do {
            // L'identifiant est minté ici : c'est une session à nous, et Milō
            // apprendra son token par l'extension, qui l'enregistre à la
            // construction comme pour n'importe quelle autre.
            let opened = try await RemoteMediaSession.start(
                attributes: attributes.with(id: UUID().uuidString))
            session = opened
            systemHoldsAny = true
            // La signature décrit ce qu'on a poussé ailleurs ; sur une session
            // neuve elle ne vaut rien.
            lastSignature = ""

            // Réclamer l'écran maintenant, tant qu'on est au premier plan.
            try? await opened.requestToBecomeSystemPrimary()
            await MiloAPIClient.reportLiveSessions([opened.id])
            note("session ouverte par l'app (\(opened.id))")
        } catch {
            note("ouverture refusée : \(error)")
        }
    }

    private static func reconcileSession() async {
        let all = (try? await RemoteMediaSession<MiloSessionAttributes>.sessions()) ?? []
        systemHoldsAny = !all.isEmpty

        // Dit à Milō ce que le téléphone tient réellement, **avant** de filtrer.
        //
        // Une session que l'app a lâchée reste vivante côté système ; ce qu'on
        // rapporte ici est l'état de l'appareil, pas la prise de l'app. Filtrer
        // d'abord ferait retirer chez Milō une session bien présente, et la
        // rouvrirait pour rien.
        //
        // C'est la moitié manquante du problème des sessions fantômes : sans ce
        // rapport, un token de session survit à sa session et Milō pousse dans
        // le vide pour toujours. Voir `MiloAPIClient.reportLiveSessions`.
        await MiloAPIClient.reportLiveSessions(all.map(\.id))

        let existing = all.filter { !disowned.contains($0.id) }

        guard let live = existing.first(where: { $0.isSystemPrimary }) ?? existing.first else {
            if session != nil { note("session disparue") }
            session = nil
            return
        }

        if live.id != session?.id {
            session = live
            // La signature décrit ce qu'on a poussé à la session d'avant ; sur
            // une autre elle ne vaut rien, et la garder sauterait la première
            // mise à jour de la nouvelle.
            lastSignature = ""
            note("session adoptée (\(live.id))")
        }

        // Réclamé tant que ce n'est pas obtenu. Une seule demande ne suffit
        // pas : `startPump()` part aussi de `didFinishLaunching`, où la scène
        // n'est pas encore active et où la demande est ignorée sans erreur —
        // c'est ce qui obligeait à lancer l'app **deux** fois pour voir la
        // carte apparaître.
        if !live.isSystemPrimary {
            try? await live.requestToBecomeSystemPrimary()
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
            // Place tenue, jamais envoyée telle quelle : `refresh()` la remplace
            // par l'identifiant de la session qu'il tient, seul que
            // `update(_:)` accepte. L'app n'en mint plus aucun — voir
            // `reconcileSession`.
            id: "",
            isPlaying: isPlaying,
            elapsedTime: positionMS / 1000,
            timestamp: ISO8601DateFormatter().string(from: .now),
            currentTrack: track,
            devices: await buildDevices()
        )
    }

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
