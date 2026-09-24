import Foundation

/// Milō's audio state, as `GET /api/audio/state` and the `source/state` event carry it.
///
/// **This file exists twice, byte for byte**: `Milo-Mac/Milo Mac/MiloAudioState.swift` and
/// `Milo-iOS/Shared/MiloAudioState.swift`. Both apps decode the wire through it, so they
/// cannot read the same state two ways. Change one, copy it to the other; from the folder
/// holding both repos, this must print nothing:
///
///     diff "Milo-Mac/Milo Mac/MiloAudioState.swift" Milo-iOS/Shared/MiloAudioState.swift
///
/// The contract is the frozen section « Développeurs : le fil » of the Milō audio-states
/// document (24/09/2026, phase 5.0, against `b76fc715`). It is the authority, not this file:
/// a payload that looks wrong is checked there before "fixing" the decoder.
///
/// What the wire guarantees, and what the decoder relies on:
///
/// - Every field is always present; an absent value is `null`, never a missing key.
/// - Durations and positions are integer milliseconds; instants are float seconds since
///   the epoch, UTC.
/// - An empty string is never published: it becomes `null`.
///
/// `service` and `phase` are **frozen**: an unknown value fails the whole decode, on
/// purpose (the spec forbids a permissive fallback on either). `details` is not frozen and
/// is decoded leniently — a shape the apps do not know makes it `nil`, never the state.
/// `availability` is not decoded: neither app reads it.
struct MiloAudioState: Decodable, Sendable, Equatable {

    /// The chosen source (`AudioSource` on the backend), `"none"` when there is none. A bare
    /// string: the ids must match the backend enum byte for byte, and an app must not stop
    /// decoding because the backend gained a source.
    let source: String

    /// True from the start to the end of a source change, and of a whole multiroom switch
    /// (until `set_multiroom_enabled` returns, volume sync included). The end of a multiroom
    /// switch is the first state where this is false again.
    let switching: Bool

    let service: ServiceState

    /// Non-nil if and only if `service == .failed`.
    let serviceError: ServiceError?

    /// The listening in progress on the chosen source, if any.
    let session: Session?

    /// The commands `POST /api/audio/control/{source}` accepts right now, by their exact
    /// command names (`resume`, not `play`). Empty when there is no source, while
    /// `switching`, and whenever `service != .running`.
    let controls: [String]

    /// What "play" would restart. Non-nil only when `session == nil`.
    let resume: ResumePoint?

    /// The chosen source's own content, for the few kinds the apps read.
    let details: Details?

    let multiroomEnabled: Bool
    let equalizerEffectsEnabled: Bool

    enum ServiceState: String, Decodable, Sendable {
        /// `source == "none"`.
        case stopped
        /// A start or a switch is under way.
        case starting
        case running
        /// The last start failed, until the next one succeeds.
        case failed
    }

    enum Phase: String, Decodable, Sendable {
        case loading
        case playing
        case paused
        /// A sender is there, but Milō cannot tell playing from paused (AirPlay realtime,
        /// Bluetooth without an AVRCP player, the Mac source).
        case connected
    }

    struct ServiceError: Decodable, Sendable, Equatable {
        /// `start_timeout` or `start_failed`.
        let reason: String
        /// For logs only, never displayed as is.
        let message: String
    }

    struct Session: Decodable, Sendable, Equatable {
        /// 32 hex characters. A new listening has a new id.
        let id: String
        let phase: Phase
        let title: String?
        let artist: String?
        let album: String?
        /// An absolute URL or a path on Milō (`/api/...`).
        let artwork: String?
        /// Displayable names of who is sending: AirPlay's client, the Bluetooth device, the
        /// Macs. Empty everywhere else.
        let senders: [String]
        /// `nil` when unknown: radio, a track without duration, AirPlay before its first
        /// progress report.
        let durationMs: Int?
        /// `nil` when there is no position at all (radio, Mac, Bluetooth without a player).
        let position: PositionAnchor?

        enum CodingKeys: String, CodingKey {
            case id, phase, title, artist, album, artwork, senders, position
            case durationMs = "duration_ms"
        }
    }

    /// The position as an anchor: `ms` at the instant `at`, moving at `rate` while playing.
    ///
    /// Milō republishes it only on a discontinuity (seek, speed change, drift over 2 s), so
    /// a client interpolates between anchors instead of polling a playhead.
    struct PositionAnchor: Decodable, Sendable, Equatable {
        let ms: Int
        /// Seconds since the epoch, UTC.
        let at: Double
        /// The podcast speed; 1.0 everywhere else.
        let rate: Double

