import Testing
import Foundation
@testable import Milo_iOS

// Twinned with Milo-Mac/Milo MacTests/MiloAudioStateTests.swift: the same cases, line for line,
// except the `@testable import`. They pin the one decoder both apps share
// (`MiloAudioState.swift`) to the payloads of the spec's §10, « Un exemple par source et par
// phase ». `…` elisions there are filled with plausible values here; the common fields the
// spec omits are merged in by `state(_:)`.

/// Decodes a §10 example, completed with the fields the spec lists as omitted.
private func state(_ partial: String) throws -> MiloAudioState {
    let common: [String: Any] = [
        "switching": false, "service": "running", "service_error": NSNull(),
        "availability": [String: Any](), "multiroom_enabled": false,
        "equalizer_effects_enabled": true,
    ]
    let object = try #require(try JSONSerialization.jsonObject(with: Data(partial.utf8)) as? [String: Any])
    let merged = common.merging(object) { _, new in new }
    return try MiloAudioState.decode(try JSONSerialization.data(withJSONObject: merged))
}

struct MiloAudioStateDecodingTests {

    @Test("The §1 example decodes whole")
    func theReferenceExampleDecodes() throws {
        let decoded = try MiloAudioState.decode(Data("""
        {"source":"podcast","switching":false,"service":"running","service_error":null,
         "availability":{"radio":null,"podcast":null,"music_library":"no_storage","cd":"no_disc",
           "spotify":null,"tidal":null,"qobuz":"no_account","airplay":null,"bluetooth":null,"mac":null},
         "session":{"id":"9f0c2a7e41b84d6f8a1e3b5c7d9e0f12","phase":"paused",
           "title":"Épisode 12","artist":"Le Code a changé","album":"Le Code a changé",
           "artwork":"https://cdn.example/ep12.jpg","senders":[],"duration_ms":2400000,
           "position":{"ms":192000,"at":1790270000.25,"rate":1.5}},
         "controls":["resume","seek","set_speed"],"resume":null,
         "details":{"kind":"podcast","episode":{"uuid":"e1","name":"Épisode 12"},"speed":1.5},
         "multiroom_enabled":false,"equalizer_effects_enabled":true}
        """.utf8))

        #expect(decoded.source == "podcast")
        #expect(decoded.service == .running)
        #expect(decoded.serviceError == nil)
        #expect(decoded.session?.phase == .paused)
        #expect(decoded.session?.durationMs == 2_400_000)
        #expect(decoded.session?.position == .init(ms: 192_000, at: 1_790_270_000.25, rate: 1.5))
        #expect(decoded.controls == ["resume", "seek", "set_speed"])
        #expect(decoded.details == .other(kind: "podcast"))
        #expect(decoded.equalizerEffectsEnabled)
    }

