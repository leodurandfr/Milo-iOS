import Testing
import Foundation
@testable import Milo_iOS

/// Le niveau **rendu** au système, et ce qui arrive quand il vaut zéro.
///
/// Le curseur maître de la carte Now Playing n'a pas d'API à lui : iOS le
/// synthétise en multipliant les niveaux qu'on lui rend par un facteur commun —
/// mesuré le 22/09/2026 sur trois enceintes, une rafale à ×1,57 puis ×1,36 puis
/// ×1,27. Un zéro rendu est donc absorbant, et ces tests figent le plancher qui
/// l'empêche.
struct RenderedLevelTests {

    @Test("Zéro rendu rendrait le curseur maître inerte, donc on ne rend pas zéro")
    func zeroIsNeverRendered() {
        #expect(MiloAPIClient.renderedLevel(0) == MiloAPIClient.renderedFloor)
        #expect(MiloAPIClient.renderedLevel(-1) == MiloAPIClient.renderedFloor)

        // La démonstration de pourquoi : le système multiplie, et zéro absorbe
        // tout facteur. Sans plancher, aucune poignée ne remonte le son.
        #expect(MiloAPIClient.renderedLevel(0) * 2 > 0)
    }

    @Test("Le plancher reste inaudible")
    func theFloorIsInaudible() {
        // Sur les bornes de l'appareil (-78…-8 dB), 1 % de la course vaut
        // 0,7 dB au-dessus du plancher du limiteur.
        #expect(MiloAPIClient.renderedFloor * 70 < 1.0)
    }

    @Test("Ailleurs, le niveau passe tel quel")
    func everythingElsePassesThrough() {
        #expect(MiloAPIClient.renderedLevel(0.5) == 0.5)
        #expect(MiloAPIClient.renderedLevel(1) == 1)
        #expect(MiloAPIClient.renderedLevel(2) == 1)
    }
}

/// Ce qu'on confirme au système après qu'il a demandé un niveau.
///
/// Mesuré le 26/09/2026 : une valeur égale à celle que le système vient de
/// demander ne remonte pas jusqu'au curseur de la carte, qui restait figé sous
/// les boutons physiques — et, figé en haut, ramenait toute sa course à
/// -78…-72 dB. Ces tests figent l'écart qui en fait une nouvelle valeur.
struct DisplayedLevelTests {

    /// Les niveaux du relevé : plancher, plafond à -72 dB, avant les appuis,
    /// butée haute.
    let requested: [Float] = [0.01, 0.0855, 0.5398643, 1.0]

    @Test("Une valeur fraîche ne revient jamais bit à bit au système")
    func aFreshLevelIsNeverEchoedVerbatim() {
        for level in requested {
            let shown = Float(MiloAPIClient.displayedLevel(
                optimistic: Double(level), reported: 0.3))
            #expect(shown != level, "rendu \(shown) pour \(level) demandé")
        }
    }

    @Test("L'écart reste imperceptible et dans la course")
    func theOffsetStaysSmallAndInRange() {
        for level in requested {
            let shown = MiloAPIClient.displayedLevel(
                optimistic: Double(level), reported: 0.3)
            #expect(abs(shown - Double(level)) <= MiloAPIClient.acknowledgedOffset + 1e-9)
            #expect(shown >= MiloAPIClient.renderedFloor)
            #expect(shown <= 1)
        }
    }

    @Test("L'écart ne réordonne pas deux enceintes")
    func theOffsetKeepsTheOrder() {
        // Une première version basculait à 0,5 : 0,4999 passait devant 0,5001.
        let below = MiloAPIClient.displayedLevel(optimistic: 0.4999, reported: 0.3)
        let above = MiloAPIClient.displayedLevel(optimistic: 0.5001, reported: 0.3)
        #expect(below < above)
    }

    @Test("La base d'un geste ne porte pas l'écart")
    func theGestureBaseCarriesNoOffset() {
        // Parti du niveau affiché, la valeur optimiste rangerait l'écart dans la valeur
        // optimiste, et le rendu suivant l'ajouterait une seconde fois.
        for level in requested {
            #expect(MiloAPIClient.baseLevel(optimistic: Double(level), reported: 0.3)
                    == MiloAPIClient.renderedLevel(Double(level)))
        }
        #expect(MiloAPIClient.baseLevel(optimistic: nil, reported: 0)
                == MiloAPIClient.renderedFloor)
    }

    @Test("Sans valeur fraîche, ce que Milō rapporte passe tel quel")
    func withoutAFreshLevelMiloIsShownAsIs() {
        #expect(MiloAPIClient.displayedLevel(optimistic: nil, reported: 0.5398643) == 0.5398643)
        #expect(MiloAPIClient.displayedLevel(optimistic: nil, reported: 0)
                == MiloAPIClient.renderedFloor)
    }
}

/// Le niveau optimiste, celui que l'affichage préfère pendant trois secondes.
///
/// Il est rangé sur l'échelle du curseur. La version précédente y rangeait des
/// décibels sous une autre clé, et c'est le seul point de la mise à jour qui
/// pouvait se voir : un -47,8 relu comme un niveau se borne à 0, soit du
/// silence affiché.
/// Une MAC par test, et non une pour la suite : ces tests écrivent tous dans le
/// **même** conteneur partagé que l'app, et Swift Testing les lance en
/// parallèle. Une clé commune faisait effacer par le nettoyage de l'un la
/// valeur que l'autre venait de poser — un échec qui ne dépendait que de
/// l'ordonnancement.
struct OptimisticLevelTests {

