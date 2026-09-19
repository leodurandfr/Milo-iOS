import Foundation
import NowPlaying
import Observation

/// Milō vu par l'écran verrouillé, le Centre de contrôle et la Dynamic Island.
///
/// Le système garde cette instance et lui route les mises à jour suivantes : la
/// connexion à Milō se fait donc une fois et se réutilise, plutôt qu'à chaque
/// push.
///
/// Les commandes et le curseur partent d'ici, **sur le LAN** : APNs ne sert qu'à
/// l'état descendant. Ce qui remonte vers Milō est du HTTP ordinaire, et
/// n'emprunte jamais Internet.
@available(iOS 27, *)
@Observable
final class MiloRemoteSession: @MainActor RemoteMediaSessionRepresentable {

    let id: String
    private(set) var attributes: MiloSessionAttributes

    init(attributes: MiloSessionAttributes) {
        self.id = attributes.id
        self.attributes = attributes
        startObservingPushToken()
    }

    /// Le système remet ici les attributs poussés par Milō. Les stocker suffit :
    /// `@Observable` fait remonter le changement à l'interface Now Playing.
    func update(_ attributes: MiloSessionAttributes) {
        self.attributes = attributes
    }

    // MARK: - Ce qui joue

    var playbackSnapshot: MediaPlaybackSnapshot? {
        MediaPlaybackSnapshot(
            state: attributes.isPlaying ? .playing() : .paused,
            elapsedTime: attributes.elapsedTime,
            timestamp: attributes.capturedAt
        )
    }

    var content: (any MediaContentRepresentable)? {
        guard let track = attributes.currentTrack else { return nil }

        // `MusicContent` veut des `String` non optionnels alors que Milō peut
        // n'avoir pas encore de métadonnées. Une chaîne vide laisse le système
        // masquer la ligne ; inventer « Inconnu » l'afficherait pour de bon.
        return MusicContent(
            id: track.id,
            songTitle: track.title ?? "",
            artistName: track.artist ?? "",
            albumName: track.album ?? "",
            type: .audio,
            // Une durée à 0 n'est pas une durée : Milō s'en sert pour dire
            // « inconnue », et l'annoncer ferait afficher une barre fausse.
            duration: track.duration > 0 ? .finite(track.duration) : nil,
            artwork: artwork(for: track)
        )
    }

    /// La pochette est chargée par l'extension, à la demande du système.
    ///
    /// L'URL est publique (Spotify sert la sienne sur `i.scdn.co`), donc ce
    /// chargement ne dépend pas du LAN — il marche même hors de la maison, ce
    /// qui est précisément le cas où l'écran verrouillé sert encore.
    private func artwork(for track: MiloSessionAttributes.Track) -> Artwork? {
        guard let raw = track.artworkURL, let url = URL(string: raw) else { return nil }
        return Artwork(id: raw) { _ in
            let (data, _) = try await URLSession.shared.data(from: url)
            return try ArtworkRepresentation(data: data)
        }
    }

    // MARK: - Commandes

    var commands: [MediaCommand] {
        [
            .play { await MiloAPIClient.fireTransport(.play) },
            .pause { await MiloAPIClient.fireTransport(.pause) },
            .togglePlayPause { await MiloAPIClient.fireTransport(.playPause) },
            .next { await MiloAPIClient.fireTransport(.next) },
            .previous { await MiloAPIClient.fireTransport(.previous) },
            .seekToPosition { position in
                await MiloAPIClient.fireSeek(toSeconds: position)
            }
        ]
    }

    // MARK: - Enceintes

    /// Un `MediaDevice` par client snapcast : l'utilisateur obtient un curseur
    /// par pièce dans le Centre de contrôle.
    ///
    /// Le niveau affiché arrive déjà normalisé 0…1 de Milō. À l'écriture il faut
    /// refaire le chemin inverse, parce que le backend raisonne en dB — et c'est
    /// bien une écriture **absolue** : convertir en delta contre
    /// `/api/volume/adjust` serait une lecture-modification-écriture en course
    /// contre l'encodeur rotatif de l'appareil.
    var devices: [MediaDevice] {
        attributes.devices.map { device in
            MediaDevice(
                id: device.id,
                name: device.name,
                type: Self.deviceType(device.type),
                capabilities: [
                    .absoluteVolume(device.volume) { level in
                        await MiloAPIClient.setClientVolume(mac: device.id,
                                                            normalized: level)
                    }
                ]
            )
        }
    }

    private static func deviceType(_ raw: String) -> MediaDevice.DeviceType {
        switch raw {
        case "tv": return .tv
        case "phone": return .phone
        case "tablet": return .tablet
        case "desktop": return .desktop
        case "laptop": return .laptop
        default: return .speaker
        }
    }

    // MARK: - Token de session

    /// Rend à Milō le token de cette session.
    ///
    /// Tant qu'il n'est pas arrivé, Milō n'envoie **aucun** `update` : il n'a pas
    /// d'adresse où les mettre. Ce n'est pas une erreur, c'est l'aller-retour du
    /// protocole — `start` part au token push-to-start, la suite part à celui-ci.
    private func startObservingPushToken() {
        if let token = pushToken {
            Task { await MiloAPIClient.registerPushToken(token, kind: .session, sessionID: id) }
        }
        Task { [weak self] in
            guard let self else { return }
            for await token in pushTokenUpdates {
                await MiloAPIClient.registerPushToken(token, kind: .session, sessionID: self.id)
            }
        }
    }
}
