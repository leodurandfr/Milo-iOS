import Foundation
import NowPlaying

/// Le token qui permet à Milō d'ouvrir une session sans que l'app tourne.
///
/// Il est long à vivre et existe avant toute session : c'est lui qui reçoit
/// l'événement `start`, et rien d'autre. Tant que Milō ne l'a pas, il ne peut
/// rien démarrer — l'écran verrouillé reste vide même quand la musique joue.
///
/// Ce fichier est dans la cible de l'app et pas dans `Shared` : `RemoteMediaSession`
/// est `@available(iOSApplicationExtension, unavailable)`, donc ni le widget ni
/// l'extension Now Playing ne peuvent le compiler.
@available(iOS 27, *)
enum MiloPushToStart {

    /// À appeler au lancement. La valeur courante part tout de suite si elle
    /// existe, puis on suit les rotations — iOS peut réémettre le token sans
    /// prévenir, et un token périmé chez Milō est un `start` qui n'arrive jamais.
    /// `@MainActor` parce que les deux accesseurs de `RemoteMediaSession` le
    /// sont — l'appel vient de `didFinishLaunching`, déjà sur cet acteur.
    @MainActor
    static func begin() {
        if let token = RemoteMediaSession<MiloSessionAttributes>.pushToStartToken {
            Task { await MiloAPIClient.registerPushToken(token, kind: .pushToStart) }
        }

        let updates = RemoteMediaSession<MiloSessionAttributes>.pushToStartTokenUpdates
        Task {
            for await token in updates {
                await MiloAPIClient.registerPushToken(token, kind: .pushToStart)
            }
        }
    }
}
