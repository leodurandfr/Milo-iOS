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

    static func refresh() async {
        guard let attributes = await buildAttributes() else {
            note("pas d'état exploitable depuis Milō")
            return
        }

        do {
            if let session {
                try await session.update(attributes)
                note("update ok (\(attributes.id))")
            } else {
                let fresh = try await RemoteMediaSession.start(attributes: attributes)
                session = fresh
                // Ne vaut que depuis le premier plan : en arrière-plan la
                // demande est ignorée, sans erreur.
                try await fresh.requestToBecomeSystemPrimary()
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
            track = MiloSessionAttributes.Track(
                id: (audio["active_source"] as? String ?? "milo") + ":" +
                    (metadata["title"] as? String ?? "-"),
                title: metadata["title"] as? String,
                artist: metadata["artist"] as? String,
                album: metadata["album"] as? String,
                duration: durationMS / 1000,
                artworkURL: metadata["album_art_url"] as? String
            )
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

    /// Un device par client snapcast.
    ///
    /// `/api/volume/state` ne nomme pas les clients — seules les zones portent un
    /// nom, et un client peut n'appartenir à aucune. On retombe alors sur la fin
    /// de l'adresse MAC, qui reste identifiable, plutôt que sur un « Enceinte 2 »
    /// qui changerait d'ordre entre deux lectures.
    private static func buildDevices() async -> [MiloSessionAttributes.Device] {
        guard let data = try? await MiloAPIClient.get(path: "/api/volume/state"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let clients = payload["clients"] as? [String: [String: Any]]
        else { return [] }

        var zoneOf: [String: String] = [:]
        if let zones = payload["zones"] as? [String: [String: Any]] {
            for zone in zones.values {
                guard let name = zone["name"] as? String,
                      let ids = zone["client_ids"] as? [String] else { continue }
                for id in ids { zoneOf[id] = name }
            }
        }

        let limits = MiloAPIClient.volumeLimits()
        let span = limits.max - limits.min

        return clients.keys.sorted().map { mac in
            let db = clients[mac]?["volume_db"] as? Double ?? limits.min
            let normalized = span > 0 ? (db - limits.min) / span : 0
            return MiloSessionAttributes.Device(
                id: mac,
                name: zoneOf[mac] ?? "Milō \(mac.suffix(5))",
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
