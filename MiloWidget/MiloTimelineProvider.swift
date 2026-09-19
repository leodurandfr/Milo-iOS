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
            // Rattrapage : si l'enregistrement du token a échoué au moment où
            // WidgetKit l'a émis, c'est ici qu'on repose la question.
            if #available(iOS 26.0, *) {
                await MiloAPIClient.reconcileWidgetPushToken()
            }

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

            // Milō injoignable : re-tenter plus tôt pour que le logo se rallume vite
            // (WidgetKit reste libre d'étaler ces rafraîchissements selon son budget)
            let refreshMinutes = data.isReady ? 15 : 5
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: refreshMinutes, to: .now)!
            let timeline = Timeline(entries: entries, policy: .after(nextUpdate))
            completion(timeline)
        }
    }

    private func hasRecentInteraction() -> Bool {
        guard let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID) else { return false }
        let timestamp = defaults.double(forKey: MiloAPIClient.lastInteractionKey)
        guard timestamp > 0 else { return false }
        return Date().timeIntervalSince1970 - timestamp < 5
    }

    private func fetchMiloData() async -> MiloWidgetData {
        // Pendant les interactions rapides, utiliser le cache UserDefaults pour éviter
        // un appel réseau bloquant à chaque reload de timeline. On relit l'accessibilité
        // mémorisée plutôt que de supposer que Milō répond : sinon un tap sur un Milō
        // éteint rallumerait le logo et afficherait un volume inventé.
        if hasRecentInteraction() {
            return MiloWidgetData(
                volumeDB: MiloAPIClient.sharedDouble(forKey: MiloAPIClient.lastVolumeKey, default: -20),
                sourceName: "",
                isConnected: MiloAPIClient.sharedBool(forKey: MiloAPIClient.reachableKey, default: true),
                canControlVolume: MiloAPIClient.sharedBool(forKey: MiloAPIClient.canControlKey, default: true),
                isMuted: MiloAPIClient.sharedBool(forKey: MiloAPIClient.mutedKey, default: false),
                availableSources: []
            )
        }

        // Les deux requêtes partent en parallèle, et la synchro est attendue : une
        // extension WidgetKit est détruite dès `completion`, un Task non attendu
        // n'aurait aucune garantie de s'exécuter.
        async let state = MiloAPIClient.getVolume()
        async let settings: Void = MiloAPIClient.syncVolumeSettings()
        await settings

        do {
            let volume = try await state

            // Garder le cache à jour pour que le premier tap optimiste soit juste
            UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                .set(volume.volumeDB, forKey: MiloAPIClient.lastVolumeKey)
            MiloAPIClient.cacheReachability(true,
                                            canControlVolume: volume.canControlVolume,
                                            muted: volume.isMuted)

            return MiloWidgetData(
                volumeDB: volume.volumeDB,
                sourceName: "",
                isConnected: true,
                canControlVolume: volume.canControlVolume,
                isMuted: volume.isMuted,
                availableSources: []
            )
        } catch {
            MiloAPIClient.cacheReachability(false, canControlVolume: false)
            return .disconnected
        }
    }
}
