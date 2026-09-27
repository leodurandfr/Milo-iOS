import Testing
import Foundation
@testable import Milo_iOS

/// Ce que le curseur global du Centre de contrôle demande, et ce qu'on en fait.
///
/// Le système envoie un facteur commun sur toutes les enceintes, mais ce facteur
/// porte des niveaux absolus : ce sont eux qui disent où le doigt a laissé la
/// poignée. Ces tests figent ça, parce que la relecture du facteur comme un gain
/// a été essayée le 20/09/2026 et rendait les extrémités inatteignables.
///
/// Tout est sur l'échelle du curseur, 0…1, et plus du tout en décibels : la
/// conversion appartient à Milō, qui seul connaît ses bornes. Des chiffres en
/// décibels réapparaissant ici seraient le signe que la conversion est revenue.
struct VolumeGestureTests {

    /// Les trois niveaux mesurés le 20/09/2026 sur un vrai glissement.
    let measured = ["a": 0.4264775, "b": 0.4300078, "c": 0.43415198]

    @Test("On applique le niveau demandé, pas un dérivé du facteur")
    func targetIsTheRequestedLevel() throws {
        let target = try #require(
            MiloAPIClient.globalTarget(touched: measured, snapshot: measured))

        // La moyenne des trois. La lecture du facteur comme un gain donnait
        // 0,33 là où le système en demandait 0,43.
        #expect(abs(target - 0.43021) < 0.0001)
    }

    @Test("Les extrémités sont atteignables")
    func extremesAreReachable() throws {
        let top = try #require(MiloAPIClient.globalTarget(
            touched: ["a": 1, "b": 1, "c": 1], snapshot: measured))
        let bottom = try #require(MiloAPIClient.globalTarget(
            touched: ["a": 0, "b": 0, "c": 0], snapshot: measured))

        #expect(top == 1)
        #expect(bottom == 0)
    }

    @Test("Hors bornes, on borne")
    func targetIsClamped() throws {
        #expect(try #require(MiloAPIClient.globalTarget(
            touched: ["a": 4], snapshot: ["a": 0.5])) == 1)
        #expect(try #require(MiloAPIClient.globalTarget(
            touched: ["a": -4], snapshot: ["a": 0.5])) == 0)
    }

    @Test("Sans enceinte, rien à viser")
    func emptyIsRejected() {
        #expect(MiloAPIClient.globalTarget(touched: [:], snapshot: [:]) == nil)
    }

    @Test("Une rafale partielle laisse en place les enceintes qu'elle ne cite pas")
    func aPartialBurstKeepsUntouchedSpeakersInPlace() throws {
        // Deux enceintes sur trois montent de 0,43 à 0,86 ; la troisième n'a
        // pas bougé, et sa place dans la moyenne est son niveau actuel.
        let snapshot = ["a": 0.43, "b": 0.43, "c": 0.43]
        let target = try #require(MiloAPIClient.globalTarget(
            touched: ["a": 0.86, "b": 0.86], snapshot: snapshot))

        #expect(abs(target - 0.7166667) < 0.0001)
    }

    @Test("Une cible pour une enceinte absente de l'instantané est ignorée")
    func aTargetForAVanishedSpeakerIsIgnored() throws {
        // L'enceinte s'est éteinte entre le rendu et la rafale : la moyenne
        // reste celle des enceintes que le système a réellement sous les yeux.
        let target = try #require(MiloAPIClient.globalTarget(
            touched: ["a": 0.8, "disparue": 0.1], snapshot: ["a": 0.8, "b": 0.6]))

        #expect(abs(target - 0.7) < 0.0001)
    }

    @Test("Deux enceintes touchées : geste global")
    func twoSpeakersAreGlobal() {
        #expect(MiloAPIClient.isGlobalGesture(touched: 2, deviceCount: 3))
    }

    @Test("Une rafale incomplète reste un geste global")
    func anIncompleteBurstIsStillGlobal() {
        // L'ancienne règle exigeait `touched == deviceCount` et rejetait
        // celle-ci, ce qui la faisait repartir en écritures par enceinte.
        #expect(MiloAPIClient.isGlobalGesture(touched: 2, deviceCount: 4))
    }

    @Test("Une base quasi nulle ne casse plus la détection")
    func aNearZeroBaseNoLongerBreaksDetection() {
        // Une enceinte presque coupée ne rendait plus de rapport exploitable,
        // et son absence faisait retomber tout le geste en mode par enceinte.
        // Le compte ne dépend plus d'aucun rapport.
        #expect(MiloAPIClient.isGlobalGesture(touched: 3, deviceCount: 3))
    }

    @Test("Une seule enceinte touchée : curseur individuel")
    func singleSpeakerIsNotGlobal() {
        #expect(!MiloAPIClient.isGlobalGesture(touched: 1, deviceCount: 3))
    }

    @Test("Une enceinte seule n'a aucun équilibre à préserver")
    func singleDeviceStaysPerClient() {
        #expect(!MiloAPIClient.isGlobalGesture(touched: 1, deviceCount: 1))
    }
}

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
        let inerte = 0.0 * 2.0
        #expect(inerte == 0)
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
        // Parti du niveau affiché, `noteShift` rangerait l'écart dans la valeur
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