    /// Efface tout ce qu'un test a pu laisser sous cette MAC, ancienne clé
    /// comprise.
    private func forget(_ mac: String) {
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)
        defaults?.removeObject(forKey: MiloAPIClient.optimisticLevelKey(mac))
        defaults?.removeObject(forKey: MiloAPIClient.optimisticVolumeAtKey(mac))
        defaults?.removeObject(forKey: "milo_opt_vol_\(mac)")
    }

    @Test("Une écriture qui n'aboutit pas rend la main à Milō tout de suite")
    func aFailedWriteHandsTheDisplayBack() {
        // Sans cette remise à zéro, l'affichage tenait trois secondes pleines
        // un niveau que Milō n'avait jamais appliqué.
        let mac = "aabbccdd0005"
        forget(mac)
        defer { forget(mac) }

        MiloAPIClient.noteOptimistic(mac: mac, level: 0.9)
        #expect(MiloAPIClient.optimisticLevel(mac: mac) == 0.9)

        MiloAPIClient.forgetOptimistic(macs: [mac])
        #expect(MiloAPIClient.optimisticLevel(mac: mac) == nil)
    }

    /// 29/10, 15:11:52.103 : un push arrivé 2,2 s après notre cran fermait la
    /// fenêtre en effaçant aussi le niveau demandé, et le rendu perdait son
    /// écart hors commande (0,321 → 0,3205). La fenêtre se ferme, l'écart reste.
    @Test("Un push tardif ferme la fenêtre sans faire perdre l'écart de confirmation")
    func aLatePushKeepsTheConfirmationOffset() {
        let mac = "aabbccdd0007"
        forget(mac)
        defer { forget(mac) }

        MiloAPIClient.noteOptimistic(mac: mac, level: 0.3205)
        MiloAPIClient.expireOptimistic(macs: [mac])

        #expect(MiloAPIClient.optimisticLevel(mac: mac) == nil)
        #expect(MiloAPIClient.optimisticAt(mac: mac) == nil)
        let confirmed = MiloAPIClient.lastRequestedLevel(mac: mac)
        #expect(confirmed == 0.3205)
        let shown = MiloAPIClient.displayedLevel(optimistic: nil, reported: 0.3205,
                                                 confirmed: confirmed)
        #expect(abs(shown - 0.321) < 0.000_001)
    }

    @Test("L'oubli accepte une MAC à deux-points comme l'écriture")
    func forgettingAcceptsAColonedMac() {
        // `forgetOptimistic` est appelé avec les clés de l'instantané, qui
        // portent les deux-points ; `noteOptimistic` reçoit des MAC déjà
        // nettoyées. Les deux doivent viser la même clé.
        let plain = "aabbccdd0006"
        forget(plain)
        defer { forget(plain) }

        MiloAPIClient.noteOptimistic(mac: plain, level: 0.7)
        MiloAPIClient.forgetOptimistic(macs: ["aa:bb:cc:dd:00:06"])
        #expect(MiloAPIClient.optimisticLevel(mac: plain) == nil)
    }

    @Test("Ce qui est posé est ce que le curseur montre, sans conversion")
    func theOptimisticLevelIsAlreadyWhatTheSliderShows() throws {
        let mac = "aabbccdd0001"
        forget(mac)
        defer { forget(mac) }

        MiloAPIClient.noteOptimistic(mac: mac, level: 0.72)

        let level = try #require(MiloAPIClient.optimisticLevel(mac: mac))
        #expect(level == 0.72)
    }

    @Test("Un décibel laissé par la version précédente n'est pas lu comme un niveau")
    func aStaleDecibelValueCannotBeReadAsALevel() {
        let mac = "aabbccdd0002"
        forget(mac)
        defer { forget(mac) }

        // Exactement ce que la version précédente laissait derrière elle : une
        // valeur en dB sous l'ancienne clé, et une estampille fraîche.
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)
        defaults?.set(-47.8, forKey: "milo_opt_vol_\(mac)")
        defaults?.set(Date().timeIntervalSince1970,
                      forKey: MiloAPIClient.optimisticVolumeAtKey(mac))

        #expect(MiloAPIClient.optimisticLevel(mac: mac) == nil)
    }

    @Test("Passé la fenêtre, c'est Milō qui reprend la main")
    func aStaleLevelIsIgnored() {
        let mac = "aabbccdd0003"
        forget(mac)
        defer { forget(mac) }

        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)
        defaults?.set(0.72, forKey: MiloAPIClient.optimisticLevelKey(mac))
        defaults?.set(Date().timeIntervalSince1970 - MiloAPIClient.optimisticVolumeWindow - 1,
                      forKey: MiloAPIClient.optimisticVolumeAtKey(mac))

        #expect(MiloAPIClient.optimisticLevel(mac: mac) == nil)
    }
}

/// Le choix de l'adresse de Milō parmi les réponses concurrentes de `milo.local`.
///
/// Sur ce réseau le nom en a deux : celle du mDNS, juste, et celle qu'une route
/// Split DNS fait servir par le NAS, périmée. `getaddrinfo` rend les deux et
/// l'ordre n'est pas le nôtre — prendre la première et l'épingler cinq minutes
/// mettait l'app en panne totale un tirage sur deux.
struct AddressSelectionTests {

    @Test("Le premier candidat qui répond est retenu")
    func firstResponderWins() async {
        let picked = await MiloAPIClient.firstReachable(among: ["192.168.1.39", "192.168.1.55"]) {
            $0 == "192.168.1.39"
        }

        #expect(picked == "192.168.1.39")
    }

    @Test("Un premier candidat muet ne condamne pas les suivants")
    func deadFirstCandidateIsSkipped() async {
        let picked = await MiloAPIClient.firstReachable(among: ["192.168.1.55", "192.168.1.39"]) {
            $0 == "192.168.1.39"
        }

        #expect(picked == "192.168.1.39")
    }

    @Test("On s'arrête au premier qui répond, sans sonder le reste")
    func probingStopsAtTheFirstHit() async {
        let probed = Probed()

        _ = await MiloAPIClient.firstReachable(among: ["a", "b", "c"]) {
            await probed.record($0)
            return $0 == "a"
        }

        #expect(await probed.all == ["a"])
    }

    @Test("Aucun candidat ne répond : rien à retenir")
    func nothingReachableYieldsNil() async {
        let picked = await MiloAPIClient.firstReachable(among: ["192.168.1.55"]) { _ in false }

        #expect(picked == nil)
    }

    @Test("Sans candidat, rien à choisir")
    func emptyYieldsNil() async {
        let picked = await MiloAPIClient.firstReachable(among: []) { _ in true }

        #expect(picked == nil)
    }

    /// Ce que la sonde a vu passer, dans l'ordre.
    private actor Probed {
        private(set) var all: [String] = []
        func record(_ candidate: String) { all.append(candidate) }
    }
}

