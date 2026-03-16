import AppIntents
import WidgetKit

struct IncreaseVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Augmenter le volume"
    static var description: IntentDescription = "Augmente le volume de Milo"

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)
        let step = defaults?.double(forKey: "volume_step_db") ?? 3.0
        let effectiveStep = step > 0 ? step : 3.0

        // Premier tap : synchro rapide du volume réel avant l'optimistic update
        let lastInteraction = defaults?.double(forKey: "last_volume_interaction") ?? 0
        let isFirstTap = lastInteraction == 0 || (Date().timeIntervalSince1970 - lastInteraction) > 5
        var currentDB = defaults?.double(forKey: "last_volume_db") ?? -20
        if isFirstTap, let vol = try? await MiloAPIClient.getVolume(), let db = vol.volume_db {
            currentDB = db
        }

        defaults?.set(currentDB + effectiveStep, forKey: "last_volume_db")
        defaults?.set(Date().timeIntervalSince1970, forKey: "last_volume_interaction")

        // Reload immédiat pour switcher logo → volume sans attendre le réseau
        WidgetCenter.shared.reloadAllTimelines()

        // Fire-and-forget : envoie le delta au serveur
        MiloAPIClient.fireAdjustVolume(delta_db: effectiveStep)

        return .result()
    }
}
