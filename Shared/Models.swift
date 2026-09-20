import Foundation

/// Réponse de `POST /api/volume/adjust`
struct VolumeResponse: Codable {
    let status: String
    let volume_db: Double?
    let delta_db: Double?
}

struct VolumeStateData: Codable {
    let global_volume_db: Double
    /// Optionnels : un champ manquant ne doit pas faire passer Milō pour injoignable.
    let global_mute: Bool?
    /// `false` = aucun appareil ne pilote le volume via Milō (≠ `volume_control`,
    /// qui signale seulement que l'appareil local est un DAC).
    let any_volume_control: Bool?
}

/// État de volume exploitable par le widget, extrait de `GET /api/volume/state`
struct MiloVolumeState {
    let volumeDB: Double
    let isMuted: Bool
    let canControlVolume: Bool
}

struct VolumeStateResponse: Codable {
    let status: String
    let data: VolumeStateData?
}

struct MiloWidgetData {
    var volumeDB: Double
    var isConnected: Bool
    var canControlVolume: Bool
    var isMuted: Bool

    /// Milō est joignable ET le volume est réellement pilotable
    var isReady: Bool { isConnected && canControlVolume }

    static let placeholder = MiloWidgetData(
        volumeDB: -20,
        isConnected: true,
        canControlVolume: true,
        isMuted: false
    )

    static let disconnected = MiloWidgetData(
        volumeDB: 0,
        isConnected: false,
        canControlVolume: false,
        isMuted: false
    )
}