/// Quels logos de station méritent d'être déposés d'avance pour l'extension.
///
/// Ce qu'on répare : on change de station depuis la carte de l'écran verrouillé,
/// l'app dort, et le nouveau logo n'est dans aucun cache. Déposer les favoris
/// pendant que l'app est devant évite à l'extension de jouer son tirage `milo.local`.
///
/// Le tri « favori » n'est **pas** testé ici : il appartient à la route
/// `?favorites_only=true`. Se fier au drapeau `is_favorite` de la liste nue a
/// coûté dix-sept favoris sur vingt-deux, et c'est exactement ce que ces tests
/// ne doivent pas réinstaller.
struct StationPrimingTests {

    func station(_ name: String, favicon: Any?) -> [String: Any] {
        var s: [String: Any] = ["name": name]
        if let favicon { s["favicon"] = favicon }
        return s
    }

    @Test("Un logo hébergé par Milō est déposé")
    func hostedFaviconIsPrimed() {
        let stations = [station("FIP", favicon: "/api/radio/images/d77a8b35a9a3.webp")]

        #expect(MiloAPIClient.stationArtworkToPrime(in: stations)
                == ["/api/radio/images/d77a8b35a9a3.webp"])
    }

    @Test("Un logo servi par Internet n'a rien à gagner au préchargement")
    func remoteFaviconIsSkipped() {
        // L'extension atteint `duckduckgo.com` sans toucher au LAN : rien à
        // tirer au sort, donc rien à déposer d'avance.
        let stations = [station("RTL", favicon: "https://duckduckgo.com/i/035a5e15.png")]

        #expect(MiloAPIClient.stationArtworkToPrime(in: stations).isEmpty)
    }

    @Test("Une station sans logo ne fait pas trébucher la liste")
    func missingFaviconIsIgnored() {
        let stations = [
            station("Sans logo", favicon: nil),
            station("FIP", favicon: "/api/radio/images/d77a8b35a9a3.webp"),
        ]

        #expect(MiloAPIClient.stationArtworkToPrime(in: stations)
                == ["/api/radio/images/d77a8b35a9a3.webp"])
    }

    @Test("Deux stations qui partagent un logo ne le déposent qu'une fois")
    func duplicatesAreCollapsed() {
        let shared = "/api/radio/images/3dffdd56c66f.webp"
        let stations = [station("A", favicon: shared), station("B", favicon: shared)]

        #expect(MiloAPIClient.stationArtworkToPrime(in: stations) == [shared])
    }

    @Test("Une route mal restreinte ne fait pas télécharger tout le catalogue")
    func theCatalogueIsCapped() {
        // Vingt-deux favoris mesurés, trois cents stations au catalogue. Le
        // plafond est là pour que la différence ne se paie jamais.
        let stations = (0..<300).map { station("S\($0)", favicon: "/api/radio/images/\($0).webp") }

        #expect(MiloAPIClient.stationArtworkToPrime(in: stations).count == 40)
    }
}

/// Ce que montre la carte de l'écran verrouillé quand rien ne porte de titre.
///
/// L'app ne ferme plus la carte — elle le faisait pour tout état sans titre,
/// pendant que le push de Milō en gardait une, d'où un Mac qui perdait son
/// icône dès que l'app était ouverte. Tout état se dessine : ce qu'il nomme,
/// sinon sa source, sinon Milō ; et seul Milō ferme — aussitôt sur `none`.
///
/// Les payloads sont ceux du §10 du fil, complétés des champs qu'il omet.
/// Toutes les clés sont présentes, une valeur absente vaut `null`.
struct NowPlayingSourceCardTests {

