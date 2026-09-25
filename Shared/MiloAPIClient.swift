import Foundation
import WidgetKit

enum MiloAPIError: Error {
    case invalidURL
    /// L'API a répondu mais Milō n'est pas en état de servir la requête
    case unavailable
}

struct MiloAPIClient {

    static let appGroupID = "group.leodurand.Milo-iOS"
    static let ipAddressKey = "milo_ip_address"
    static let ipResolvedAtKey = "milo_ip_resolved_at"
    static let volumeLimitMinKey = "volume_limit_min_db"
    static let volumeLimitMaxKey = "volume_limit_max_db"
    static let lastVolumeKey = "last_volume_db"
    static let lastInteractionKey = "last_volume_interaction"
    static let volumeStepKey = "volume_step_db"
    static let reachableKey = "milo_reachable"
    static let canControlKey = "milo_can_control_volume"
    static let mutedKey = "milo_muted"
    /// Repli si `step_mobile_db` n'a pas encore pu être lu (backend ancien, hors ligne)
    static let volumeStepFallbackDB = 3.0

    /// `UserDefaults.double(forKey:)` renvoie 0 quand la clé est absente, ce qui rend
    /// impossible de distinguer « pas encore synchronisé » de « vraie valeur 0 ».
    /// Cet accesseur passe par `object(forKey:)` pour que le défaut s'applique vraiment.
    static func sharedDouble(forKey key: String, default defaultValue: Double) -> Double {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let value = defaults.object(forKey: key) as? Double else { return defaultValue }
        return value
    }

