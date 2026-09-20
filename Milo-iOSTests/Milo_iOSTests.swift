import Testing
import Foundation
@testable import Milo_iOS

/// Ce que le curseur global du Centre de contrôle demande, et ce qu'on en fait.
///
/// Le système envoie un facteur commun sur toutes les enceintes, mais ce facteur
/// porte des niveaux absolus : ce sont eux qui disent où le doigt a laissé la
/// poignée. Ces tests figent ça, parce que la relecture du facteur comme un gain
/// a été essayée le 20/09/2026 et rendait les extrémités inatteignables.
struct VolumeGestureTests {

    let limits = (min: -78.0, max: -8.0)

    @Test("On applique le niveau demandé, pas un dérivé du facteur")
    func targetIsTheRequestedLevel() throws {
        // Mesuré : le système demande 0.4265 / 0.4300 / 0.4342, soit -47,9 dB
        // en moyenne sur une plage -78…-8. La lecture en gain donnait -54,7.
        let asked = [0.4264775, 0.4300078, 0.43415198].map { -78 + $0 * 70 }

        let target = try #require(MiloAPIClient.globalTarget(targetDBs: asked, limits: limits))

        #expect(abs(target - (-47.885)) < 0.01)
    }

    @Test("Les extrémités sont atteignables")
    func extremesAreReachable() throws {
        let top = try #require(MiloAPIClient.globalTarget(targetDBs: [-8, -8, -8], limits: limits))
        let bottom = try #require(MiloAPIClient.globalTarget(targetDBs: [-78, -78, -78], limits: limits))

        #expect(top == limits.max)
        #expect(bottom == limits.min)
    }

    @Test("Hors bornes, on borne")
    func targetIsClamped() throws {
        #expect(try #require(MiloAPIClient.globalTarget(targetDBs: [0], limits: limits)) == limits.max)
        #expect(try #require(MiloAPIClient.globalTarget(targetDBs: [-200], limits: limits)) == limits.min)
    }

    @Test("Sans enceinte, rien à viser")
    func emptyIsRejected() {
        #expect(MiloAPIClient.globalTarget(targetDBs: [], limits: limits) == nil)
    }

    @Test("Trois rapports concordants sur trois enceintes : geste global")
    func concordantRatiosAreGlobal() {
        // Les vrais chiffres du 20/09 : 1,90000 / 1,90000 / 1,90021.
        #expect(MiloAPIClient.isGlobalGesture(ratios: [1.90000, 1.90000, 1.90021],
                                              touched: 3, deviceCount: 3))
    }

    @Test("Une seule enceinte touchée : curseur individuel")
    func singleSpeakerIsNotGlobal() {
        #expect(!MiloAPIClient.isGlobalGesture(ratios: [1.9], touched: 1, deviceCount: 3))
    }

    @Test("Des rapports qui divergent ne sont pas un geste global")
    func divergentRatiosAreNotGlobal() {
        #expect(!MiloAPIClient.isGlobalGesture(ratios: [1.9, 1.5, 1.9],
                                               touched: 3, deviceCount: 3))
    }

    @Test("Une enceinte seule n'a aucun équilibre à préserver")
    func singleDeviceStaysPerClient() {
        #expect(!MiloAPIClient.isGlobalGesture(ratios: [1.9], touched: 1, deviceCount: 1))
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
