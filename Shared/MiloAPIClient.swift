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
    /// L'IP reste préférable partout ailleurs : elle évite une résolution mDNS
    /// à chaque requête, ce qui compte pour un widget dont le processus est tué
    /// s'il traîne.
    nonisolated(unsafe) static var prefersHostname = false

    static func baseURL() -> String {
        if prefersHostname { return "http://milo.local" }
        if let sharedDefaults = UserDefaults(suiteName: appGroupID),
           let ip = sharedDefaults.string(forKey: ipAddressKey), !ip.isEmpty {
            return "http://\(ip)"
        }
        return "http://milo.local"
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
        URLSession.shared.dataTask(with: request) { data, _, _ in
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

    // MARK: - Audio

    static func changeSource(_ name: String) async throws {
        _ = try await post(path: "/api/audio/source/\(name)")
    }

    // MARK: - Settings

    static func getDockApps() async throws -> DockAppsResponse {
        let data = try await get(path: "/api/settings/dock-apps")
        return try JSONDecoder().decode(DockAppsResponse.self, from: data)
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
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
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
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

}