    static func sharedBool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let value = defaults.object(forKey: key) as? Bool else { return defaultValue }
        return value
    }

    /// Mémorise ce qu'on vient d'apprendre du réseau, pour que le chemin optimiste
    /// du widget n'ait pas à supposer que Milō est joignable.
    static func cacheReachability(_ reachable: Bool,
                                  canControlVolume: Bool? = nil,
                                  muted: Bool? = nil) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(reachable, forKey: reachableKey)
        if let canControlVolume { defaults?.set(canControlVolume, forKey: canControlKey) }
        if let muted { defaults?.set(muted, forKey: mutedKey) }
    }

    /// Force le nom d'hôte plutôt que l'IP mise en cache.
    ///
    /// Mesuré depuis l'extension Now Playing, dans le même processus et à la
    /// même seconde : `https://www.apple.com` répond 200,
    /// `http://192.168.1.55` échoue en -1009, et `http://milo.local` répond 200.
    /// iOS traite la connexion directe vers une IP privée comme un accès au
    /// réseau local à autoriser — ce qu'une extension ne peut pas demander,
    /// faute d'écran — là où la résolution `.local` passe.
    ///
    /// Ce refus visait un chemin **non lié** à une interface. Lié au Wi-Fi, la
    /// même IP passe (mesuré le 25/09/2026) : c'est ce que fait
    /// `scopedTransport`, que l'extension pose aussi. Cette URL en `milo.local`
    /// n'y sert plus qu'à reconnaître les requêtes destinées à Milō.
    ///
    /// L'IP reste préférable partout ailleurs : elle évite une résolution mDNS
    /// à chaque requête, ce qui compte pour un widget dont le processus est tué
    /// s'il traîne.
    nonisolated(unsafe) static var prefersHostname = false

    /// La connexion à Milō, établie une fois et réutilisée.
    ///
    /// C'est ce que la documentation d'Apple demande explicitement pour une
    /// extension Now Playing : « The framework caches the sessions your
    /// extension returns and routes subsequent updates and commands to the same
    /// instance. **If your extension connects to a backend or device, establish
    /// that connection once and reuse it across `session(_:)` calls.** »
    ///
    /// Pourquoi ça compte ici, mesuré le 19/09/2026 : une commande qui ouvrait
    /// sa propre connexion rejouait la résolution de `milo.local` **et** le
    /// tirage NECP à chaque appui, et perdait de temps en temps. À 19:39:21 le
    /// nom se résout en 1 ms, puis pas un seul chemin ne devient utilisable —
    /// douze `failed resolver`, cent quatorze `waiting`, **zéro `ready`** — et
    /// la commande expire en −1001. À 19:40:35, même processus, cinq candidats
    /// refusés puis un qui passe, et le `POST` aboutit. La différence n'est pas
    /// dans le code : c'est la course, rejouée à chaque fois.
    ///
    /// Une connexion déjà établie ne la rejoue pas — mais seulement tant que le
    /// processus vit, et `mediaremoted` termine celui-ci sans arrêt : trois
    /// `RBSTerminateRequest` et trois PID distincts en quinze secondes, mesurés
    /// à 19:57. Le conseil d'Apple suppose un processus qui dure ; ici la
    /// réutilisation ne porte qu'à l'intérieur d'un même réveil, ce qui couvre
    /// le cas où plusieurs commandes se suivent. Au-delà, c'est le second essai
    /// de `sendControl` qui rattrape.
    ///
    /// Un préchauffage explicite a été essayé et retiré : il partait bien
    /// (`milo_warm_trace` = « lancé ») et n'aboutissait jamais — pas un seul
    /// `HEAD /` de l'extension dans le journal de nginx en vingt minutes. Une
    /// tâche détachée ne survit pas au processus qui l'a lancée, et une
    /// connexion TCP encore moins.
    /// Deux chemins restent délibérément sur `URLSession.shared` :
    ///
    /// - **les pochettes**, qui pèsent des centaines de kilooctets et partent le
    ///   plus souvent vers Internet. Les laisser ici, c'est mettre une commande
    ///   derrière un téléchargement d'un demi-mégaoctet ;
    /// - **la sonde** de `MiloRemoteSession`, dont tout l'objet est de mesurer
    ///   ce qu'une connexion neuve obtient. Sur un pool réutilisé elle mesurerait
    ///   le pool.
    nonisolated(unsafe) static let lan: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Ne pas attendre un réseau qui n'est pas là : dans une extension, un
        // rappel qui patiente est un rappel que le système tue.
        configuration.waitsForConnectivity = false
        // Deux, pas une : la sonde ou un maintien en vie ne doit pas faire la
        // queue devant une commande que l'utilisateur vient de déclencher.
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Le transport des requêtes adressées à Milō, quand l'hôte en impose un.
    ///
    /// Seule l'extension Now Playing en pose un — `MiloScopedHTTP`, lié au
    /// Wi-Fi : sous la restriction réseau que `mediaremoted` lui impose, un
    /// chemin non lié vers le LAN est refusé par NECP, et `URLSession` ne sait
    /// pas lier une requête à une interface. L'app et le widget n'ont pas cette
    /// restriction et gardent `URLSession`.
    nonisolated(unsafe) static var scopedTransport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?

    /// `session.data(for:)`, sauf pour une requête adressée à Milō quand un
    /// transport lié est posé. Tout ce qui part vers Milō passe par ici.
    static func lanData(for request: URLRequest,
                        session: URLSession = lan) async throws -> (Data, URLResponse) {
        if let scopedTransport, let host = request.url?.host, isMiloHost(host) {
            return try await scopedTransport(request)
        }
        return try await session.data(for: request)
    }

    private static func isMiloHost(_ host: String) -> Bool {
        if host == "milo.local" { return true }
        let cached = UserDefaults(suiteName: appGroupID)?.string(forKey: ipAddressKey)
        return host == cached
    }

    static func baseURL() -> String {
        if prefersHostname { return "http://milo.local" }
        if let sharedDefaults = UserDefaults(suiteName: appGroupID),
           let ip = sharedDefaults.string(forKey: ipAddressKey), !ip.isEmpty {
            return "http://\(ip)"
        }
        return "http://milo.local"
    }

    // MARK: - Résolution de l'adresse

    /// L'adresse de Milō ne bouge qu'au renouvellement du bail DHCP : inutile de
    /// relancer une résolution à chaque sondage.
    static let ipResolutionInterval: TimeInterval = 300

    /// Ce qu'on accorde à un candidat pour prouver qu'il est bien Milō. Court
    /// délibérément : une adresse morte doit coûter moins qu'un sondage, et
    /// `.local` en produit rarement plus de deux.
    private static let candidateProbeTimeout: TimeInterval = 1.5

    /// Quand la dernière passe a échoué, et le répit qu'on s'accorde après.
    private static let ipProbedAtKey = "milo_ip_probed_at"
    private static let ipProbeRetryDelay: TimeInterval = 30

    /// Résout `milo.local` et mémorise l'adresse **qui répond**, pour le widget.
    ///
    /// `URLSession` ne réécrit pas l'URL de la réponse avec l'adresse résolue :
    /// `httpResponse.url?.host` vaut toujours « milo.local », si bien que la clé
    /// partagée resterait vide et que l'extension WidgetKit referait une
    /// résolution mDNS à chaque réveil — lente, et fragile dans son budget.
    ///
    /// Pourquoi on *teste* au lieu de prendre la première adresse venue : sur ce
    /// réseau, `milo.local` a deux réponses concurrentes. Le mDNS multicast rend
    /// l'adresse réelle du Pi ; une route Split DNS du tailnet envoie `.local`
    /// au NAS, qui sert une entrée statique périmée. La course se rejoue à
    /// chaque résolution, et `getaddrinfo` rend les deux, dans un ordre qui n'est
    /// pas le nôtre. Prendre la première et l'épingler cinq minutes, c'est offrir
    /// à l'app une panne totale un tirage sur deux — symptôme qui se lit comme
    /// une dizaine de bugs distincts : volume qui s'applique parfois, commandes
    /// muettes, « Milo n'est pas disponible » qui se répare tout seul.
    ///
    /// Ça ne remplace pas de rendre `.local` au mDNS côté réseau ; ça empêche
    /// seulement l'app d'être la victime de ce qu'elle ne contrôle pas.
    static func resolveAndCacheIPAddress() async {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        let now = Date().timeIntervalSince1970
        let hasCachedIP = defaults.string(forKey: ipAddressKey)?.isEmpty == false
        let resolvedAt = defaults.object(forKey: ipResolvedAtKey) as? Double ?? 0
        if hasCachedIP, now - resolvedAt < ipResolutionInterval { return }

        // Répit après une passe qui n'a rien trouvé, pour ne pas la rejouer à
        // chaque sondage. Court devant les cinq minutes d'une réussite : ce
        // qu'on attend ici, c'est que le réseau revienne, pas qu'un bail DHCP
        // change.
        let probedAt = defaults.object(forKey: ipProbedAtKey) as? Double ?? 0
        if now - probedAt < ipProbeRetryDelay { return }

        // Hors du pool coopératif : `getaddrinfo` bloque le temps de la
        // résolution, et sur ce réseau la branche unicast peut consommer ses
        // trois secondes entières. Un `await` qui retient un thread du pool en
        // affame le reste de l'app.
        let candidates = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: resolveIPv4Candidates(for: "milo.local"))
            }
        }
        guard !candidates.isEmpty else {
            // Le nom n'a rien rendu. Marqué comme une passe infructueuse, sans
            // quoi chaque sondage repaie un `getaddrinfo` bloquant — c'est
            // précisément ce que le répit existe pour borner.
            //
            // L'adresse en cache est **gardée**, contrairement à la branche du
            // dessous : une résolution qui échoue ne dit rien de la validité de
            // ce qu'on avait déjà. Si elle est morte, c'est à la requête qui
            // s'en sert de le découvrir — voir `forgetCachedIPAddress`.
            defaults.set(Date().timeIntervalSince1970, forKey: ipProbedAtKey)
            return
        }

        guard let ip = await firstReachable(among: candidates, probe: { await respondsAsMilo($0) })
        else {
            // Aucun candidat ne répond : **retirer** l'ancienne plutôt que la
            // laisser en place. `baseURL()` retombe alors sur `milo.local`, ce
            // qui donne au moins une chance au tirage suivant, là où une adresse
            // morte en cache condamne toutes les requêtes jusqu'à expiration.
            //
            // Le sondage est court — 1,5 s par candidat — donc un creux du Wi-Fi
            // suffit à faire échouer une adresse parfaitement valide. D'où la
            // marque de tentative : sans elle, la clé effacée rend `hasCachedIP`
            // faux, la garde de fraîcheur ne retient plus rien, et **chaque**
            // sondage repaie `getaddrinfo` et les sondes en entier.
            defaults.removeObject(forKey: ipAddressKey)
            defaults.removeObject(forKey: ipResolvedAtKey)
            defaults.set(Date().timeIntervalSince1970, forKey: ipProbedAtKey)
            return
        }

        defaults.set(ip, forKey: ipAddressKey)
        defaults.set(Date().timeIntervalSince1970, forKey: ipResolvedAtKey)
        defaults.removeObject(forKey: ipProbedAtKey)
    }

    /// Le premier candidat que `probe` accepte, dans l'ordre donné.
    ///
    /// Séquentiel et non concurrent : c'est tout l'objet de l'ordre. `getaddrinfo`
    /// place en tête ce que le système juge préférable, et on ne s'en écarte que
    /// si ça ne répond pas.
    ///
    /// Extraite pour être testable sans réseau — c'est la seule partie de la
    /// résolution qui porte une décision.
    static func firstReachable(among candidates: [String],
                               probe: (String) async -> Bool) async -> String? {
        for candidate in candidates where await probe(candidate) { return candidate }
        return nil
    }

    /// Toutes les adresses IPv4 que le système associe à ce nom, dédupliquées,
    /// dans l'ordre où il les rend.
    ///
    /// La liste **entière**, et pas seulement `info.pointee` : les deux réponses
    /// concurrentes de `milo.local` y sont côte à côte, et n'en lire qu'une
    /// revenait à tirer au sort.
    ///
    /// Bloquant : `getaddrinfo` attend la résolution.
    private static func resolveIPv4Candidates(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0 else { return [] }
        defer { freeaddrinfo(info) }

        var found: [String] = []
        var node = info
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr,
                           current.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer)
                if !ip.isEmpty, !found.contains(ip) { found.append(ip) }
            }
            node = current.pointee.ai_next
        }
        return found
    }

    /// Cette adresse sert-elle bien l'API de Milō ?
    ///
    /// `/api/volume/state` plutôt que la racine : nginx sert la SPA sur `/`, et
    /// n'importe quel serveur web du LAN répondrait 200 à un `HEAD /`. On demande
    /// une route que seul Milō a.
    private static func respondsAsMilo(_ ip: String) async -> Bool {
        guard let url = URL(string: "http://\(ip)/api/volume/state") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = candidateProbeTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (_, response) = try? await lanData(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Oublier l'adresse en cache après un échec réseau, pour que le sondage
    /// suivant re-résolve au lieu d'attendre les cinq minutes.
    ///
    /// **Y compris depuis le widget**, qui ne sait pourtant pas repeupler cette
    /// clé — seul le sondage de l'app appelle `resolveAndCacheIPAddress`. Le
    /// réserver à l'app a été essayé et retiré le 20/09/2026 : une adresse morte
    /// que personne n'a le droit de jeter, c'est un widget qui vise le vide
    /// jusqu'au prochain passage de l'app au premier plan — après un changement
    /// de bail, indéfiniment. L'effacer coûte une résolution mDNS par requête,
    /// ce que le widget faisait de toute façon avant que cette clé existe.
    /// Un ralentissement se préfère à une panne.
    ///
    /// Appelée sur les erreurs d'`URLSession` uniquement, jamais sur un code HTTP :
    /// une route qui répond 400 prouve que l'adresse est la bonne.
    ///
    /// Pas de réessai ici : le budget d'une commande ne le permet pas — c'est
    /// déjà la raison d'être du second essai de `sendControl`. On se contente de
    /// ne pas rester collé à une adresse qu'on vient de voir échouer.
    private static func forgetCachedIPAddress(after error: Error) {
        guard !prefersHostname else { return }
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return }
        // Énumérés plutôt que « toute erreur d'URL » : `NSURLErrorCancelled`
        // arrive à chaque navigation annulée et ne dit rien de l'adresse.
        // `-1009` est dans la liste parce que c'est ce que rend iOS quand il
        // refuse une IP privée, pas seulement quand le réseau manque.
        switch error.code {
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet:
            let defaults = UserDefaults(suiteName: appGroupID)
            defaults?.removeObject(forKey: ipAddressKey)
            defaults?.removeObject(forKey: ipResolvedAtKey)
        default:
            break
        }
    }

    // MARK: - Volume

    static func getVolume() async throws -> MiloVolumeState {
        let data = try await get(path: "/api/volume/state")
        let state = try JSONDecoder().decode(VolumeStateResponse.self, from: data)
        // L'API répond toujours en HTTP 200 : l'échec se lit dans `status`, pas dans le code.
        guard state.status == "success", let payload = state.data else {
            throw MiloAPIError.unavailable
        }
        return MiloVolumeState(
            volumeDB: payload.global_volume_db,
            isMuted: payload.global_mute ?? false,
            canControlVolume: payload.any_volume_control ?? true
        )
    }

    /// Fire-and-forget : lance la requête sans bloquer l'appelant
    static func fireAdjustVolume(delta_db: Double) {
        guard let url = URL(string: baseURL() + "/api/volume/adjust") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyDict: [String: Any] = ["delta_db": delta_db, "show_bar": true]
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else { return }
        request.httpBody = body
        let requestTime = Date().timeIntervalSince1970
        lan.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let response = try? JSONDecoder().decode(VolumeResponse.self, from: data),
                  response.status == "success",
                  let db = response.volume_db else {
                cacheReachability(false)
                return
            }
            let defaults = UserDefaults(suiteName: appGroupID)
            cacheReachability(true)
            // Réponse périmée : un tap plus récent a déjà écrit sa valeur optimiste,
            // l'écraser ferait reculer l'affichage pendant une rafale de taps.
            guard requestTime >= (defaults?.double(forKey: lastInteractionKey) ?? 0) else { return }
            defaults?.set(db, forKey: lastVolumeKey)
            defaults?.set(requestTime, forKey: lastInteractionKey)
            // Debounce 300ms : ne reload que si aucun nouveau tap entre-temps
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if defaults?.double(forKey: lastInteractionKey) == requestTime {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }.resume()
    }

    /// Synchronise limites et pas de volume depuis les settings backend.
    ///
    /// `/api/settings/volume-limits` et `/api/settings/volume-steps` sont en écriture
    /// seule (PUT) : toute la lecture passe par `/api/settings/bulk`, en une requête —
    /// ce qui convient à un process court comme une extension WidgetKit, incapable de
    /// maintenir le WebSocket `volume_changed`.
    ///
    /// `volume_steps` est récent côté Milō : un backend antérieur répond 200 sans ce
    /// bloc. Dans ce cas on conserve la dernière valeur connue, ou `volumeStepFallbackDB`.
    static func syncVolumeSettings() async {
        guard let data = try? await get(path: "/api/settings/bulk"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let defaults = UserDefaults(suiteName: appGroupID)

        // Les deux bornes ensemble ou aucune : un cache mi-ancien mi-neuf pourrait
        // donner min > max, ce qui inverserait le clamp.
        if let limits = json["volume_limits"] as? [String: Any],
           let minDB = limits["min_db"] as? Double,
           let maxDB = limits["max_db"] as? Double,
           minDB < maxDB {
            defaults?.set(minDB, forKey: volumeLimitMinKey)
            defaults?.set(maxDB, forKey: volumeLimitMaxKey)
        }

        // Absent sur un backend plus ancien : on ne touche alors pas au cache.
        if let steps = json["volume_steps"] as? [String: Any],
           let mobileStep = steps["step_mobile_db"] as? Double, mobileStep > 0 {
            defaults?.set(mobileStep, forKey: volumeStepKey)
        }
    }

    /// Bornes de repli, en vigueur tant que `/api/settings/bulk` n'a pas répondu.
    ///
    /// **Ces bornes ne servent qu'au widget et aux App Intents**, qui raisonnent
    /// vraiment en décibels — le widget affiche un niveau, les intents ajoutent
    /// un pas — et qui appellent `syncVolumeSettings()` dans la même passe que
    /// leur lecture. Le chemin Now Playing, lui, ne convertit plus rien : il
    /// parle à Milō sur l'échelle 0…1 du curseur et le laisse posséder ses
    /// bornes. Ne pas l'y ramener. L'extension Now Playing n'appelle pas
    /// `syncVolumeSettings()` et ne peut pas se le permettre — un processus que
    /// `mediaremoted` termine en quelques secondes, avec trois secondes de
    /// budget réseau par commande — si bien que sa copie restait celle-ci
    /// indéfiniment : elle a converti sur -80…-21 pendant que l'appareil
    /// tournait sur -78…-8, et le volume montait trois fois moins que demandé.
    ///
    /// Le repli haut ne doit surtout pas être 0 dB : aucun Milō n'autorise le volume
    /// jusqu'à 0, si bien qu'un widget non encore synchronisé affichait une valeur
    /// optimiste que le backend n'appliquerait jamais, puis la voyait reculer à la
    /// première réponse réseau. Sous-estimer est le seul sens sûr. Mêmes valeurs que
    /// `VolumeDefaults` côté Milo-Mac, pour que les deux clients se replient pareil.
    static let volumeLimitFallback = (min: -80.0, max: -21.0)

    static func volumeLimits() -> (min: Double, max: Double) {
        let lo = sharedDouble(forKey: volumeLimitMinKey, default: volumeLimitFallback.min)
        let hi = sharedDouble(forKey: volumeLimitMaxKey, default: volumeLimitFallback.max)
        return lo < hi ? (min: lo, max: hi) : volumeLimitFallback
    }

    /// Pas de volume du widget : `step_mobile_db` s'il a pu être synchronisé, sinon repli
    static func volumeStep() -> Double {
        let step = sharedDouble(forKey: volumeStepKey, default: volumeStepFallbackDB)
        return step > 0 ? step : volumeStepFallbackDB
    }

    // MARK: - Transport

    /// Interne plutôt que `private` : `MiloAPIClient+Media` vit dans un autre fichier et
    /// `private` est à portée de fichier, même pour une extension du même type.
    ///
    /// Le délai par défaut de 3 s est celui du widget, dont le process est tué s'il traîne.
    /// Les routes de la bibliothèque musicale, elles, interrogent un serveur Subsonic
    /// derrière le Pi et sont franchement plus lentes ; elles passent un délai plus long.
    static func get(path: String, timeout: TimeInterval = 3) async throws -> Data {
        guard let url = URL(string: baseURL() + path) else { throw MiloAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, _) = try await lanData(for: request)
            return data
        } catch {
            forgetCachedIPAddress(after: error)
            throw error
        }
    }

    @discardableResult
    static func post(path: String, body: Data? = nil, timeout: TimeInterval = 3) async throws -> Data {
        guard let url = URL(string: baseURL() + path) else { throw MiloAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, _) = try await lanData(for: request)
            return data
        } catch {
            forgetCachedIPAddress(after: error)
            throw error
        }
    }

}
