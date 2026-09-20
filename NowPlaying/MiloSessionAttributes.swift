import Foundation
import NowPlaying

/// L'état de lecture de Milō, tel qu'il arrive dans le push APNs.
///
/// Milō envoie l'objet **entier** à chaque événement — `start` comme `update` —
/// et non un delta. C'est la différence avec ActivityKit, où `attributes` est
/// immuable et seul `content-state` change : `NowPlaying` n'a pas de
/// `ContentState`, et `update(_:)` reçoit ce type complet.
///
/// Sur `end`, seul `id` est présent.
///
/// Nullabilité : c'est ici que tout se joue. Un champ déclaré non optionnel que
/// Milō n'envoie pas fait **échouer le décodage entier**, silencieusement, et la
/// session ne s'ouvre jamais — sans erreur visible nulle part. La règle vient du
/// backend, pas d'une supposition :
///
/// - nullables : `title`, `artist`, `album`, `artworkURL`, et `currentTrack`
///   lui-même. Une source peut passer ACTIVE avant sa première métadonnée, et le
///   Bluetooth n'a jamais de pochette en bande.
/// - toujours présents : `id`, `isPlaying`, `elapsedTime`, `devices`, et
///   `duration` quand une piste est là — une durée inconnue vaut `0.0`, jamais
///   `null`.
@available(iOS 27, *)
struct MiloSessionAttributes: RemoteMediaSessionAttributes {

    let id: String
    let isPlaying: Bool
    let elapsedTime: TimeInterval
    /// ISO-8601, décodé à la main — voir `capturedAt`.
    let timestamp: String
    let currentTrack: Track?
    let devices: [Device]

    struct Track: Codable {
        let id: String
        let title: String?
        let artist: String?
        let album: String?
        /// Secondes. Milō convertit depuis les millisecondes de `/api/audio/state`.
        let duration: TimeInterval
        let artworkURL: String?
    }

    struct Device: Codable {
        let id: String
        let name: String
        let type: String
        /// Déjà normalisé 0…1 sur `volume_limits` par Milō, et c'est exactement
        /// ce que le curseur attend.
        ///
        /// Ne reconvertir dans aucun sens, ni pour l'affichage ni pour
        /// l'écriture : Milō accepte désormais `volume` sur cette même échelle,
        /// et la conversion en décibels n'existe plus de ce côté-ci. Elle a
        /// existé, sur des bornes que l'app gardait en cache et ne rafraîchissait
        /// jamais — -80…-21 face à -78…-8 sur l'appareil — et c'est ce qui
        /// faisait monter le son trois fois moins que le doigt ne le demandait.
        let volume: Float
    }

    /// Les mêmes attributs sous l'identifiant d'une autre session.
    ///
    /// `RemoteMediaSession.update(_:)` refuse des attributs dont l'`id` ne
    /// correspond pas au sien, et une session adoptée porte celui que Milō a
    /// minté — voir `MiloNowPlayingBridge.adoptExistingSession`. On ne fabrique
    /// donc plus l'identifiant à la source : on le repose sur le chemin.
    func with(id: String) -> MiloSessionAttributes {
        MiloSessionAttributes(
            id: id,
            isPlaying: isPlaying,
            elapsedTime: elapsedTime,
            timestamp: timestamp,
            currentTrack: currentTrack,
            devices: devices
        )
    }

    /// `timestamp` est porté en `String` plutôt qu'en `Date`, délibérément.
    ///
    /// C'est le système qui décode ce type, et la stratégie de date de son
    /// `JSONDecoder` n'est documentée nulle part. Déclarer un `Date` reviendrait
    /// à parier que cette stratégie est `.iso8601` ; si le pari est perdu, le
    /// décodage jette et la session ne s'ouvre jamais, sans rien dans les logs.
    /// Un `String` décode toujours, et la conversion redevient notre affaire.
    var capturedAt: Date {
        Self.iso8601.date(from: timestamp)
            ?? Self.iso8601NoFraction.date(from: timestamp)
            ?? .now
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Milō envoie `2026-09-19T12:00:00Z`, sans fraction de seconde. Les deux
    /// formateurs sont là parce qu'`ISO8601DateFormatter` refuse l'une des deux
    /// formes selon `withFractionalSeconds`, et qu'on ne choisit pas ce que le
    /// serveur enverra demain.
    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
