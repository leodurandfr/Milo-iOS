import AppIntents
import WidgetKit

struct IncreaseVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Augmenter le volume"
    static var description: IntentDescription = "Augmente le volume de Milo"

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)

        // Tap qui ouvre une nouvelle rafale (pas seulement le tout premier de la vie
        // du widget) : on resynchronise volume réel ET réglages avant l'optimistic
        // update, sinon on partirait d'un cache périmé et du pas de repli.
        // Les deux requêtes sont parallèles : l'attente reste celle d'un seul aller-retour.
        let lastInteraction = MiloAPIClient.sharedDouble(forKey: MiloAPIClient.lastInteractionKey, default: 0)
        let startsNewBurst = lastInteraction == 0 || (Date().timeIntervalSince1970 - lastInteraction) > 5
        var currentDB = MiloAPIClient.sharedDouble(forKey: MiloAPIClient.lastVolumeKey, default: -20)
        if startsNewBurst {
            async let state = MiloAPIClient.getVolume()
            async let settings: Void = MiloAPIClient.syncVolumeSettings()
            await settings
            if let volume = try? await state {
                currentDB = volume.volumeDB
                MiloAPIClient.cacheReachability(true,
                                                canControlVolume: volume.canControlVolume,
                                                muted: volume.isMuted)
            } else {
                MiloAPIClient.cacheReachability(false)
            }
        }

        // Lu après la synchro : `step_mobile_db` si Milō l'expose, sinon repli
        let effectiveStep = MiloAPIClient.volumeStep()

        // Le backend borne le volume : on borne aussi l'affichage optimiste,
        // sinon le widget affiche une valeur que Milō n'appliquera jamais.
        let limits = MiloAPIClient.volumeLimits()
        let targetDB = min(max(currentDB + effectiveStep, limits.min), limits.max)

        defaults?.set(targetDB, forKey: MiloAPIClient.lastVolumeKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: MiloAPIClient.lastInteractionKey)

        // Reload immédiat pour switcher logo → volume sans attendre le réseau
        WidgetCenter.shared.reloadAllTimelines()

        // Fire-and-forget : envoie le delta au serveur
        MiloAPIClient.fireAdjustVolume(delta_db: effectiveStep)

        return .result()
    }
}
