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
    static let refusedWidgetTokenKey = "milo_refused_widget_token"
    static let refusalDetailKey = "milo_push_refusal_detail"

    /// Nature du token, telle que Milō la range dans son registre.
    ///
    /// Les trois ne se remplacent pas entre eux : `pushToStart` reçoit `start`,
    /// `session` reçoit `update` et `end`, `widget` reçoit `content-changed`.
    enum PushTokenKind: String {
        case widget
        case pushToStart = "push_to_start"
        case session

        /// L'hôte APNs auquel ce token répond — et il ne se déduit **pas** de
        /// l'entitlement du build.
        ///
        /// Mesuré le 19/09/2026 contre le vrai service, depuis le Pi, sur un
        /// build Debug signé `aps-environment: development` :
        ///
        /// | token           | sandbox          | production       |
        /// |-----------------|------------------|------------------|
        /// | `widget`        | **200**          | `BadDeviceToken` |
        /// | `push_to_start` | `BadDeviceToken` | **200**          |
        /// | `session`       | `BadDeviceToken` | **200**          |
        ///
        /// Les deux tokens du framework `NowPlaying` sont donc des tokens de
        /// **production**, sur un build de développement. Ce n'est pas une
        /// anomalie : ils ne viennent pas de l'inscription APNs de l'app, mais
        /// de `mediaremoted`, un démon du système qui n'a qu'une seule identité
        /// APNs — de production. Les journaux le montrent qui les range sous la
        /// clé `leodurand.Milo-iOS::pushToStart`, dans le même registre que ceux
        /// de toutes les autres apps de l'appareil, tous en `production`. Le
        /// token du widget, lui, vient bien de l'app et suit son entitlement.
        ///
        /// Viser le mauvais hôte répond `BadDeviceToken` : un 400 que rien ne
        /// distingue d'un token malformé ni d'un mauvais topic, et c'est ce qui
        /// a rendu la panne si coûteuse — la clé, le topic et le type de push
        /// étaient bons depuis le début.
        ///
        /// `production` en dur ne fait courir aucun risque à un build App Store,
        /// où c'est déjà la seule réponse possible.
        var apnsEnvironment: String? {
            switch self {
            case .widget: return MiloAPIClient.apsEnvironment()
            case .pushToStart, .session: return "production"
            }
        }
    }

    /// Environnement APNs déduit de l'entitlement `aps-environment` du build.
    ///
    /// **Ne vaut que pour le token du widget** — le seul que l'app obtienne par
    /// sa propre inscription APNs, et donc le seul qui suive son entitlement.
    /// Voir `PushTokenKind.apnsEnvironment` pour les deux autres.
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

    /// Verdict d'un enregistrement, et surtout : faut-il réessayer.
    ///
    /// La distinction est la seule chose qui sépare un rattrapage d'une boucle.
    /// Un 4xx est un jugement sur la requête elle-même — la rejouer dépense des
    /// lancements pour un résultat qui ne peut pas changer. Une panne réseau est
    /// transitoire et mérite exactement le contraire.
    enum PushRegistrationOutcome {
        case registered
        /// Milō a refusé la requête pour sa forme. `detail` porte ce qu'il
        /// reproche — le 422 nomme le champ et les valeurs admises.
        case refused(String)
        /// Milō n'a pas répondu, ou a échoué de son côté. Réessayer a du sens.
        case unavailable
    }

    /// Dépose un token chez Milō. Idempotent : à appeler à chaque lancement.
    ///
    /// `sessionID` est requis pour `.session` et interdit ailleurs — Milō répond
    /// 422 sur un désaccord, plutôt que d'enregistrer quelque chose d'ambigu.
    ///
    /// Le code HTTP est lu, et pas seulement `status`. Ne lire que `status`
    /// rendait un 422 indiscernable d'une panne réseau : c'est ainsi qu'un
    /// `environment` refusé est resté invisible, route correcte, méthode
    /// correcte, champ correct, valeur rejetée — et le contrat au vert, puisqu'il
    /// prouve l'existence des routes et non les valeurs qu'on met dans un corps.
    static func registerPushToken(_ token: Data,
                                  kind: PushTokenKind,
                                  sessionID: String? = nil) async -> PushRegistrationOutcome {
        let hex = token.map { String(format: "%02x", $0) }.joined()

        guard let environment = kind.apnsEnvironment else {
            // Le profil est illisible (simulateur). Rien d'utile à envoyer, et
            // rien qu'un réessai corrigerait sur ce build. Ne concerne que le
            // widget : les deux autres familles répondent sans lire de profil.
            return .refused("aps-environment illisible")
        }

        var body: [String: Any] = [
            "token": hex,
            "kind": kind.rawValue,
            "environment": environment,
            "device_id": deviceID()
        ]
        if let sessionID { body["session_id"] = sessionID }

        guard let url = URL(string: baseURL() + "/api/push/tokens"),
              let payload = try? JSONSerialization.data(withJSONObject: body)
        else { return .refused("requête impossible à construire") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .unavailable }

        if http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["status"] as? String == "success" {
            return .registered
        }

        // Tous les 4xx ne sont pas des jugements sur la requête.
        //
        // Un **404** dit que la route n'existe pas sur *ce* Milō — un backend
        // antérieur à `/api/push/tokens`. C'est précisément le cas que
        // `reconcileWidgetPushToken` existe pour rattraper : le ranger parmi les
        // refus définitifs condamnait le widget à rester muet même après la mise
        // à jour du backend, puisque plus rien ne réessayait. **408** et **429**
        // sont transitoires par définition.
        //
        // Restent les vrais refus de forme — 400, 422 — qu'un réessai ne
        // corrigera jamais.
        if [404, 408, 429].contains(http.statusCode) { return .unavailable }
        guard (400..<500).contains(http.statusCode) else { return .unavailable }

        // Le corps du 422 nomme le champ fautif et les valeurs admises. Le garder
        // tel quel : reformuler ferait perdre la seule information exploitable.
        let detail = String(data: data, encoding: .utf8) ?? ""
        return .refused("HTTP \(http.statusCode) \(detail)")
    }

    /// Enregistre le token du widget, en retenant le verdict.
    ///
    /// Un token déjà accepté ne coûte rien. Un token déjà refusé n'est pas
    /// rejoué : c'est ce qui empêche le rattrapage de la timeline de devenir une
    /// boucle contre un serveur qui a déjà dit non. Un token neuf lève la
    /// consigne — le refus portait sur l'ancien, pas sur l'app.
    ///
    /// Sérialisé, parce que la garde n'est pas atomique : lire la consigne, aller
    /// sur le réseau, puis écrire le verdict laisse une fenêtre où un second
    /// appel passe aussi. Le lancement et le retour d'inscription APNs arrivent
    /// justement ensemble — mesuré contre un serveur de test, deux POST
    /// identiques pour un seul lancement.
    static func registerWidgetToken(_ token: Data) async {
        await WidgetTokenRegistrar.shared.register(token)
    }

    /// Retire un token du registre — quand la dernière instance d'un widget
    /// disparaît, par exemple. Milō répond 404 s'il ne le détenait pas, ce qui
    /// n'est pas une erreur de notre point de vue.
    @discardableResult
    static func unregisterPushToken(_ token: Data) async -> Bool {
        let hex = token.map { String(format: "%02x", $0) }.joined()

        // Oublier le verdict **avant** de partir sur le réseau, et quel que soit
        // ce que Milō répondra.
        //
        // `registerWidgetToken` ne réenvoie pas un token dont il a noté qu'il
        // était déjà enregistré. Garder cette note après avoir retiré le token
        // rendait le retrait irréversible : reposer le widget rend le *même*
        // token, que la note fait alors tenir pour déjà connu — et il ne repart
        // jamais. Le push widget restait mort jusqu'à la réinstallation.
        //
        // Effacer inconditionnellement est le choix sûr : si le DELETE échoue,
        // on aura au pire un POST de plus, que Milō traite de façon idempotente.
        let defaults = UserDefaults(suiteName: appGroupID)
        if defaults?.string(forKey: registeredWidgetTokenKey) == hex {
            defaults?.removeObject(forKey: registeredWidgetTokenKey)
        }
        if defaults?.string(forKey: refusedWidgetTokenKey) == hex {
            defaults?.removeObject(forKey: refusedWidgetTokenKey)
            defaults?.removeObject(forKey: refusalDetailKey)
        }

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
    /// question à Milō tant qu'il n'a pas confirmé. `registerWidgetToken` décide
    /// seul s'il y a lieu de redemander : un token déjà accepté, comme un token
    /// déjà refusé pour sa forme, ne coûte aucune requête.
    @available(iOS 26.0, *)
    static func reconcileWidgetPushToken() async {
        guard let info = await WidgetCenter.shared.currentPushInfo else { return }
        await registerWidgetToken(info.token)
    }
}


