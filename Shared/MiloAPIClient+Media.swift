import Foundation

/// Ce que l'écran verrouillé renvoie vers Milō.
///
/// Tout part en HTTP sur le LAN. APNs ne porte que l'état descendant : rien de
/// ce qui suit n'emprunte Internet, et rien n'a besoin que Milō soit joignable
/// de l'extérieur.
extension MiloAPIClient {

    enum TransportCommand: String {
        case play = "resume"
        case pause
        case playPause = "playpause"
        case next
        case previous = "prev"
    }

    /// Source active du moment, telle que `/api/audio/state` la nomme.
    ///
    /// `/api/audio/control/{source}` s'adresse à une source précise : il n'existe
    /// pas de « commande au système ». On relit donc la source courante juste
    /// avant, plutôt que de mémoriser celle du dernier push — elle peut avoir
    /// changé sous nos pieds, et la session survit justement à ce changement.
    private static func activeSource() async -> String? {
        guard let data = try? await get(path: "/api/audio/state"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["active_source"] as? String
    }

    /// Envoie une commande de transport. Sans effet si aucune source n'est active.
    static func fireTransport(_ command: TransportCommand) async {
        guard let source = await activeSource() else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["command": command.rawValue])
        _ = try? await post(path: "/api/audio/control/\(source)", body: body)
    }

    /// Déplace la tête de lecture. Milō attend des millisecondes ; le système,
    /// lui, raisonne en secondes.
    static func fireSeek(toSeconds position: TimeInterval) async {
        guard let source = await activeSource() else { return }
        let body = try? JSONSerialization.data(withJSONObject: [
            "command": "seek",
            "data": ["position_ms": Int(position * 1000)]
        ])
        _ = try? await post(path: "/api/audio/control/\(source)", body: body)
    }

    /// Applique un niveau de curseur à une enceinte.
    ///
    /// Le curseur donne 0…1, Milō stocke des dB : on refait le chemin que Milō a
    /// fait dans l'autre sens, avec les mêmes bornes. Écriture **absolue** — un
    /// delta serait une lecture-modification-écriture en course contre l'encodeur
    /// rotatif de l'appareil et son propre écran, ce que ces routes existent
    /// précisément pour éviter.
    static func setClientVolume(mac: String, normalized level: Float) async {
        let limits = volumeLimits()
        let clamped = min(max(Double(level), 0), 1)
        let db = limits.min + clamped * (limits.max - limits.min)

        // La route veut douze caractères hex, sans séparateurs — d'où son
        // paramètre `mac_url`. Échapper les `:` en `%3A` donne un 400 « Expected
        // 12 hex characters », mesuré ; on les retire donc plutôt.
        let plain = mac.replacingOccurrences(of: ":", with: "")
        guard let url = URL(string: baseURL() + "/api/volume/client/mac/\(plain)")
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["volume_db": db])

        // Le code est lu, contrairement aux commandes de transport. La route
        // répond 400 hors des bornes au lieu de borner, et un curseur qui revient
        // en place sans rien dire est précisément comment l'encodage du MAC est
        // resté invisible. La trace est consultable dans l'app group.
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        if http.statusCode != 200 {
            UserDefaults(suiteName: appGroupID)?
                .set("volume \(plain) -> HTTP \(http.statusCode)", forKey: "milo_volume_write_error")
        }
    }
}
