import Foundation
import WidgetKit

enum MiloAPIError: Error {
    case invalidURL
}

struct MiloAPIClient {

    static let appGroupID = "group.leodurand.Milo-iOS"
    static let ipAddressKey = "milo_ip_address"

    static func baseURL() -> String {
        if let sharedDefaults = UserDefaults(suiteName: appGroupID),
           let ip = sharedDefaults.string(forKey: ipAddressKey), !ip.isEmpty {
            return "http://\(ip)"
        }
        return "http://milo.local"
    }

    // MARK: - Volume

    static func getVolume() async throws -> VolumeResponse {
        let data = try await get(path: "/api/volume/")
        return try JSONDecoder().decode(VolumeResponse.self, from: data)
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
                  let db = response.volume_db else { return }
            let defaults = UserDefaults(suiteName: appGroupID)
            defaults?.set(db, forKey: "last_volume_db")
            defaults?.set(requestTime, forKey: "last_volume_interaction")
            // Debounce 300ms : ne reload que si aucun nouveau tap entre-temps
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if defaults?.double(forKey: "last_volume_interaction") == requestTime {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }.resume()
    }

    /// Récupère le step mobile depuis /api/volume/state et le cache dans UserDefaults
    static func syncVolumeStep() async {
        guard let data = try? await get(path: "/api/volume/state") else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let step = json["step_mobile_db"] as? Double, step > 0 else { return }
        UserDefaults(suiteName: appGroupID)?.set(step, forKey: "volume_step_db")
    }

    // MARK: - Audio

    static func getAudioState() async throws -> AudioStateResponse {
        let data = try await get(path: "/api/audio/state")
        return try JSONDecoder().decode(AudioStateResponse.self, from: data)
    }

    static func changeSource(_ name: String) async throws {
        _ = try await post(path: "/api/audio/source/\(name)")
    }

    // MARK: - Settings

    static func getDockApps() async throws -> DockAppsResponse {
        let data = try await get(path: "/api/settings/dock-apps")
        return try JSONDecoder().decode(DockAppsResponse.self, from: data)
    }

    // MARK: - Private

    private static func get(path: String) async throws -> Data {
        guard let url = URL(string: baseURL() + path) else { throw MiloAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func post(path: String, body: Data? = nil, timeout: TimeInterval = 3) async throws -> Data {
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