    @Test("Radio: loading, recognized song, and the resume point after a stop")
    func radio() throws {
        let station = """
        {"id":"96062a7a-0001","name":"FIP","url":"https://x/fip.mp3","country":"France","genre":"jazz",
         "favicon":"https://x/fip.png","bitrate":128,"codec":"MP3"}
        """
        let loading = try state("""
        {"source":"radio","session":{"id":"a1","phase":"loading","title":"FIP","artist":null,"album":"FIP",
         "artwork":"/api/radio/favicon?url=x","senders":[],"duration_ms":null,"position":null},
         "controls":["stop","next","prev"],"resume":null,
         "details":{"kind":"radio","station":\(station),"track":null}}
        """)
        #expect(loading.session?.phase == .loading)
        #expect(loading.session?.position == nil)
        #expect(loading.details == .radio(station: .init(id: "96062a7a-0001", name: "FIP",
                                                         favicon: "https://x/fip.png"), track: nil))

        let recognized = try state("""
        {"source":"radio","session":{"id":"a1","phase":"playing","title":"So What","artist":"Miles Davis",
         "album":"FIP","artwork":"https://x/kind-of-blue.jpg","senders":[],"duration_ms":null,"position":null},
         "controls":["stop","next","prev"],"resume":null,
         "details":{"kind":"radio","station":\(station),
           "track":{"title":"So What","artist":"Miles Davis","artwork":"https://x/kind-of-blue.jpg"}}}
        """)
        guard case .radio(_, let track) = recognized.details else {
            Issue.record("radio details expected"); return
        }
        #expect(track?.artwork == "https://x/kind-of-blue.jpg")

        let stopped = try state("""
        {"source":"radio","session":null,"controls":["resume_playback","next","prev"],
         "resume":{"title":"FIP","artist":null,"album":"FIP","artwork":"/api/radio/favicon?url=x",
           "duration_ms":null,"position_ms":null},
         "details":{"kind":"radio","station":\(station),"track":null}}
        """)
        #expect(stopped.session == nil)
        #expect(stopped.resume?.positionMs == nil)
        #expect(stopped.shown?.title == "FIP")
        #expect(stopped.shown?.isSession == false)
    }

    @Test("Music Library: the current track id comes out of details")
    func musicLibrary() throws {
        let playing = try state("""
        {"source":"music_library","session":{"id":"c3","phase":"playing","title":"Teardrop",
         "artist":"Massive Attack","album":"Mezzanine","artwork":"/api/music-library/cover/al-42",
         "senders":[],"duration_ms":330000,"position":{"ms":81000,"at":1790270000.25,"rate":1.0}},
         "controls":["pause","seek","next","prev","set_shuffle","play_index","stop"],"resume":null,
         "details":{"kind":"music_library","queue":[{"id":"tr-1","title":"Angel"}],"queue_index":2,
           "shuffle":false,"track_id":"tr-3","album_id":"al-42","artist_id":"ar-7"}}
        """)
        #expect(playing.details == .musicLibrary(trackId: "tr-3"))
        #expect(playing.controls.contains("pause"))
    }

    @Test("CD: an unreadable disc has no session, no resume, and only eject")
    func unreadableDisc() throws {
        let decoded = try state("""
        {"source":"cd","availability":{"cd":"unreadable_disc"},"session":null,"controls":["eject"],
         "resume":null,"details":{"kind":"cd","disc":null,"current_track":null,"artwork_pending":false}}
        """)
        #expect(decoded.shown == nil)
        #expect(decoded.controls == ["eject"])
        #expect(decoded.details == .other(kind: "cd"))
    }

    @Test("A source change and a failed start carry no session and no controls")
    func switchingAndFailure() throws {
        let switching = try state("""
        {"source":"spotify","switching":true,"service":"starting","service_error":null,"session":null,
         "controls":[],"resume":null,"details":null}
        """)
        #expect(switching.switching)
        #expect(switching.service == .starting)

        let failed = try state("""
        {"source":"qobuz","switching":false,"service":"failed",
         "service_error":{"reason":"start_timeout","message":"Transition timeout after 15s"},
         "session":null,"controls":[],"resume":null,"details":null}
        """)
        #expect(failed.service == .failed)
        #expect(failed.serviceError?.reason == "start_timeout")
    }

    @Test("Connected sessions: senders are names, and there is no title to show")
    func connected() throws {
        let airplay = try state("""
        {"source":"airplay","session":{"id":"18","phase":"connected","title":null,"artist":null,"album":null,
         "artwork":null,"senders":["Mac mini de Léo"],"duration_ms":null,"position":null},
         "controls":[],"resume":null,"details":{"kind":"airplay","artwork_width":null}}
        """)
        #expect(airplay.session?.phase == .connected)
        #expect(airplay.session?.senders == ["Mac mini de Léo"])
        #expect(airplay.shown == nil)

        let mac = try state("""
        {"source":"mac","session":{"id":"6d","phase":"connected","title":null,"artist":null,"album":null,
         "artwork":null,"senders":["mac-mini-de-leo2","MacBook Air"],"duration_ms":null,"position":null},
         "controls":[],"resume":null,"details":null}
        """)
        #expect(mac.session?.senders.count == 2)
    }

    @Test("service and phase are frozen: an unknown value fails the whole decode")
    func frozenEnumsAreStrict() {
        #expect(throws: (any Error).self) {
            try state("""
            {"source":"spotify","service":"rebooting","session":null,"controls":[],"resume":null,"details":null}
            """)
        }
        #expect(throws: (any Error).self) {
            try state("""
            {"source":"spotify","session":{"id":"e5","phase":"buffering","title":"x","artist":null,
             "album":null,"artwork":null,"senders":[],"duration_ms":null,"position":null},
             "controls":[],"resume":null,"details":null}
            """)
        }
    }

    @Test("A missing field is a broken contract, not a default")
    func missingFieldFails() {
        #expect(throws: (any Error).self) {
            try state("""
            {"source":"spotify","session":null,"resume":null,"details":null}
            """)
        }
    }

    @Test("details is lenient: an unknown or malformed shape costs details, never the state")
    func detailsIsLenient() throws {
        let unknown = try state("""
        {"source":"spotify","session":null,"controls":[],"resume":null,"details":{"kind":"hologram"}}
        """)
        #expect(unknown.details == .other(kind: "hologram"))

        let malformed = try state("""
        {"source":"radio","session":null,"controls":[],"resume":null,"details":{"kind":"radio","station":null}}
        """)
        #expect(malformed.details == nil)
        #expect(malformed.source == "radio")
    }
}

