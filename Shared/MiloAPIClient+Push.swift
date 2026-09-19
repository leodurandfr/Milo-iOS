import Foundation
import WidgetKit

/// Enregistrement des tokens APNs auprès de Milō.
///
/// Milō est en LAN pur en entrée, mais joint APNs en sortie : c'est lui le
/// fournisseur, et il lui faut donc savoir à quels tokens s'adresser. Rien ici
/// ne parle à Apple — on ne fait que déposer chez Milō ce qu'iOS nous a donné.
extension MiloAPIClient {

    static let deviceIDKey = "milo_push_device_id"
    static let registeredWidgetTokenKey = "milo_registered_widget_token"

    /// Nature du token, telle que Milō la range dans son registre.
    ///
    /// Les trois ne se remplacent pas entre eux : `pushToStart` reçoit `start`,
    /// `session` reçoit `update` et `end`, `widget` reçoit `content-changed`.
    enum PushTokenKind: String {
        case widget
        case pushToStart = "push_to_start"
        case session
    }

    /// Environnement APNs déduit de l'entitlement `aps-environment` du build.
    ///
    /// Jamais deviné : un token de build Debug n'est valide que contre
    /// `api.sandbox.push.apple.com`, et viser le mauvais hôte répond
    /// `BadDeviceToken` — un 400 indiscernable d'un token malformé, sans rien de
    /// visible sur le téléphone. C'est la façon la plus courante dont « le push
    /// ne marche pas » se manifeste, donc on lit la valeur réelle plutôt que de
    /// la déduire d'un `#if DEBUG` qui mentirait sur un build TestFlight.
    ///
    /// Retourne `nil` si le profil est illisible (simulateur, notamment) : on
    /// n'enregistre alors rien du tout. Milō refuse un enregistrement sans
    /// environnement (422), et il a raison — une valeur inventée coûterait plus
    /// cher qu'une absence.
    static func apsEnvironment() -> String? {
        guard let data = embeddedMobileProvision() else { return nil }

        // Le fichier est un conteneur CMS signé ; le plist est en clair à
        // l'intérieur. On le découpe aux bornes plutôt que de dépendre de
        // Security.framework pour décoder une signature qui ne nous apprend rien.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8))
        else { return nil }

        let plistData = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else { return nil }

        // Deux vocabulaires pour la même chose : Apple écrit `development` dans
        // l'entitlement, alors que Milō — qui raisonne en hôtes APNs — attend
        // `sandbox`. Transmettre la valeur brute donne un 422 que le client
        // avalait sans rien dire, puisqu'il ne lit que `status`. La traduction
        // vit ici plutôt que côté serveur : c'est nous qui parlons le dialecte
        // des entitlements, Milō n'a pas à le connaître.
        switch environment {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }

    /// Le profil du bundle courant, puis celui de l'app conteneur en repli.
    ///
    /// Une extension widget porte le sien dans son `.appex`, mais il arrive qu'un
    /// build local n'en embarque pas ; on remonte alors au bundle de l'app, qui
    /// est signé avec un profil de même environnement.
    private static func embeddedMobileProvision() -> Data? {
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        // `.appex` vit dans `<App>.app/PlugIns/` : deux crans au-dessus.
        let containing = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("embedded.mobileprovision")
        return try? Data(contentsOf: containing)
    }

    /// Identifiant stable de cette installation, minté une fois puis conservé.
    ///
    /// C'est lui qui permet à Milō de *remplacer* un token plutôt que d'en
    /// accumuler : sans lui, chaque rotation de token laisserait un mort dans le
    /// registre, et Milō pousserait indéfiniment vers des destinations éteintes.
    /// Il vit dans l'app group pour que l'app et le widget déclarent la même
    /// installation — deux identifiants donneraient deux appareils à Milō.
    static func deviceID() -> String {
        let defaults = UserDefaults(suiteName: appGroupID)
        if let existing = defaults?.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults?.set(fresh, forKey: deviceIDKey)
        return fresh
    }

    /// Dépose un token chez Milō. Idempotent : à appeler à chaque lancement.
    ///
    /// `sessionID` est requis pour `.session` et interdit ailleurs — Milō répond
    /// 422 sur un désaccord, plutôt que d'enregistrer quelque chose d'ambigu.
    @discardableResult
    static func registerPushToken(_ token: Data,
                                  kind: PushTokenKind,
                                  sessionID: String? = nil) async -> Bool {
        let hex = token.map { String(format: "%02x", $0) }.joined()

        guard let environment = apsEnvironment() else {
            // Sans environnement il n'y a rien d'utile à envoyer : un token
            // enregistré sous le mauvais hôte échouerait en silence côté Milō.
            return false
        }

        var body: [String: Any] = [
            "token": hex,
            "kind": kind.rawValue,
            "environment": environment,
            "device_id": deviceID()
        ]
        if let sessionID { body["session_id"] = sessionID }

        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let response = try? await post(path: "/api/push/tokens", body: data),
              let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
        else { return false }

        return json["status"] as? String == "success"
    }

    /// Retire un token du registre — quand la dernière instance d'un widget
    /// disparaît, par exemple. Milō répond 404 s'il ne le détenait pas, ce qui
    /// n'est pas une erreur de notre point de vue.
    @discardableResult
    static func unregisterPushToken(_ token: Data) async -> Bool {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: baseURL() + "/api/push/tokens/\(hex)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 || http.statusCode == 404
    }

    /// Rattrape un enregistrement de token qui n'a pas abouti.
    ///
    /// `pushTokenDidChange` n'est appelé que lorsque le token *change*. Si Milō
    /// était injoignable à ce moment-là — redémarrage, Wi-Fi absent, backend plus
    /// ancien que la route — l'enregistrement est perdu pour de bon : rien ne
    /// rappellera le handler tant que le token reste le même, et le widget
    /// resterait muet indéfiniment.
    ///
    /// La timeline, elle, repasse régulièrement. On s'en sert pour reposer la
    /// question à Milō tant qu'il n'a pas confirmé. L'appel est ignoré dès que le
    /// token courant est celui qu'on a déjà fait accepter, donc le cas normal ne
    /// coûte aucune requête.
    @available(iOS 26.0, *)
    static func reconcileWidgetPushToken() async {
        guard let info = await WidgetCenter.shared.currentPushInfo else { return }
        let hex = info.token.map { String(format: "%02x", $0) }.joined()

        let defaults = UserDefaults(suiteName: appGroupID)
        guard defaults?.string(forKey: registeredWidgetTokenKey) != hex else { return }

        if await registerPushToken(info.token, kind: .widget) {
            defaults?.set(hex, forKey: registeredWidgetTokenKey)
        }
    }
}
