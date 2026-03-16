import WidgetKit
import Foundation

struct MiloTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> MiloWidgetEntry {
        MiloWidgetEntry(date: .now, data: .placeholder, showVolume: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (MiloWidgetEntry) -> Void) {
        completion(MiloWidgetEntry(date: .now, data: .placeholder, showVolume: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MiloWidgetEntry>) -> Void) {
        Task {
            let data = await fetchMiloData()
            let recentInteraction = hasRecentInteraction()

            var entries: [MiloWidgetEntry] = []

            if recentInteraction {
                // Montrer le volume maintenant
                entries.append(MiloWidgetEntry(date: .now, data: data, showVolume: true))
                // Revenir au logo après 3 secondes
                let hideDate = Calendar.current.date(byAdding: .second, value: 3, to: .now)!
                entries.append(MiloWidgetEntry(date: hideDate, data: data, showVolume: false))
            } else {
                entries.append(MiloWidgetEntry(date: .now, data: data, showVolume: false))
            }

            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
            let timeline = Timeline(entries: entries, policy: .after(nextUpdate))
            completion(timeline)
        }
    }

    private func hasRecentInteraction() -> Bool {
        guard let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID) else { return false }
        let timestamp = defaults.double(forKey: "last_volume_interaction")
        guard timestamp > 0 else { return false }
        return Date().timeIntervalSince1970 - timestamp < 5
    }

    private func fetchMiloData() async -> MiloWidgetData {
        // Pendant les interactions rapides, utiliser directement le cache UserDefaults
        // pour éviter un appel réseau bloquant à chaque reload de timeline
        if hasRecentInteraction(),
           let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID) {
            let volumeDB = defaults.double(forKey: "last_volume_db")
            return MiloWidgetData(
                volumeDB: volumeDB,
                sourceName: "",
                isConnected: true,
                availableSources: []
            )
        }

        do {
            let volume = try await MiloAPIClient.getVolume()
            let volumeDB = volume.volume_db ?? -20

            // Garder le cache à jour pour que le premier tap optimiste soit juste
            UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                .set(volumeDB, forKey: "last_volume_db")

            // Sync step + limites en background (non bloquant pour la timeline)
            Task { await MiloAPIClient.syncVolumeSettings() }

            return MiloWidgetData(
                volumeDB: volumeDB,
                sourceName: "",
                isConnected: true,
                availableSources: []
            )
        } catch {
            return .disconnected
        }
    }
}