struct MiloAudioStateDisplayTests {

    private func session(title: String?) -> String {
        let title = title.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"e5","phase":"paused","title":\(title),"artist":"Björk","album":"Post","artwork":null,
         "senders":[],"duration_ms":321000,"position":null}
        """
    }

    private let resume = """
    {"title":"Teardrop","artist":"Massive Attack","album":"Mezzanine","artwork":null,
     "duration_ms":330000,"position_ms":81000}
    """

    @Test("A titled session is what is shown")
    func sessionWins() throws {
        let decoded = try state("""
        {"source":"spotify","session":\(session(title: "Hyperballad")),"controls":[],"resume":null,"details":null}
        """)
        #expect(decoded.shown?.title == "Hyperballad")
        #expect(decoded.shown?.isSession == true)
    }

    @Test("With no session, the resume point is shown")
    func resumeFallsBack() throws {
        let decoded = try state("""
        {"source":"music_library","session":null,"controls":[],"resume":\(resume),"details":null}
        """)
        #expect(decoded.shown?.title == "Teardrop")
        #expect(decoded.shown?.isSession == false)
    }

    @Test("An empty title names nothing")
    func emptyTitleNamesNothing() throws {
        let decoded = try state("""
        {"source":"spotify","session":\(session(title: "")),"controls":[],"resume":null,"details":null}
        """)
        #expect(decoded.shown == nil)
    }

    @Test("Nothing titled, nothing shown")
    func nothingShown() throws {
        let decoded = try state("""
        {"source":"spotify","session":\(session(title: nil)),"controls":[],"resume":null,"details":null}
        """)
        #expect(decoded.shown == nil)
    }
}

struct PositionAnchorTests {

    private let anchor = MiloAudioState.PositionAnchor(ms: 192_000, at: 1_000, rate: 1.5)

    @Test("Playing: advances by rate × elapsed")
    func playingAdvances() {
        let now = Date(timeIntervalSince1970: 1_010)
        #expect(anchor.positionMs(at: now, phase: .playing, durationMs: 2_400_000) == 207_000)
    }

    @Test("Any other phase: the anchor holds")
    func otherPhasesHold() {
        let now = Date(timeIntervalSince1970: 1_010)
        for phase in [MiloAudioState.Phase.loading, .paused, .connected] {
            #expect(anchor.positionMs(at: now, phase: phase, durationMs: 2_400_000) == 192_000)
        }
    }

    @Test("Clamped to [0, duration_ms]")
    func clamped() {
        let late = Date(timeIntervalSince1970: 1_000_000)
        #expect(anchor.positionMs(at: late, phase: .playing, durationMs: 200_000) == 200_000)

        let early = Date(timeIntervalSince1970: 0)
        #expect(anchor.positionMs(at: early, phase: .playing, durationMs: nil) == 0)
    }
}