/// Le plafond caché d'iOS sous le curseur principal, et la relecture des rafales.
///
/// Chaque séquence est relevée sur l'iPhone (journaux de `mediaremoted`, 26 et
/// 27/09/2026) : les niveaux rendus — hors commande ou pendant une commande —,
/// puis ce qu'iOS a demandé pour un appui. Le modèle doit retrouver le G engagé,
/// le sens de l'appui, et le niveau voulu.
struct GroupVolumeMirrorTests {

    func all(_ level: Double) -> [String: Double] { ["a": level, "b": level, "c": level] }

    func close(_ a: Double?, _ b: Double, _ tolerance: Double = 0.0002) -> Bool {
        guard let a else { return false }
        return abs(a - b) < tolerance
    }

    /// Des niveaux rendus hors de toute commande d'iOS : un push de Milō.
    func pushed(_ mirror: inout GroupVolumeMirror, _ levels: Double...) {
        for level in levels { mirror.observe(all(level), duringCommand: false) }
    }

    /// 27/09, 01:21:36 → 01:21:44 : baissé ailleurs à 0,0278 sous un plafond
    /// de 0,1569, puis « + », « + », « − ». Le rendu corrigé du premier « + »
    /// (0,0908) arrive pendant la commande : la carte l'affiche, iOS ne l'adopte
    /// pas. Le lire comme adopté faisait prendre le second « + » pour un « − ».
    @Test("Ce qu'iOS affiche sans l'adopter : « + », « + », « − » relus justes")
    func renderedDuringACommandIsNotAdopted() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.1569, 0.1135, 0.0278)

        let first = mirror.interpret(burst: all(0.016), shown: all(0.0278), now: 100)
        #expect(first?.kind == .button(up: true))
        #expect(close(first?.systemLevel, 0.0903))
        mirror.observe(all(0.0908), duringCommand: true)

        let second = mirror.interpret(burst: all(0.027162), shown: all(0.0903), now: 101.6)
        #expect(second?.kind == .button(up: true))
        #expect(close(second?.systemLevel, 0.1533))
        #expect(close(second?.intended, 0.0903 + 0.0625))
        mirror.observe(all(0.1533), duringCommand: true)

        let third = mirror.interpret(burst: all(0.016088), shown: all(0.1528), now: 104.4)
        #expect(third?.kind == .button(up: false))
        #expect(close(third?.systemLevel, 0.0908))
    }

    /// 26/09, 17:57 : engagé à 0,6609, puis baissé ailleurs jusqu'à 0,5323. Un
    /// « − » a posé 0,378385 au lieu de 0,4698.
    @Test("Baissé ailleurs, un « − » se relit comme « affiché − 1/16 »")
    func loweredElsewhereThenDown() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.6609, 0.618, 0.4038, 0.4895, 0.5323)
        #expect(close(mirror.ceiling, 0.6609))

        let reading = mirror.interpret(burst: all(0.378385), shown: all(0.5323), now: 100)
        #expect(reading?.kind == .button(up: false))
        #expect(close(reading?.intended, 0.4698))
        #expect(close(reading?.targets["a"], 0.4698))
    }

    /// 26/09, 20:03 : un plafond resté à 0,45 depuis 27 minutes, le son à
    /// 0,1214. Un « + » a demandé 0,0496 : le son a baissé.
    @Test("Sous un plafond resté haut, un « + » monte au lieu de baisser")
    func plusNoLongerLowers() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.45, 0.1214)

        let reading = mirror.interpret(burst: all(0.049612), shown: all(0.1214), now: 100)
        #expect(reading?.kind == .button(up: true))
        #expect(close(reading?.systemLevel, 0.1839))
        #expect(close(reading?.intended, 0.1839))
        #expect(close(mirror.ceiling, 0.1839))
        #expect(close(mirror.reference["a"], 0.049612, 0.000001))
    }

    /// 26/09, 17:48 : le plafond est la valeur externe la plus haute (0,6177),
    /// pas le dernier G engagé (0,5748).
    @Test("Le plafond monte avec un niveau vu plus haut que lui")
    func theCeilingRisesWithAHigherLevel() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.5748, 0.6177, 0.5748, 0.5319)
        #expect(close(mirror.ceiling, 0.6177))

        let reading = mirror.interpret(burst: all(0.404199), shown: all(0.5319), now: 100)
        #expect(reading?.kind == .button(up: false))
        #expect(close(reading?.intended, 0.4694))
    }

    @Test("iOS sain : la correction vaut exactement 1")
    func aHealthySystemIsLeftAlone() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.3205)
        let reading = mirror.interpret(burst: all(0.383), shown: all(0.3205), now: 100)
        #expect(reading?.kind == .button(up: true))
        #expect(close(reading?.targets["b"], 0.383, 0.001))
    }

    /// iOS a recréé son point d'accès sans qu'on le sache : il repart de ce
    /// qu'il affiche. Lire avec le plafond suivi donnerait 0,68.
    @Test("Une remise à zéro d'iOS passée inaperçue ne fait pas sauter le son")
    func anUnseenResetDoesNotOvershoot() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.45, 0.1214)

        let reading = mirror.interpret(burst: all(0.1839), shown: all(0.1214), now: 100)
        #expect(reading?.hypothesis == "saine")
        #expect(close(reading?.intended, 0.1839))
    }

    @Test("Un glissement sous un plafond resté haut suit le doigt")
    func aSlideFollowsTheFinger() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.45, 0.1214)

        // Le doigt part de 0,1214 et passe à 0,15 : iOS demande 0,1214 × 0,15 / 0,45.
        let first = mirror.interpret(burst: all(0.04047), shown: all(0.1214), now: 100)
        #expect(first?.kind == .slider)
        #expect(close(first?.intended, 0.15, 0.001))
        mirror.observe(all(0.1505), duringCommand: true)

        // 250 ms plus tard, à 0,20 : iOS part de ce qu'il a posé (0,04047) et de 0,15.
        let second = mirror.interpret(burst: all(0.05396), shown: all(0.15), now: 100.25)
        #expect(second?.kind == .slider)
        #expect(close(second?.intended, 0.20, 0.001))
    }

    /// Une seule enceinte : son curseur de pièce pose une valeur telle quelle,
    /// qu'il ne faut pas multiplier par le plafond.
    @Test("Le curseur de pièce d'une enceinte seule n'est pas multiplié")
    func aSingleSpeakerRoomSliderIsNotScaled() {
        var mirror = GroupVolumeMirror()
        mirror.observe(["a": 0.45], duringCommand: false)
        mirror.observe(["a": 0.1214], duringCommand: false)

        let reading = mirror.interpret(burst: ["a": 0.13], shown: ["a": 0.1214], now: 100)
        #expect(close(reading?.intended, 0.13))
    }

    @Test("Un « − » tout en bas pose zéro")
    func downAtTheBottomIsZero() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.054)
        let reading = mirror.interpret(burst: all(0), shown: all(0.054), now: 100)
        #expect(reading?.kind == .button(up: false))
        #expect(reading?.intended == 0)
    }

    @Test("Hors commande, un vrai changement est adopté ; un rendu inchangé, non")
    func onlyAChangeOutsideACommandIsAdopted() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.45, 0.1214)
        _ = mirror.interpret(burst: all(0.049612), shown: all(0.1214), now: 100)
        mirror.observe(all(0.1844), duringCommand: true)
        #expect(close(mirror.reference["a"], 0.049612, 0.000001))
        #expect(close(mirror.card["a"], 0.1844, 0.000001))

        // Le push de Milō confirme le même niveau : rien ne bouge pour iOS.
        mirror.observe(all(0.1844), duringCommand: false)
        #expect(close(mirror.reference["a"], 0.049612, 0.000001))

        // Un changement fait ailleurs, lui, devient la référence.
        mirror.observe(all(0.3), duringCommand: false)
        #expect(close(mirror.reference["a"], 0.3, 0.000001))
        #expect(close(mirror.ceiling, 0.3, 0.000001))
    }

    /// 27/09, 02:02:36 : cinq « + » dans le Centre de contrôle engagent
    /// 0,20 → 0,26 → 0,32 → 0,38 → 0,44 — l'affiché + 1/16, tronqué au centième.
    @Test("Le Centre de contrôle tronque son pas au centième : c'est encore un bouton")
    func controlCenterTruncatesItsStep() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.20)
        mirror.observe(all(0.2005), duringCommand: true)   // notre rendu, écart compris

        let up = mirror.interpret(burst: all(0.26), shown: all(0.20), now: 100)
        #expect(up?.kind == .button(up: true))
        #expect(close(up?.systemLevel, 0.26))
        mirror.observe(all(0.2630), duringCommand: true)

        let down = mirror.interpret(burst: all(0.20), shown: all(0.2625), now: 101)
        #expect(down?.kind == .button(up: false))
    }

    /// Un glissement du même Centre de contrôle, relevé à 02:02:45 : aucune de
    /// ses valeurs ne tombe sur l'affiché ± 1/16 tronqué.
    @Test("Un glissement du Centre de contrôle reste un glissement")
    func aControlCenterSlideStaysASlide() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.09)
        var shown = 0.09
        var now = 100.0
        for level in [0.11, 0.19, 0.20, 0.12, 0.09, 0.08, 0.15, 0.19, 0.18, 0.17] {
            let reading = mirror.interpret(burst: all(level), shown: all(shown), now: now)
            #expect(reading?.kind == .slider, "\(shown) → \(level)")
            mirror.observe(all(level + 0.0005), duringCommand: true)
            shown = level
            now += 0.25
        }
    }

    /// 27/09, 02:07:44 → 02:07:46, déverrouillé : « + » puis trois « − » à
    /// moins d'une seconde d'écart. iOS part chaque fois de son propre dernier G
    /// (0,2451 → 0,1826 → 0,1201 → 0,0576), pas de notre rendu, qu'il n'affiche
    /// qu'au bout d'≈ 1,07 s. Lus comme des glissements, deux de ces appuis
    /// partaient en niveau absolu : -65 dB, puis -74 dB.
    @Test("Des appuis rapides partent du dernier G d'iOS, et restent des appuis")
    func quickPressesStartFromTheLastSystemLevel() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.1826)

        let plus = mirror.interpret(burst: all(0.244273), shown: all(0.1820), now: 100)
        #expect(plus?.kind == .button(up: true))
        mirror.observe(all(0.2111), duringCommand: true)

        let first = mirror.interpret(burst: all(0.181978), shown: all(0.2105), now: 100.97)
        #expect(first?.kind == .button(up: false))
        mirror.observe(all(0.1825), duringCommand: true)

        let second = mirror.interpret(burst: all(0.119683), shown: all(0.1819), now: 101.55)
        #expect(second?.kind == .button(up: false))
        mirror.observe(all(0.1540), duringCommand: true)

        let third = mirror.interpret(burst: all(0.057389), shown: all(0.1535), now: 102.18)
        #expect(third?.kind == .button(up: false))
    }

    /// 27/09, 18:49:41 → 18:52:23, écran verrouillé. iOS a engagé 0,021683 et posé
    /// 0,015656 / 0,015140 (rapport 0,72207), puis un « − » l'a mené à zéro. Le
    /// rendu reste au plancher (0,0100) pendant la commande comme après, alors que
    /// Milō rapporte 0,0023 / 0 / 0,0023 : iOS ne voit rien changer, et garde son
    /// rapport à travers le zéro (0,05235 = 0,72207 × 0,0725). Le miroir, lui,
    /// repartait d'un plafond nul, adoptait 0,0100 comme référence et plafond, et
    /// lisait les « + » suivants comme des glissements (0,0523, 0,0833, 0,1056).
    @Test("À volume très bas, un zéro ne remet pas le rapport d'iOS à 1")
    func aZeroKeepsTheSystemRatio() {
        var mirror = GroupVolumeMirror(
            ceiling: 0.021683,
            reference: ["a": 0.015656, "b": 0.015140, "c": 0.015656],
            card: ["a": 0.0180, "b": 0.0111, "c": 0.0180],
            cardRule: .loudest)
        mirror.observe(["a": 0.0180, "b": 0.0111, "c": 0.0180], duringCommand: false)

        let zero = mirror.interpret(burst: all(0), shown: ["a": 0.0175, "b": 0.0106, "c": 0.0175],
                                    now: 100)
        #expect(zero?.kind == .button(up: false))
        mirror.observe(all(0.01), duringCommand: true)
        pushed(&mirror, 0.01, 0.01, 0.01)

        let presses: [(burst: [String: Double], shown: Double, during: Double,
                       up: Bool, system: Double, now: Double)] = [
            (["a": 0.052350, "b": 0.050625, "c": 0.052350], 0.01, 0.05285, true, 0.0725, 368.8),
            (["a": 0.083291, "b": 0.080546, "c": 0.083291], 0.05235, 0.083791, true, 0.11535, 371.0),
            (["a": 0.105632, "b": 0.102151, "c": 0.105632], 0.083291, 0.106132, true, 0.146291, 373.2),
            (["a": 0.031505, "b": 0.030467, "c": 0.031505], 0.105632, 0.0324, false, 0.043632, 376.5),
            (all(0), 0.0319, 0.01, false, 0, 379.1),
            (all(0), 0.01, 0.01, false, 0, 381.0),
        ]
        for press in presses {
            let reading = mirror.interpret(burst: press.burst, shown: all(press.shown), now: press.now)
            #expect(reading?.kind == .button(up: press.up), "\(press.now) : \(reading?.summary ?? "nil")")
            #expect(close(reading?.systemLevel, press.system), "\(press.now)")
            mirror.observe(all(press.during), duringCommand: true)
            pushed(&mirror, press.during)
        }
    }

    /// 27/09, 18:42:34 → 18:49:41. Le miroir est juste après un « − » du Centre de
    /// contrôle (G = 0,10). Milō remonte ensuite ailleurs jusqu'à 0,5274 / 0,5204
    /// / 0,5274 : iOS prend 0,5204 pour plafond, le miroir 0,5274. Trois appuis du
    /// Centre de contrôle (0,37, 0,43, 0,29) laissent le miroir à 0,2944 contre
    /// 0,29 chez iOS. Baissé depuis l'app à 0,2094 / 0,2025 / 0,2094, iOS tient
    /// un rapport de 0,72207, le miroir 0,711. À 1,5 % d'écart, le « + » de
    /// 18:49:10 n'était plus reconnu, et l'hypothèse « saine », la plus proche
    /// du doigt, a fait BAISSER le son (0,2094 → 0,1963) en remettant le
    /// rapport du miroir à 1 : les cinq appuis suivants sont partis en
    /// glissements.
    @Test("Un miroir décalé par des niveaux inégaux reconnaît l'appui, et s'y recale")
    func aSlightlyOffMirrorStillReadsAPress() {
        var mirror = GroupVolumeMirror(
            ceiling: 0.10,
            reference: ["a": 0.10, "b": 0.090336, "c": 0.10],
            card: ["a": 0.1421, "b": 0.1352, "c": 0.1421],
            cardRule: .loudest)
        func push(_ loud: Double, _ quiet: Double) {
            mirror.observe(["a": loud, "b": quiet, "c": loud], duringCommand: false)
        }
        push(0.1421, 0.1352)
        for (loud, quiet) in [(0.1845, 0.1775), (0.3988, 0.3918), (0.4416, 0.4347),
                              (0.5274, 0.5204), (0.4845, 0.4775), (0.3131, 0.3061)] {
            push(loud, quiet)
        }

        // Centre de contrôle : 0,37 (« + » tronqué), puis 0,43 et 0,29.
        let cc = mirror.interpret(burst: ["a": 0.222611, "b": 0.217635, "c": 0.222611],
                                  shown: ["a": 0.3131, "b": 0.3061, "c": 0.3131], now: 2820.12)
        #expect(cc?.kind == .button(up: true))
        mirror.observe(["a": 0.3421, "b": 0.3351, "c": 0.3421], duringCommand: true)
        push(0.3421, 0.3351)
        _ = mirror.interpret(burst: ["a": 0.258711, "b": 0.252927, "c": 0.258711],
                             shown: ["a": 0.3416, "b": 0.3346, "c": 0.3416], now: 2822.34)
        mirror.observe(["a": 0.4364, "b": 0.4294, "c": 0.4364], duringCommand: true)
        push(0.4364, 0.4294)
        _ = mirror.interpret(burst: ["a": 0.174479, "b": 0.170578, "c": 0.174479],
                             shown: ["a": 0.4359, "b": 0.4289, "c": 0.4359], now: 2823.43)
        mirror.observe(["a": 0.2956, "b": 0.2886, "c": 0.2956], duringCommand: true)
        push(0.2956, 0.2886)
        push(0.2523, 0.2453)
        push(0.2094, 0.2025)

        let presses: [(burst: [String: Double], shown: [String: Double],
                       rendered: [String: Double], up: Bool, system: Double, now: Double)] = [
            (["a": 0.196331, "b": 0.189861, "c": 0.196331], ["a": 0.2094, "b": 0.2025, "c": 0.2094],
             ["a": 0.196974, "b": 0.1901, "c": 0.196974], true, 0.2719, 2950.84),
            (["a": 0.187358, "b": 0.181185, "c": 0.187358], ["a": 0.196474, "b": 0.1896, "c": 0.196474],
             ["a": 0.187965, "b": 0.1811, "c": 0.187965], true, 0.259474, 2973.78),
            (["a": 0.180853, "b": 0.174894, "c": 0.180853], ["a": 0.187465, "b": 0.1806, "c": 0.187465],
             ["a": 0.181434, "b": 0.1745, "c": 0.181434], true, 0.250465, 2975.33),
            (["a": 0.176137, "b": 0.170333, "c": 0.176137], ["a": 0.180934, "b": 0.1740, "c": 0.180934],
             ["a": 0.176698, "b": 0.1698, "c": 0.176698], true, 0.243934, 2976.59),
            (["a": 0.082459, "b": 0.079742, "c": 0.082459], ["a": 0.176198, "b": 0.1693, "c": 0.176198],
             ["a": 0.084183, "b": 0.0773, "c": 0.084183], false, 0.114198, 2979.81),
            (["a": 0.015656, "b": 0.015140, "c": 0.015656], ["a": 0.083683, "b": 0.0768, "c": 0.083683],
             ["a": 0.0180, "b": 0.0111, "c": 0.0180], false, 0.021683, 2981.26),
        ]
        for press in presses {
            let reading = mirror.interpret(burst: press.burst, shown: press.shown, now: press.now)
            #expect(reading?.kind == .button(up: press.up), "\(press.now) : \(reading?.summary ?? "nil")")
            #expect(close(reading?.systemLevel, press.system), "\(press.now)")
            mirror.observe(press.rendered, duringCommand: true)
            mirror.observe(press.rendered, duringCommand: false)
        }
        // Recalé sur le G d'iOS dès le premier appui, sans plus d'incertitude.
        #expect(close(mirror.ceiling, 0.021683, 0.000001))
        #expect(mirror.slack == 0)
    }

    /// 27/09, 20:40:27 → 20:40:57. Baissé depuis l'app à 0,0100 / 0,0127 / 0,0100
    /// sous un plafond de 0,2095, puis le Centre de contrôle : « + » à 0,07, un
    /// toucher du curseur à 0,46, un « − » à 0. L'état suivi lisait 0,4600 pile,
    /// mais loin du doigt : « saine » a écrit 0,023 et remis le rapport à 1.
    /// Deux « − » de trop à zéro n'ont pas rappelé l'extension ; la carte est
    /// restée à 0, et iOS a remis ses rapports à 1 : le « + » a engagé 0,0625 et
    /// posé 0,0625 partout. Lu comme un glissement à 0,149 : le son a sauté.
    @Test("Au zéro, le Centre de contrôle et les « − » de trop ne font pas sauter le son")
    func controlCenterJumpAndExtraZeros() {
        var mirror = GroupVolumeMirror(
            ceiling: 0.209467,
            reference: ["a": 0.01, "b": 0.0127, "c": 0.01],
            card: ["a": 0.01, "b": 0.0127, "c": 0.01],
            cardRule: .loudest)

        let plus = mirror.interpret(burst: ["a": 0.003342, "b": 0.004244, "c": 0.003342],
                                    shown: ["a": 0.01, "b": 0.0127, "c": 0.01], now: 2431.3)
        #expect(plus?.kind == .button(up: true))
        #expect(close(plus?.systemLevel, 0.07))
        mirror.observe(["a": 0.0324, "b": 0.0351, "c": 0.0324], duringCommand: true)
        mirror.observe(["a": 0.0324, "b": 0.0351, "c": 0.0324], duringCommand: false)

        let jump = mirror.interpret(burst: ["a": 0.021961, "b": 0.027890, "c": 0.021961],
                                    shown: ["a": 0.0319, "b": 0.0346, "c": 0.0319], now: 2433.6)
        #expect(jump?.kind == .slider)
        #expect(jump?.hypothesis == "suivie")
        #expect(close(jump?.intended, 0.46))
        mirror.observe(["a": 0.0222, "b": 0.0249, "c": 0.0222], duringCommand: true)
        mirror.observe(["a": 0.0222, "b": 0.0249, "c": 0.0222], duringCommand: false)

        for now in [2435.8, 2449.25] {
            let zero = mirror.interpret(burst: all(0), shown: all(0.01), now: now)
            #expect(zero?.kind == .button(up: false))
            mirror.observe(all(0.01), duringCommand: true)
            pushed(&mirror, 0.01)
        }

        // 20:40:50 et 20:40:52 : « − » engagés à 0 sans rappel. Puis le « + ».
        let up = mirror.interpret(burst: all(0.0625), shown: all(0.01), now: 2457.6)
        #expect(up?.kind == .button(up: true), "\(up?.summary ?? "nil")")
        #expect(close(up?.systemLevel, 0.0625))
    }

    /// Le 0 d'iOS ne reste l'affiché que tant que rien d'autre n'est adopté :
    /// remonté à 0,5 depuis l'app, un glissement vers 0,0625 n'est pas un « + ».
    @Test("Remonté ailleurs après un zéro, le 0 d'iOS n'est plus l'affiché")
    func aZeroIsForgottenOnceRaisedElsewhere() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.05)
        let zero = mirror.interpret(burst: all(0), shown: all(0.05), now: 100)
        #expect(zero?.kind == .button(up: false))
        mirror.observe(all(0.01), duringCommand: true)
        pushed(&mirror, 0.5)

        let drag = mirror.interpret(burst: all(0.0625), shown: all(0.5), now: 110)
        #expect(drag?.kind != .button(up: true))
    }

    /// Un appui qui suit de près un glissement reste un appui : sans quoi un
    /// seul appui mal lu faisait lire tous les suivants comme des glissements.
    @Test("Un appui juste après un glissement est encore relu comme un appui")
    func aPressRightAfterASlideIsStillAPress() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.2)
        let slide = mirror.interpret(burst: all(0.23), shown: all(0.2), now: 100)
        #expect(slide?.kind == .slider)
        mirror.observe(all(0.2305), duringCommand: true)

        // 0,4 s plus tard, iOS part de son dernier G : 0,23 + 1/16.
        let plus = mirror.interpret(burst: all(0.2925), shown: all(0.23), now: 100.4)
        #expect(plus?.kind == .button(up: true))
    }

    /// Une lecture suivie bornée à 1 tombe toujours sur un centième : ce n'est
    /// pas une raison de la croire loin du doigt.
    @Test("Une lecture bornée à 1 ne passe pas pour un centième du Centre de contrôle")
    func aClampedReadingIsNotAHundredth() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.45, 0.1214)
        let reading = mirror.interpret(burst: all(0.5), shown: all(0.1214), now: 100)
        #expect(reading == nil)
    }

    /// Remonté ailleurs à des niveaux inégaux au-dessus du plafond : si iOS prend
    /// le plus bas (comme à 18:46:44), le miroir, qui prend le plus haut, est
    /// décalé de tout l'écart — 3,4 % à 0,2094 / 0,2025. L'appui reste un appui.
    @Test("Monté ailleurs à des niveaux inégaux, un appui reste un appui")
    func unevenRiseStillReadsAPress() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.15)
        mirror.observe(["a": 0.2094, "b": 0.2025, "c": 0.2094], duringCommand: false)
        #expect(close(mirror.slack, (0.2094 - 0.2025) / 0.2094, 0.000001))

        // iOS : plafond 0,2025, G = 0,2094 + 1/16 = 0,2719.
        let reading = mirror.interpret(
            burst: ["a": 0.2094 * 0.2719 / 0.2025, "b": 0.2719, "c": 0.2094 * 0.2719 / 0.2025],
            shown: ["a": 0.2094, "b": 0.2025, "c": 0.2094], now: 100)
        #expect(reading?.kind == .button(up: true))
        #expect(close(mirror.ceiling, 0.2719, 0.000001))
    }

    /// Baissé ailleurs de 0,20 à 0,18 : iOS tient 0,9. Le doigt monte à 0,23,
    /// iOS demande 0,207. Lue « saine », parce que plus proche du doigt, cette
    /// rafale remettait le rapport du miroir à 1, et l'appui suivant, décalé de
    /// 10 %, partait en glissement.
    @Test("Un glissement ne remet pas à 1 le rapport qu'iOS garde")
    func aSlideKeepsTheTrackedRatio() {
        var mirror = GroupVolumeMirror()
        pushed(&mirror, 0.20, 0.18)

        let slide = mirror.interpret(burst: all(0.207), shown: all(0.18), now: 100)
        #expect(slide?.kind == .slider)
        #expect(slide?.hypothesis == "suivie")
        #expect(close(slide?.intended, 0.23, 0.001))
        mirror.observe(all(0.2305), duringCommand: true)
        pushed(&mirror, 0.2305)

        // 0,207 × (0,2305 + 1/16) / 0,23
        let plus = mirror.interpret(burst: all(0.2637), shown: all(0.23), now: 102.5)
        #expect(plus?.kind == .button(up: true))
    }

    @Test("Des niveaux inégaux sans règle connue : un glissement n'est pas relu")
    func unevenSlideIsLeftToTheSystem() {
        var mirror = GroupVolumeMirror()
        let shown = ["a": 0.2, "b": 0.4, "c": 0.6]
        mirror.observe(shown, duringCommand: false)
        let reading = mirror.interpret(burst: ["a": 0.21, "b": 0.42, "c": 0.63],
                                       shown: shown, now: 100)
        #expect(reading == nil)
    }

    @Test("Ce que Milō confirme se rend à l'identique, écart compris")
    func aConfirmedLevelKeepsItsOffset() {
        let kept = MiloAPIClient.displayedLevel(optimistic: nil, reported: 0.1839, confirmed: 0.1839)
        #expect(close(kept, 0.1844, 0.000001))
        let fromTheApp = MiloAPIClient.displayedLevel(optimistic: nil, reported: 0.1844, confirmed: 0.1839)
        #expect(close(fromTheApp, 0.1844, 0.000001))
        let elsewhere = MiloAPIClient.displayedLevel(optimistic: nil, reported: 0.3, confirmed: 0.1839)
        #expect(close(elsewhere, 0.3, 0.000001))
    }
}
