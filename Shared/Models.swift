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

/// Instantané de `GET /api/audio/state`.
///
/// Décodé à la main plutôt qu'en `Codable` : `metadata` est un dictionnaire libre dont
/// les clés dépendent de la source active (voir `MiloNowPlaying`), ce qu'aucun type
/// `Codable` ne sait représenter sans inventer un `AnyCodable`. C'est le même choix que
/// `MiloState` côté Milo-Mac, pour que les deux clients décodent le même payload de la
/// même façon.
///
/// L'ancien modèle de ce fichier lisait `source` / `title` / `artist` à plat : aucun de
/// ces trois champs n'existe côté backend, donc il ne décodait jamais rien.
struct MiloAudioState {
    let activeSource: String
    /// "starting", "ready", "active", "error" — `ready` s'appelait `waiting` avant un
    /// renommage backend, et un Milō pas à jour renvoie encore l'ancien nom.
    let sourceState: String
    /// Vrai pendant un changement de source : l'état affiché est alors en transit.
    let transitioning: Bool
    let multiroomEnabled: Bool
    let equalizerEnabled: Bool
    /// Clés dépendantes de la source — ne jamais y accéder directement, passer par
    /// `MiloNowPlaying(metadata:)`.
    let metadata: [String: Any]

    /// Vrai quand la source est posée : moteur debout et plus rien en vol.
    var isSourceSettled: Bool {
        ["ready", "waiting", "active"].contains(sourceState.lowercased())
    }

    init(json: [String: Any]) {
        activeSource = json["active_source"] as? String ?? "none"
        sourceState = json["source_state"] as? String ?? "active"
        transitioning = json["transitioning"] as? Bool ?? false
        multiroomEnabled = json["multiroom_enabled"] as? Bool ?? false
        equalizerEnabled = json["equalizer_effects_enabled"] as? Bool ?? true
        metadata = json["metadata"] as? [String: Any] ?? [:]
    }
}

/// Ce qui joue, normalisé entre les deux familles de clés que le backend emploie selon
/// la source.
///
/// Radio publie `station_name` / `track_title` / `track_artist` ; les autres sources
/// publient `title` / `artist`. Un morceau de radio est identifié par un `track_title`
/// non vide — jamais par `shazam_enabled` : le titre vient soit de Shazam, soit des
/// métadonnées du flux lui-même, et rien ne distingue les deux à la lecture. Sans
/// morceau reconnu on retombe sur le nom de la station, pour avoir toujours quelque
/// chose à annoncer.
struct MiloNowPlaying {
    let title: String?
    let artist: String?
    let isPlaying: Bool

    init(metadata: [String: Any]) {
        let trackTitle = metadata["track_title"] as? String
        if let trackTitle, !trackTitle.isEmpty {
            title = trackTitle
            artist = metadata["track_artist"] as? String
        } else if let stationName = metadata["station_name"] as? String, !stationName.isEmpty {
            title = stationName
            artist = nil
        } else {
            title = metadata["title"] as? String
            artist = metadata["artist"] as? String
        }
        // Le backend sérialise ce drapeau en entier, pas en booléen.
        isPlaying = metadata["is_playing"] as? Int == 1
    }
}

struct DockAppsResponse: Codable {
    let enabled_apps: [String]
}

struct MiloWidgetData {
    var volumeDB: Double
    var sourceName: String
    var isConnected: Bool
    var canControlVolume: Bool
    var isMuted: Bool
    var availableSources: [String]

    /// Milō est joignable ET le volume est réellement pilotable
    var isReady: Bool { isConnected && canControlVolume }

    static let placeholder = MiloWidgetData(
        volumeDB: -20,
        sourceName: "spotify",
        isConnected: true,
        canControlVolume: true,
        isMuted: false,
        availableSources: ["spotify", "bluetooth", "radio"]
    )

    static let disconnected = MiloWidgetData(
        volumeDB: 0,
        sourceName: "",
        isConnected: false,
        canControlVolume: false,
        isMuted: false,
        availableSources: []
    )
}

/// Les `rawValue` doivent correspondre **exactement** aux identifiants de l'enum
/// `AudioSource` du backend (`backend/core/models/audio_state.py`), qui est la source de
/// vérité — ce catalogue ne décrit que l'affichage. Même liste que
/// `AudioSourceCatalog` côté Milo-Mac.
///
/// Deux identifiants étaient faux ici : `librespot` (le backend dit `spotify`) et `roc`
/// (il dit `mac`). `POST /api/audio/source/{name}` échouait donc sur ces deux-là.
///
/// L'ordre ci-dessous n'est qu'un repli : l'ordre réel d'affichage vient de
/// `dock_apps.enabled_apps` dans `/api/settings/bulk`, qui sert à la fois de filtre et
/// d'ordre. Ne jamais coder l'ordre en dur ailleurs.
enum MiloSource: String, CaseIterable {
    case spotify
    case bluetooth
    case radio
    case podcast
    case airplay
    case mac
    case cd
    case dlna
    case qobuz
    case tidal
    case musicLibrary = "music_library"

    var displayName: String {
        switch self {
        case .spotify:      return "Spotify"
        case .bluetooth:    return "Bluetooth"
        case .radio:        return "Radio"
        case .podcast:      return "Podcast"
        case .airplay:      return "AirPlay"
        case .mac:          return "Mac"
        case .cd:           return "CD"
        case .dlna:         return "DLNA"
        case .qobuz:        return "Qobuz"
        case .tidal:        return "Tidal"
        case .musicLibrary: return "Bibliothèque"
        }
    }

    var iconName: String {
        switch self {
        case .spotify:      return "music.note"
        case .bluetooth:    return "wave.3.right"
        case .radio:        return "radio"
        case .podcast:      return "mic.fill"
        case .airplay:      return "airplay.audio"
        case .mac:          return "laptopcomputer"
        case .cd:           return "opticaldisc"
        case .dlna:         return "network"
        case .qobuz:        return "music.note.list"
        case .tidal:        return "waveform"
        case .musicLibrary: return "music.note.house"
        }
    }
}
