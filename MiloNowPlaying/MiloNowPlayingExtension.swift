import ExtensionFoundation
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
        // Cette extension n'atteint pas Milō par son IP — voir
        // `MiloAPIClient.prefersHostname`, où la mesure est consignée.
        MiloAPIClient.prefersHostname = true
    }

    var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    func session(_ attributes: MiloSessionAttributes) async throws -> MiloRemoteSession {
        MiloRemoteSession(attributes: attributes)
    }
}