        /// The spec's single interpolation formula, shared by every client:
        /// `ms + (phase == playing ? (now − at) × 1000 × rate : 0)`, clamped to
        /// `[0, duration_ms]`.
        func positionMs(at now: Date, phase: Phase, durationMs: Int?) -> Int {
            let advance = phase == .playing ? (now.timeIntervalSince1970 - at) * 1000 * rate : 0
            var value = max(Double(ms) + advance, 0)
            if let durationMs { value = min(value, Double(durationMs)) }
            return Int(value)
        }
    }

    /// Same field rules as a session. Only radio, podcast, music library and CD keep one.
    struct ResumePoint: Decodable, Sendable, Equatable {
        let title: String?
        let artist: String?
        let album: String?
        let artwork: String?
        let durationMs: Int?
        /// `nil` for radio.
        let positionMs: Int?

        enum CodingKeys: String, CodingKey {
            case title, artist, album, artwork
            case durationMs = "duration_ms"
            case positionMs = "position_ms"
        }
    }

    /// The part of `details` the apps read. Every other kind decodes to `.other`.
    enum Details: Decodable, Sendable, Equatable {
        case radio(station: Station, track: RadioTrack?)
        /// The current track's Subsonic id.
        case musicLibrary(trackId: String?)
        case other(kind: String)

        struct Station: Decodable, Sendable, Equatable {
            let id: String
            let name: String?
            /// The station's logo, as the station catalogue serves it (not proxied).
            let favicon: String?
        }

        /// The song recognized in the stream or by Shazam.
        struct RadioTrack: Decodable, Sendable, Equatable {
            let title: String?
            let artist: String?
            let artwork: String?
        }

        private enum CodingKeys: String, CodingKey {
            case kind, station, track
            case trackId = "track_id"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "radio":
                self = .radio(station: try container.decode(Station.self, forKey: .station),
                              track: try container.decodeIfPresent(RadioTrack.self, forKey: .track))
            case "music_library":
                self = .musicLibrary(trackId: try container.decodeIfPresent(String.self, forKey: .trackId))
            default:
                self = .other(kind: kind)
            }
        }
    }

    /// What a card or a now-playing row shows: the session when it has a title, otherwise
    /// the resume point when it has one, otherwise nothing.
    ///
    /// This is the display rule of both apps (§9: a card exists if `session` or `resume`
    /// carries a `title`), written once so the lock screen and the menu bar cannot
    /// disagree about whether there is something to show.
    struct Shown: Sendable, Equatable {
        let title: String
        let artist: String?
        let album: String?
        let artwork: String?
        let durationMs: Int?
        /// True when this comes from `session`, false when from `resume`.
        let isSession: Bool
    }

    var shown: Shown? {
        if let session, let title = Self.nonEmpty(session.title) {
            return Shown(title: title, artist: Self.nonEmpty(session.artist),
                         album: Self.nonEmpty(session.album), artwork: Self.nonEmpty(session.artwork),
                         durationMs: session.durationMs, isSession: true)
        }
        if let resume, let title = Self.nonEmpty(resume.title) {
            return Shown(title: title, artist: Self.nonEmpty(resume.artist),
                         album: Self.nonEmpty(resume.album), artwork: Self.nonEmpty(resume.artwork),
                         durationMs: resume.durationMs, isSession: false)
        }
        return nil
    }

    /// Milō never publishes an empty string, but reading one as absent costs nothing and
    /// keeps a stray `""` from naming an empty card.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func decode(_ data: Data) throws -> MiloAudioState {
        try JSONDecoder().decode(MiloAudioState.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case source, switching, service, session, controls, resume, details
        case serviceError = "service_error"
        case multiroomEnabled = "multiroom_enabled"
        case equalizerEffectsEnabled = "equalizer_effects_enabled"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        switching = try container.decode(Bool.self, forKey: .switching)
        service = try container.decode(ServiceState.self, forKey: .service)
        serviceError = try container.decodeIfPresent(ServiceError.self, forKey: .serviceError)
        session = try container.decodeIfPresent(Session.self, forKey: .session)
        controls = try container.decode([String].self, forKey: .controls)
        resume = try container.decodeIfPresent(ResumePoint.self, forKey: .resume)
        // Lenient on purpose: `details` is not frozen, and an unknown shape there must cost
        // the apps a highlight or a badge, never the whole state.
        details = try? container.decodeIfPresent(Details.self, forKey: .details)
        multiroomEnabled = try container.decode(Bool.self, forKey: .multiroomEnabled)
        equalizerEffectsEnabled = try container.decode(Bool.self, forKey: .equalizerEffectsEnabled)
    }
}