/// Sérialise l'enregistrement du token widget.
///
/// Un acteur seul ne suffit pas, et c'est le piège : `await` à l'intérieur d'une
/// méthode d'acteur relâche l'isolation, si bien qu'un second appel entre
/// pendant que le premier est encore sur le réseau. Mesuré contre un serveur de
/// test — deux POST identiques pour un lancement, acteur ou pas, parce que les
/// deux avaient lu la consigne avant que l'un écrive son verdict.
///
/// Ce qui marche, c'est de retenir la tentative en vol : le second appelant la
/// rejoint au lieu d'en ouvrir une seconde, puis exécute la sienne — qui relit
/// la consigne que le premier vient d'écrire et s'arrête sans rien envoyer.
private actor WidgetTokenRegistrar {
    static let shared = WidgetTokenRegistrar()

    private var inFlight: Task<Void, Never>?

    func register(_ token: Data) async {
        if let current = inFlight {
            await current.value
        }
        let task = Task { await Self.perform(token) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Lit la consigne, interroge Milō, écrit le verdict.
    private static func perform(_ token: Data) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)

        guard defaults?.string(forKey: MiloAPIClient.registeredWidgetTokenKey) != hex,
              defaults?.string(forKey: MiloAPIClient.refusedWidgetTokenKey) != hex
        else { return }

        switch await MiloAPIClient.registerPushToken(token, kind: .widget) {
        case .registered:
            defaults?.set(hex, forKey: MiloAPIClient.registeredWidgetTokenKey)
            defaults?.removeObject(forKey: MiloAPIClient.refusedWidgetTokenKey)
            defaults?.removeObject(forKey: MiloAPIClient.refusalDetailKey)
        case .refused(let detail):
            // Consigné plutôt que tu : sans cette trace, un désaccord de forme
            // reste aussi muet que celui qu'on vient de passer des heures à
            // trouver.
            defaults?.set(hex, forKey: MiloAPIClient.refusedWidgetTokenKey)
            defaults?.set(detail, forKey: MiloAPIClient.refusalDetailKey)
        case .unavailable:
            break // Milō est peut-être éteint : la timeline repassera.
        }
    }
}
