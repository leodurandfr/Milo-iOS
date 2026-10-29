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
        // Réarme l'enregistrement du token de session. L'extension ne le dépose
        // qu'une fois par couple (session, token), et cette garde-là vit dans le
        // conteneur partagé — donc plus longtemps que le registre d'en face.
        UserDefaults(suiteName: MiloAPIClient.appGroupID)?
            .removeObject(forKey: MiloAPIClient.sessionTokenStampKey)

        if let token = RemoteMediaSession<MiloSessionAttributes>.pushToStartToken {
            register(token)
        }

        let updates = RemoteMediaSession<MiloSessionAttributes>.pushToStartTokenUpdates
        Task {
            for await token in updates {
                register(token)
            }
        }
    }

    /// Le dernier token qu'iOS a donné, et le dernier dont l'envoi a tranché.
    ///
    /// Tant qu'ils diffèrent, Milō n'a pas le bon token : un lancement hors du
    /// Wi-Fi de la maison — ou pendant que Milō redémarre — le laissait sans
    /// token jusqu'au lancement suivant. Or l'app reste suspendue des jours :
    /// autant de jours sans carte quand elle dort. Gardés en mémoire et non dans
    /// le conteneur partagé : `begin()` reprend la valeur courante à chaque
    /// lancement.
    @MainActor private static var current: Data?
    @MainActor private static var settled: Data?

    /// Les envois, à la file. Le token initial, une rotation et une reprise
    /// peuvent se chevaucher ; sans file, l'ancien token pouvait arriver chez
    /// Milō après le nouveau et le remplacer.
    @MainActor private static var chain: Task<Void, Never>?

    /// Pas de reprise avant cette date. Un Milō qui répond 404 ou 500 rend
    /// `.unavailable` à chaque essai, et la pompe passe toutes les deux
    /// secondes.
    @MainActor private static var nextRetry = Date.distantPast

    /// Rejoue l'envoi manqué. Appelé par la pompe, à chaque passe, **sans
    /// l'attendre** : hors du Wi-Fi, le POST prend ses trois secondes, et la
    /// passe compte sur sa propre durée pour juger Milō injoignable.
    @MainActor
    static func retryIfNeeded() {
        guard let token = current, token != settled, Date() >= nextRetry else { return }
        nextRetry = Date().addingTimeInterval(30)
        enqueue(token)
    }

    @MainActor
    private static func register(_ token: Data) {
        current = token
        enqueue(token)
    }

    /// Un refus de forme ne change pas d'un essai à l'autre : seul l'échec
    /// réseau laisse le token en attente.
    @MainActor
    private static func enqueue(_ token: Data) {
        let previous = chain
        chain = Task {
            await previous?.value
            // Une rotation est arrivée pendant l'attente : c'est elle qui compte.
            guard current == token, settled != token else { return }
            let outcome = await MiloAPIClient.registerPushToken(token, kind: .pushToStart)
            if case .unavailable = outcome {
                nextRetry = Date().addingTimeInterval(30)
            } else {
                settled = token
            }
        }
    }
}
