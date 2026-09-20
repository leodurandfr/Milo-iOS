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
