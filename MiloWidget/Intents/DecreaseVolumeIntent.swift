import AppIntents
import WidgetKit

struct DecreaseVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Diminuer le volume"
    static var description: IntentDescription = "Diminue le volume de Milo"

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)
        let step = defaults?.double(forKey: "volume_step_db") ?? 3.0
        let effectiveStep = step > 0 ? step : 3.0

        // Optimistic update immédiat
        let currentDB = defaults?.double(forKey: "last_volume_db") ?? -20
        defaults?.set(currentDB - effectiveStep, forKey: "last_volume_db")
        defaults?.set(Date().timeIntervalSince1970, forKey: "last_volume_interaction")

        // Fire-and-forget : ne bloque pas perform()
        // Le reloadAllTimelines() est appelé dans le callback de fireAdjustVolume
        // pour éviter de reconstruire le widget pendant les taps rapides
        MiloAPIClient.fireAdjustVolume(delta_db: -effectiveStep)

        return .result()
    }
}
