import ExtensionFoundation
import Foundation
import NowPlaying

/// Point d'entrée de l'extension Now Playing.
///
/// Le système la réveille sur réception d'un push `start` et appelle `session`
/// avec les attributs décodés. Il met ensuite en cache la session rendue ici et
/// lui route les `update` suivants — d'où l'absence de toute connexion ouverte
/// dans ce type : il n'y a rien à garder entre deux réveils.
@available(iOS 27, *)
@main
struct MiloNowPlayingExtension: RemoteMediaSessionExtension {

    init() {
        // Première chose écrite par le processus, avant toute autre : c'est le
        // seul point qui prouve *quel* binaire le système vient de charger.
        // Tracer à l'entrée, jamais à la sortie — un chemin qui échoue en
        // silence se lit sinon comme un chemin jamais pris.
        miloLog.info("EXTENSION DÉMARRÉE — binaire \(miloBinaryStamp(), privacy: .public)")

        // Tout ce qui part vers Milō passe par un chemin lié au Wi-Fi — voir
        // `MiloScopedHTTP`, où la mesure est consignée. Les URL restent en
        // `milo.local` (`prefersHostname`) : c'est à ce nom que `lanData`
        // reconnaît une requête destinée à Milō.
        MiloAPIClient.prefersHostname = true
        MiloAPIClient.scopedTransport = { try await MiloScopedHTTP.perform($0) }
    }

    var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    func session(_ attributes: MiloSessionAttributes) async throws -> MiloRemoteSession {
        MiloRemoteSession(attributes: attributes)
    }
}
