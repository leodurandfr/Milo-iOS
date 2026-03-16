import Foundation

struct VolumeResponse: Codable {
    let status: String
    let volume_db: Double?
    let delta_db: Double?
}

struct VolumeStateData: Codable {
    let global_volume_db: Double
    let global_mute: Bool
}

struct VolumeStateResponse: Codable {
    let status: String
    let data: VolumeStateData?
}

struct AudioStateResponse: Codable {
    let status: String
    let source: String?
    let title: String?
    let artist: String?
}

struct DockAppsResponse: Codable {
    let enabled_apps: [String]
}

struct MiloWidgetData {
    var volumeDB: Double
    var sourceName: String
    var isConnected: Bool
    var availableSources: [String]

    static let placeholder = MiloWidgetData(
        volumeDB: -20,
        sourceName: "librespot",
        isConnected: true,
        availableSources: ["librespot", "bluetooth", "radio"]
    )

    static let disconnected = MiloWidgetData(
        volumeDB: 0,
        sourceName: "",
        isConnected: false,
        availableSources: []
    )
}

enum MiloSource: String, CaseIterable {
    case librespot
    case bluetooth
    case radio
    case roc
    case podcast

    var displayName: String {
        switch self {
        case .librespot: return "Spotify"
        case .bluetooth: return "Bluetooth"
        case .radio: return "Radio"
        case .roc: return "Mac"
        case .podcast: return "Podcast"
        }
    }

    var iconName: String {
        switch self {
        case .librespot: return "music.note"
        case .bluetooth: return "wave.3.right"
        case .radio: return "radio"
        case .roc: return "laptopcomputer"
        case .podcast: return "mic.fill"
        }
    }
}