    private func state(_ partial: String) throws -> MiloAudioState {
        let common: [String: Any] = [
            "switching": false, "service": "running", "service_error": NSNull(),
            "availability": [String: Any](), "controls": [String](),
            "session": NSNull(), "resume": NSNull(), "details": NSNull(),
            "multiroom_enabled": false, "equalizer_effects_enabled": true,
        ]
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(partial.utf8)) as? [String: Any])
        let merged = common.merging(object) { _, new in new }
        return try MiloAudioState.decode(try JSONSerialization.data(withJSONObject: merged))
    }

    private func card(_ partial: String) throws -> MiloSourceCard.Card {
        MiloSourceCard.card(for: try state(partial))
    }

    private func controls(_ partial: String) throws -> [String] {
        MiloSourceCard.lockScreenControls(for: try state(partial))
    }

    @Test("Un Mac nomme la source et qui émet, sous l'icône macOS")
    func aMacNamesItsSenders() throws {
        // Mesuré le 25/09/2026 : c'est l'état que publie un Mac qui diffuse.
        #expect(try card("""
        {"source":"mac",
         "session":{"id":"18de","phase":"connected","title":null,"artist":null,"album":null,
           "artwork":null,"senders":["Mac mini de Léo"],"duration_ms":null,"position":null}}
        """) == MiloSourceCard.Card(title: "Récepteur macOS", artist: "Mac mini de Léo",
                                    artwork: "/now-playing/macos.jpg"))
    }

    @Test("Un Bluetooth sans lecteur nomme l'appareil connecté")
    func anUntitledReceiverNamesItsSender() throws {
        #expect(try card("""
        {"source":"bluetooth","controls":["disconnect"],
         "session":{"id":"4b","phase":"connected","title":null,"artist":null,"album":null,
           "artwork":null,"senders":["Pixel 7"],"duration_ms":null,"position":null}}
        """) == MiloSourceCard.Card(title: "Bluetooth", artist: "Pixel 7",
                                    artwork: "/now-playing/bluetooth.jpg"))
    }

    @Test("Une source au repos montre son nom, sans émetteur")
    func anIdleSourceShowsItsName() throws {
        #expect(try card("""
        {"source":"spotify"}
        """) == MiloSourceCard.Card(title: "Spotify", artist: nil,
                                    artwork: "/now-playing/spotify.jpg"))
    }

    @Test("Aucune source montre la carte de Milō")
    func noSourceShowsMilo() throws {
        #expect(try card("""
        {"source":"none","service":"stopped"}
        """) == MiloSourceCard.Card(title: "Milō", artist: nil, artwork: "/now-playing/milo.jpg"))
    }

    @Test("Une source inconnue de la table montre Milō plutôt qu'une carte vide")
    func anUnknownSourceShowsMilo() throws {
        #expect(try card("""
        {"source":"une-source-future"}
        """).title == "Milō")
    }

    @Test("Une station arrêtée n'offre que la reprise, pas les favorites")
    func aStoppedStationOffersOnlyToResume() throws {
        // La radio garde `next`/`prev` à l'arrêt pour parcourir ses favorites ;
        // sur l'écran verrouillé, une carte où rien ne joue n'offre que play.
        #expect(try controls("""
        {"source":"radio","controls":["resume_playback","next","prev"],
         "resume":{"title":"FIP","artist":null,"album":"FIP","artwork":null,
           "duration_ms":null,"position_ms":null}}
        """) == ["resume_playback"])
    }

    @Test("Une session en cours garde toutes ses commandes")
    func aLiveSessionKeepsItsCommands() throws {
        #expect(try controls("""
        {"source":"podcast","controls":["pause","seek","skip","set_speed"],
         "session":{"id":"9f","phase":"playing","title":"Épisode 12","artist":null,
           "album":null,"artwork":null,"senders":[],"duration_ms":2400000,
           "position":{"ms":192000,"at":1790270000.25,"rate":1.0}}}
        """) == ["pause", "seek", "skip", "set_speed"])
    }

    @Test("La table suit celle de Milō, entrée pour entrée")
    func theTableMatchesMilo() {
        // `SOURCE_CARDS` dans `backend/core/push/payloads.py`. Recopiée ici
        // parce qu'une orthographe différente fait basculer l'écran verrouillé
        // entre la carte du push et celle de l'app à chaque aller-retour.
        // Le nom et l'icône : l'un comme l'autre, divergents, font changer la
        // carte à chaque aller-retour.
        let pi: [String: String] = [
            "spotify": "Spotify|spotify", "qobuz": "Qobuz|qobuz", "tidal": "TIDAL|tidal",
            "airplay": "AirPlay|airplay", "bluetooth": "Bluetooth|bluetooth",
            "mac": "Récepteur macOS|macos", "radio": "Webradio|radio",
            "podcast": "Podcasts|podcast", "music_library": "Bibliothèque|music-library",
            "cd": "Lecteur CD|cd",
        ]
        #expect(MiloSourceCard.sources.mapValues { "\($0.title)|\($0.icon)" } == pi)
        #expect("\(MiloSourceCard.milo.title)|\(MiloSourceCard.milo.icon)" == "Milō|milo")
    }
}

/// Le seul lien entre un bouton de l'écran verrouillé et la source qui reçoit
/// sa commande : la source relue dans `currentTrack.id`. Milō l'écrit
/// `f"{source}:{title}"` (`payloads.build_attributes`), l'app par
/// `MiloTrackID.make` — et l'extension n'a plus de relecture réseau pour
/// rattraper un identifiant qu'elle lirait mal.
struct TrackIDTests {

    @Test("Chaque source se relit dans l'identifiant, même quand le titre porte des « : »")
    func everySourceRoundTrips() {
        for source in MiloSourceCard.sources.keys {
            #expect(MiloTrackID.source(of: MiloTrackID.make(source: source, title: "Artiste: Titre")) == source)
        }
    }

    @Test("L'identifiant qu'écrit Milō se relit pareil")
    func milosSpellingReadsTheSame() {
        #expect(MiloTrackID.source(of: "podcast:Podcasts") == "podcast")
        #expect(MiloTrackID.source(of: "radio:FIP: Jazz") == "radio")
    }

    @Test("Aucune source ne reçoit de commande : `none`, un identifiant sans préfixe")
    func nothingAddressesNoSource() {
        #expect(MiloTrackID.source(of: "none:Milō") == nil)
        #expect(MiloTrackID.source(of: "sans préfixe") == nil)
        #expect(MiloTrackID.source(of: ":titre") == nil)
    }

    @Test("Le nom qui active un bouton est celui que Milō liste dans `controls`")
    func commandNamesMatchControls() {
        typealias C = MiloAPIClient.ControlCommand
        #expect(C.transport(.play).name(forSource: "radio") == "resume_playback")
        #expect(C.transport(.pause).name(forSource: "radio") == "stop")
        #expect(C.transport(.playPause).name(forSource: "radio") == nil)
        #expect(C.transport(.play).name(forSource: "podcast") == "resume")
        #expect(C.transport(.previous).name(forSource: "spotify") == "prev")
        #expect(C.seek(to: 12).name(forSource: "podcast") == "seek")
        #expect(C.skip(by: -15).name(forSource: "podcast") == "skip")
    }
}

/// Ce qui part sur le réseau pour chaque bouton de l'écran verrouillé, et ce
/// qu'on a le droit de rejouer après un délai dépassé. Un délai dépassé ne dit
/// pas que Milō n'a rien fait : rejouer un `next` saute deux stations, rejouer
/// un +30 saute 60 s, pour un seul appui.
struct ControlCommandTests {

    typealias C = MiloAPIClient.ControlCommand

    @Test("Ce qui dépend du nombre d'appuis n'est jamais rejoué")
    func countedCommandsAreNeverRetried() {
        let counted: [C] = [.transport(.next), .transport(.previous), .transport(.playPause),
                            .skip(by: 30), .skip(by: -15)]
        for command in counted {
            #expect(!command.isIdempotent, "\(command) serait rejoué")
        }
    }

    @Test("Une position absolue ou un état visé se rejoue sans dommage")
    func absoluteCommandsMayBeRetried() {
        let absolute: [C] = [.transport(.play), .transport(.pause), .seek(to: 42)]
        for command in absolute {
            #expect(command.isIdempotent, "\(command) ne serait pas rejoué")
        }
    }

    @Test("Le corps porte le nom que la source attend, pour chaque source")
    func bodyNamesFollowTheSource() {
        for source in MiloSourceCard.sources.keys {
            #expect(C.transport(.next).body(forSource: source)?["command"] as? String == "next")
            #expect(C.transport(.previous).body(forSource: source)?["command"] as? String == "prev")
            let pause = C.transport(.pause).body(forSource: source)?["command"] as? String
            #expect(pause == (source == "radio" ? "stop" : "pause"))
            let playPause = C.transport(.playPause).body(forSource: source)
            #expect((playPause == nil) == (source == "radio"))
        }
    }

    @Test("Milō reçoit des millisecondes pour un seek, des secondes signées pour un skip")
    func seekAndSkipCarryTheirUnits() {
        let seek = C.seek(to: 12.5).body(forSource: "podcast")
        #expect(seek?["command"] as? String == "seek")
        #expect((seek?["data"] as? [String: Any])?["position_ms"] as? Int == 12_500)

        let skip = C.skip(by: -15).body(forSource: "podcast")
        #expect(skip?["command"] as? String == "skip")
        #expect((skip?["data"] as? [String: Any])?["seconds"] as? Double == -15)
    }

    @Test("Une valeur non finie ne fabrique aucun corps")
    func nonFiniteValuesAreGuarded() {
        // `Int(.nan * 1000)` ferait planter le processus, et `JSONSerialization`
        // lèverait une exception Objective-C sur un infini : rien ne doit partir.
        #expect(C.seek(to: .nan).body(forSource: "podcast") == nil)
        #expect(C.seek(to: .infinity).body(forSource: "podcast") == nil)
        #expect(C.skip(by: .nan).body(forSource: "podcast") == nil)
        #expect(C.skip(by: -.infinity).body(forSource: "podcast") == nil)
    }

    @Test("Un corps fabriqué passe toujours la sérialisation")
    func everyBodySerializes() throws {
        let commands: [C] = [.transport(.play), .transport(.next), .seek(to: 3.25), .skip(by: 30)]
        for command in commands {
            let body = try #require(command.body(forSource: "podcast"))
            #expect(JSONSerialization.isValidJSONObject(body))
        }
    }
}

/// La forme sous laquelle un token voyage partout ici — app group, URL de
/// retrait, file d'attente du token de session — et le chemin du retour.
struct HexTokenTests {

    func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test("Un token fait l'aller-retour octet pour octet")
    func roundTrips() {
        let token = Data((0...255).map { UInt8($0) })
        #expect(Data(hexString: hex(token)) == token)
        #expect(Data(hexString: "00ff10ab") == Data([0x00, 0xff, 0x10, 0xab]))
        #expect(Data(hexString: "00FF10AB") == Data([0x00, 0xff, 0x10, 0xab]))
    }

    @Test("Une entrée malformée ne donne pas de token")
    func malformedInputIsRejected() {
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
        #expect(Data(hexString: "0g") == nil)
        // `UInt8(_:radix:)` accepte un signe : « +f » passait pour 0x0f.
        #expect(Data(hexString: "+f") == nil)
        #expect(Data(hexString: "-0") == nil)
    }

    @Test("Une chaîne vide donne un token vide, pas un échec")
    func emptyIsEmpty() {
        #expect(Data(hexString: "") == Data())
    }
}

/// La carte à un seul appareil, le système Milō : chaque séquence est relevée au
/// banc (boutons physiques, écran verrouillé, journaux de MediaRemoteUI et de
/// l'extension). Un rappel écrit le niveau qu'iOS attend : G pour un appui, le
/// doigt pour la barre.
struct SystemVolumeModelTests {

    func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.0005) -> Bool {
        abs(a - b) < tolerance
    }

    /// Des niveaux rendus hors de toute commande d'iOS : des pushes de Milō,
    /// une seconde d'écart chacun.
    func seen(_ model: inout SystemVolumeModel, _ levels: Double..., from start: TimeInterval = 0) {
        for (i, level) in levels.enumerated() {
            model.observe(level, session: "s", duringCommand: false, now: start + Double(i))
        }
    }

    /// Les niveaux qu'un doigt sur la barre fait écrire, un rappel toutes les
    /// 65 ms.
    func slide(_ model: inout SystemVolumeModel, _ posed: [Double], shown: Double,
               from start: TimeInterval = 100, every interval: TimeInterval = 0.065) -> [Double] {
        posed.enumerated().map { i, value in
            let at = start + interval * Double(i)
            let level = model.obey(posed: value, shown: shown, now: at).level
            // iOS envoie le suivant ~11 ms après ce retour.
            model.returned(at: at + interval - 0.011)
            return level
        }
    }

    @Test("iOS sain : un appui écrit exactement affiché ± 1/16")
    func healthy() {
        var model = SystemVolumeModel()
        seen(&model, 0.3205)
        let plus = model.obey(posed: 0.383, shown: 0.3205, now: 100)
        #expect(plus.press?.up == true)
        #expect(close(plus.level, 0.383))
        let minus = model.obey(posed: 0.3205, shown: 0.383, now: 102)
        #expect(minus.press?.up == false)
        #expect(close(minus.level, 0.3205))
        #expect(close(model.ratio, 1))
    }

    /// Ce qui manquait : à rapport 1, la barre va d'un bout à l'autre, et le
    /// rapport reste à 1 après le geste.
    @Test("À rapport 1, la barre atteint le haut et le bas")
    func slideEndToEnd() {
        var model = SystemVolumeModel()
        seen(&model, 0.5)
        let up = slide(&model, [0.62, 0.8, 0.95, 1, 1], shown: 0.5)
        #expect(up.last == 1)
        #expect(zip(up, up.dropFirst()).allSatisfy { $0 <= $1 })
        let down = slide(&model, [0.7, 0.3, 0.05, 0], shown: 1, from: 110)
        #expect(down.last == 0)
        #expect(close(model.ratio, 1))
    }

    /// 29/10, 17:44:00.402–00.859 : le doigt part de 0,5186 et monte jusqu'en
    /// haut, sous le rapport qu'iOS tenait depuis l'après-midi — 0,61807793,
    /// ce qu'il pose doigt en haut. Posé ÷ rapport mène Milō en haut.
    @Test("Sous un rapport connu, un glissement jusqu'en haut met Milō au maximum")
    func slideToTheTop() {
        var model = SystemVolumeModel()
        seen(&model, 0.5186 / 0.61807793, 0.5186)
        let levels = slide(&model, [0.32321206, 0.47091976, 0.5490758, 0.5612653,
                                    0.5820591, 0.60428697, 0.61807793, 0.61807793], shown: 0.5186)
        #expect(close(levels[0], 0.5229, 0.001))
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(levels.last.map { close($0, 1, 0.000_1) } == true)
        #expect(close(model.ratio, 0.61807793, 0.000_1))
    }

    /// Le doigt saisit le curseur sous un rapport de 0,62, puis monte : le
    /// premier rappel est le curseur même, pas un appui.
    @Test("Saisir le curseur sous un rapport connu ne fait rien sauter")
    func grabTheThumb() {
        var model = SystemVolumeModel()
        seen(&model, 0.5 / 0.62, 0.5)
        let levels = slide(&model, [0.5, 0.6, 0.8, 1].map { 0.62 * $0 }, shown: 0.5)
        #expect(close(levels[0], 0.5, 0.001))
        #expect(close(levels.last ?? 0, 1, 0.001))
        #expect(close(model.ratio, 0.62, 0.001))
    }

    /// Revue du 29/10 : baissé ailleurs de 0,6 à 0,3 (rapport 0,5), toucher à
    /// 0,475 puis jusqu'en haut. Sous 1, le premier rappel se lit « − » ; il
    /// fait son pas, mais n'apprend pas 1 — le glissement plafonnait à 0,5.
    @Test("Un toucher lu en appui sous un autre rapport ne plafonne pas la barre")
    func touchReadAsAPressUnderAnotherRatio() {
        var model = SystemVolumeModel()
        seen(&model, 0.6, 0.3)
        let first = model.obey(posed: 0.5 * 0.475, shown: 0.3, now: 100)
        #expect(first.press?.up == false)
        #expect(!first.learned)
        #expect(first.level >= 0.3 - SystemVolumeModel.step - 0.000_1)
        model.returned(at: 100.054)
        let levels = slide(&model, [0.6, 0.8, 1, 1].map { 0.5 * $0 }, shown: first.level,
                           from: 100.065)
        #expect(close(levels.last ?? 0, 1, 0.001))
        #expect(close(model.ratio, 0.5, 0.001))
    }

    /// Une écriture lente (Pi occupé, Wi-Fi en veille) espace les rappels du
    /// doigt au-delà de `dragGap` : c'est le retour du précédent qui compte.
    @Test("Un glissement aux écritures lentes reste un glissement")
    func slowWritesKeepTheSlide() {
        var model = SystemVolumeModel()
        seen(&model, 0.5 / 0.62, 0.5)
        let levels = slide(&model, [0.5, 0.55, 0.6, 0.7, 0.8, 0.9, 1, 1].map { 0.62 * $0 },
                           shown: 0.5, every: 0.13)
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 + 0.000_1 })
        #expect(close(levels.last ?? 0, 1, 0.001))
        #expect(close(model.ratio, 0.62, 0.001))
    }

    /// 17:37:17.036–17.102 : doigt tenu au milieu, iOS rappelle à quelques
    /// millièmes près. Chaque rappel partait en cran et Milō montait au
    /// maximum ; le niveau reste maintenant sous le doigt.
    @Test("Un doigt immobile garde son niveau")
    func heldFingerKeepsItsLevel() {
        var model = SystemVolumeModel()
        seen(&model, 0.634)
        let levels = slide(&model, [0.5708, 0.5715832, 0.5720694, 0.5720694, 0.5719, 0.5722],
                           shown: 0.634)
        #expect((levels.max() ?? 1) - (levels.min() ?? 0) < 0.002)
        #expect(close(levels[0], 0.5708, 0.001))
    }

    /// Le doigt s'arrête, iOS se tait 400 ms, puis reprend tout près : rien ne
    /// saute.
    @Test("Une pause du doigt ne fait pas sauter le niveau")
    func pauseKeepsTheSlide() {
        var model = SystemVolumeModel()
        seen(&model, 0.5186)
        let before = slide(&model, [0.32321206, 0.40], shown: 0.5186)
        let after = model.obey(posed: 0.398, shown: 0.40, now: 100.065 + 0.4)
        #expect(after.press == nil)
        #expect(abs(after.level - before[1]) < 0.01)
    }

    /// Un toucher sur la piste, loin du curseur : la barre saute sous le doigt,
    /// Milō aussi.
    @Test("Un toucher loin du curseur y mène Milō")
    func tapFarFromTheCursor() {
        var model = SystemVolumeModel()
        seen(&model, 0.518)
        let tap = model.obey(posed: 0.054930817, shown: 0.518, now: 100)
        #expect(tap.press == nil)
        #expect(close(tap.level, 0.0549))
    }

    /// 17:36:59–17:37:02 : un bouton maintenu, répété par iOS toutes les
    /// 150–200 ms, pile sur la grille de 1/16. Ce sont des appuis.
    @Test("Un bouton maintenu reste une suite d'appuis")
    func heldButtonIsNotADrag() {
        var model = SystemVolumeModel()
        seen(&model, 0.1505)
        var now = 100.0
        for posed in [0.213, 0.2755, 0.338, 0.4005, 0.463, 0.5255] {
            let command = model.obey(posed: posed, shown: posed - 1.0 / 16, now: now)
            #expect(command.press?.up == true)
            #expect(close(command.level, posed))
            now += 0.165
        }
    }

    /// Volume presque à zéro, rapport connu : le doigt suit le rapport.
    @Test("Tout en bas, le glissement suit le rapport connu")
    func slideFromTheBottomUsesTheKnownRatio() {
        var model = SystemVolumeModel()
        seen(&model, 0.02 / 0.8, 0.02)
        let levels = slide(&model, [0.016, 0.1], shown: 0.02)
        #expect(close(levels[0], 0.02, 0.001))
        #expect(close(levels[1], 0.125, 0.001))
    }

    /// 22:58:22 : baissé ailleurs de 0,50 à 0,08. iOS engage 0,1425 et ne pose
    /// que 0,0228 (rapport 0,16) : c'est 0,1425 qu'il attend.
    @Test("Baissé ailleurs, un « + » écrit le G d'iOS")
    func plusAfterLoweredElsewhere() {
        var model = SystemVolumeModel()
        seen(&model, 0.50, 0.08)
        #expect(close(model.ratio, 0.16))

        let command = model.obey(posed: 0.0228, shown: 0.08, now: 100)
        #expect(command.press?.up == true)
        #expect(close(command.level, 0.1425))
    }

    /// 22:58:45 : sous un rapport de 0,16, la carte affiche ce qu'iOS vient de
    /// poser (0,0469) et le « + » rapproché suivant engage 0,1094, sous le
    /// niveau de Milō. Un « + » ne baisse jamais Milō : il fait un pas d'iOS.
    @Test("Des « + » rapprochés sous un rapport déréglé montent d'un pas chacun")
    func rapidPlusesStayPluses() {
        var model = SystemVolumeModel()
        seen(&model, 0.2308 / 0.16, 0.2308)
        var shown = 0.2308
        for (posed, at) in [(0.046927, 100.0), (0.017508, 100.48), (0.012801, 100.95)] {
            let command = model.obey(posed: posed, shown: shown, now: at)
            #expect(command.press?.up == true)
            #expect(close(command.level, shown + SystemVolumeModel.step, 0.000_1))
            shown = command.level
        }
    }

    /// Rejeu du 29/10, 15:11:49 (rapport 0,431) : les « − » rapprochés
    /// engagent depuis ce qu'iOS vient de poser. Écrits tels quels, ils
    /// menaient Milō de 0,436 au silence en trois appuis.
    @Test("Des « − » rapprochés descendent d'un pas chacun")
    func rapidMinusesStepOnce() {
        var model = SystemVolumeModel()
        seen(&model, 0.4364 / 0.43101, 0.4364)
        var shown = 0.4359
        for (posed, at) in [(0.1611551, 49.010), (0.042521458, 49.497), (0.0, 49.876)] {
            let command = model.obey(posed: posed, shown: shown, now: at)
            #expect(command.press?.up == false)
            #expect(close(command.level, shown - SystemVolumeModel.step, 0.000_1))
            shown = command.level
        }
    }

    /// Revue du 29/10 : Milō écrit à 1, quelqu'un le baisse à 0,6667 moins
    /// d'une seconde après ; la valeur optimiste reste fraîche trois secondes.
    /// Un « − » à 1,5 s partait de 1 et remontait Milō.
    @Test("Un appui part de ce que Milō rapporte quand l'optimiste est périmé")
    func pressFromTheReportedLevel() {
        var model = SystemVolumeModel()
        seen(&model, 1)
        _ = model.obey(posed: 1, shown: 0.9375, now: 100)
        model.observe(0.6667, session: "s", duringCommand: true, now: 100.8)
        let command = model.obey(posed: 0.9375, shown: 1, reported: 0.6667, now: 101.5)
        #expect(command.press?.up == false)
        #expect(close(command.level, 0.6667 - SystemVolumeModel.step, 0.000_1))
    }

    /// 23:29:03 : la carte montrait encore 0,9995 quand le global est tombé à
    /// 0,6667 ailleurs, une milliseconde avant le rappel d'un « − » (iOS : 0,9375).
    /// Écrit tel quel, le global est monté à 1 et un client est passé de 0 à
    /// 100 %.
    @Test("Un « − » parti juste avant un changement fait ailleurs baisse Milō")
    func minusRacingAnExternalChange() {
        var model = SystemVolumeModel()
        seen(&model, 1.0, 0.9995, from: 90)
        model.observe(0.6667, session: "s", duringCommand: false, now: 100)

        let command = model.obey(posed: 0.9375, shown: 0.6667, now: 100.001)
        #expect(command.press?.up == false)
        #expect(close(command.expected, 0.9375, 0.001))
        #expect(close(command.level, 0.6667 - 1.0 / 16, 0.001))
    }

    @Test("Un « − » sous le premier cran met Milō à zéro")
    func downToTheFloor() {
        var model = SystemVolumeModel()
        seen(&model, 0.03)
        let command = model.obey(posed: 0, shown: 0.03, now: 100)
        #expect(command.press?.up == false)
        #expect(command.level == 0)
        // iOS garde ses rapports à zéro.
        #expect(close(model.ratio, 1))
    }

    /// 17/10, 00:50:25 : iOS tenait 0,909, le modèle croyait 1. Le premier
    /// appui ne se reconnaît pas ; le deuxième suppose le même rapport, et à
    /// partir de lui chaque appui écrit le G exact. Sans cela, chaque « + »
    /// posait 0,909 × G et Milō plafonnait vers 0,62.
    @Test("Un rapport inconnu s'apprend au deuxième appui")
    func unknownRatioIsLearned() {
        var model = SystemVolumeModel()
        seen(&model, 0.1716)
        var shown = 0.1716
        var at = 100.0
        for (i, up) in [true, true, true, true, false, false, false, true, true].enumerated() {
            let commit = shown + (up ? 1 : -1) * SystemVolumeModel.step
            let command = model.obey(posed: 0.9086 * commit, shown: shown, now: at)
            #expect((command.level > shown) == up)
            if i > 0 {
                #expect(command.press?.up == up)
                #expect(close(command.level, commit, 0.001))
            }
            shown = command.level
            at += 2
        }
        #expect(close(model.ratio, 0.9086, 0.001))
    }

    /// iOS est reparti de zéro sans qu'on le voie : le rapport suivi ne lit
    /// rien, 1 lit l'appui.
    @Test("Un iOS reparti de zéro en douce se relit quand même")
    func unseenReset() {
        var model = SystemVolumeModel()
        seen(&model, 0.50, 0.08)
        let command = model.obey(posed: 0.1425, shown: 0.08, now: 100)
        #expect(command.press?.up == true)
        #expect(close(command.level, 0.1425))
        // Un seul appui ne suffit pas à changer de rapport ; le suivant le
        // confirme.
        let next = model.obey(posed: 0.1425 + 1.0 / 16, shown: 0.1425, now: 102)
        #expect(next.learned)
        #expect(close(model.ratio, 1, 0.001))
    }

    @Test("Une autre session repart de zéro")
    func newSession() {
        var model = SystemVolumeModel()
        seen(&model, 0.50, 0.08)
        model.observe(0.08, session: "autre", duringCommand: false, now: 10)
        #expect(close(model.ratio, 1))
    }

    /// 30/10, 11:35:08 → 11:35:15 : la carte d'une session montre 0,0785 ;
    /// une ré-annonce reconstruit l'autre, dont le rendu périmé dit 0,01, et
    /// iOS engage un « − » depuis 0,0785 deux millisecondes plus tard. Milō
    /// avait été monté entre-temps sur Milo-Mac.
    @Test("Un appui juste après un changement de session part du vrai niveau de Milō")
    func pressAcrossASessionChange() {
        var model = SystemVolumeModel()
        model.observe(0.0785, session: "A", duringCommand: false, now: 100)
        model.observe(0.01, session: "B", duringCommand: false, now: 107.661)
        #expect(model.opensGesture(at: 107.663))

        let command = model.obey(posed: 0.016000003, shown: 0.01, reported: 0.50, now: 107.663)

        #expect(command.press?.up == false)
        #expect(close(command.level, 0.50 - SystemVolumeModel.step))
    }

    @Test("Un rappel qui suit un glissement n'ouvre pas de geste")
    func followingCallbackOpensNoGesture() {
        var model = SystemVolumeModel()
        seen(&model, 0.30)
        _ = model.obey(posed: 0.30, shown: 0.30, now: 100)
        model.returned(at: 100.054)
        #expect(!model.opensGesture(at: 100.065))
        #expect(model.opensGesture(at: 103))
    }

    /// 29/10, 15:11:49 → 15:11:53 : un push tardif fait perdre au rendu son
    /// écart de confirmation hors commande (0,321 → 0,3205). iOS l'ignore et
    /// engage encore depuis 0,321 à 0,431.
    @Test("Un écart de confirmation perdu sur un push n'efface pas le rapport")
    func confirmationOffsetLostOnAPush() {
        var model = SystemVolumeModel()
        seen(&model, 0.4364 / 0.43101, 0.4364)
        #expect(model.obey(posed: 0.1611551, shown: 0.4359, now: 49.010).press?.up == false)
        model.observe(0.3979, session: "s", duringCommand: true, now: 49.027)
        #expect(model.obey(posed: 0.042521458, shown: 0.3974, now: 49.497).press?.up == false)
        model.observe(0.3595, session: "s", duringCommand: true, now: 49.521)
        #expect(model.obey(posed: 0, shown: 0.3590, now: 49.876).press?.up == false)
        model.observe(0.3210, session: "s", duringCommand: true, now: 49.901)

        model.observe(0.3205, session: "s", duringCommand: false, now: 52.104)
        #expect(close(model.ratio, 0.4310, 0.001))

        let command = model.obey(posed: 0.16529281, shown: 0.3205, now: 53.628)
        #expect(command.press?.up == true)
        // 0,16529 = 0,43101 × (0,321 + 1/16) : l'affichage d'iOS, écart compris.
        #expect(close(command.expected, 0.3835, 0.0002))
        #expect(close(command.level, 0.3205 + 1.0 / 16, 0.000_1))
    }

    /// L'état resté dans le conteneur après la trace du 29/10, rangé avant
    /// `anchor` : il doit se relire tel quel, et son dernier appui
    /// (0,1612 / 0,3734) redonner le rapport.
    @Test("L'état rangé avant la correction relit le premier appui")
    func storedStateFromBeforeTheFix() throws {
        let json = #"""
            {"session":"s","ceiling":0.3974,"reference":0.3974,"lastSeen":0.3974,
             "previousSeen":0.3979,"seenAt":62.61,"lastPosed":0.1611551,
             "lastCommit":0.3734,"lastAt":61.416}
            """#
        let stored = try JSONDecoder().decode(SystemVolumeModel.self, from: Data(json.utf8))
        #expect(close(stored.ratio, 1))

        var plus = stored
        #expect(plus.obey(posed: 0.43101 * (0.3979 + 1.0 / 16), shown: 0.3974, now: 100)
            .press?.up == true)
        var minus = stored
        #expect(minus.obey(posed: 0.43101 * (0.3979 - 1.0 / 16), shown: 0.3974, now: 100)
            .press?.up == false)
    }

    /// Un niveau que le modèle adopte et pas iOS — ici 0,0015 hors commande,
    /// un seuil d'iOS qu'on ne connaît pas — ne fait pas oublier le rapport
    /// reconnu.
    @Test("Le dernier rapport reconnu survit à une adoption qu'iOS n'a pas faite")
    func anchorSurvivesAnUnsharedAdoption() {
        var model = SystemVolumeModel()
        seen(&model, 0.3210 / 0.431, 0.3210)
        #expect(model.obey(posed: 0.431 * (0.3210 + 1.0 / 16), shown: 0.3210, now: 100)
            .press?.up == true)
        model.observe(0.3835, session: "s", duringCommand: true, now: 100.05)
        model.observe(0.3850, session: "s", duringCommand: false, now: 103)
        #expect(model.ratio > 0.9)

        let command = model.obey(posed: 0.431 * (0.3850 + 1.0 / 16), shown: 0.3850, now: 104)
        #expect(command.press?.up == true)
        #expect(close(command.level, 0.3850 + 1.0 / 16, 0.001))
    }

    /// Le cas d'origine : en bas de course, le rendu porte l'écart de
    /// confirmation (0,0633 pour 0,0628) et le bon « − » supposait un rapport
    /// > 1,04 depuis 0,0628.
    @Test("En bas de course, un « − » depuis le rendu avec son écart reste un « − »")
    func minusAtTheBottomWithTheOffset() {
        var model = SystemVolumeModel()
        seen(&model, 0.0633 / 0.431, 0.0633)
        let command = model.obey(posed: 0.431 * (0.0633 - 1.0 / 16), shown: 0.0628, now: 100)
        #expect(command.press?.up == false)
        #expect(command.level < 0.0628)
    }

    /// En bas de course, juste après un appui engagé à zéro, le « − » suivant
    /// part de notre rendu : 0,0005 de trop dans `shown` le faisait écarter
    /// (rapport > 1,04) et relire « + ».
    @Test("En bas de course, un « − » après un appui à zéro reste un « − »")
    func minusAfterAZeroCommitAtTheBottom() {
        var model = SystemVolumeModel()
        seen(&model, 0.1205 / 0.431, 0.1205)
        #expect(model.obey(posed: 0.431 * (0.1205 - 1.0 / 16), shown: 0.1200, now: 100)
            .press?.up == false)
        model.observe(0.0585, session: "s", duringCommand: true, now: 100.06)
        #expect(model.obey(posed: 0, shown: 0.0580, now: 100.45).press?.up == false)
        model.observe(0.0005, session: "s", duringCommand: true, now: 100.51)

        let command = model.obey(posed: 0, shown: 0, now: 101.65)
        #expect(command.press?.up == false)
        #expect(command.level == 0)
    }
}
