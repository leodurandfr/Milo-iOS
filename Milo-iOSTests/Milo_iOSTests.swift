import Testing
import Foundation
@testable import Milo_iOS

/// Ce que le curseur global du Centre de contrôle demande, et ce qu'on en fait.
///
/// Le système ne pose pas un niveau : il multiplie les nôtres par un facteur
/// commun. Ces tests figent la traduction de ce facteur, parce que c'est elle
/// qui décide de ce qu'on entend — et parce qu'elle ne se vérifie pas au doigt
/// sans un vrai iPhone et un vrai geste.
struct VolumeGestureTests {

    let limits = (min: -78.0, max: -8.0)

    @Test("Le facteur se lit comme un gain, pas comme une position")
    func ratioIsReadAsGain() throws {
        // Mesuré le 20/09/2026 : trois enceintes vers -57 dB, le système envoie
        // ×1,9. Lu sur l'échelle en dB ça vaudrait +18,9 dB ; lu comme un gain,
        // 20·log₁₀(1,9) = +5,58 dB.
        let bases = [-57.336, -56.331, -57.439]
        let mean = bases.reduce(0, +) / 3

        let target = try #require(
            MiloAPIClient.globalTarget(baseDBs: bases, ratio: 1.9, limits: limits))

        #expect(abs((target - mean) - 5.575) < 0.01)
    }

    @Test("Le même geste vaut le même écart, où qu'on parte")
    func deltaIsIndependentOfStartingPoint() throws {
        // C'est la propriété qui justifie le choix : sur l'échelle en dB, le
        // même ×1,9 valait +18,9 dB en bas et +37,8 dB une octave plus haut.
        let low = try #require(MiloAPIClient.globalTarget(baseDBs: [-60], ratio: 1.9, limits: limits))
        let high = try #require(MiloAPIClient.globalTarget(baseDBs: [-30], ratio: 1.9, limits: limits))

        #expect(abs((low + 60) - (high + 30)) < 0.001)
    }

    @Test("Aller et retour revient au point de départ")
    func gestureIsReversible() throws {
        let start = -50.0
        let up = try #require(MiloAPIClient.globalTarget(baseDBs: [start], ratio: 1.9, limits: limits))
        let back = try #require(MiloAPIClient.globalTarget(baseDBs: [up], ratio: 1 / 1.9, limits: limits))

        #expect(abs(back - start) < 0.001)
    }

    @Test("Les bornes de l'opérateur s'appliquent")
    func targetIsClamped() throws {
        let tooLoud = try #require(MiloAPIClient.globalTarget(baseDBs: [-20], ratio: 100, limits: limits))
        let tooQuiet = try #require(MiloAPIClient.globalTarget(baseDBs: [-70], ratio: 0.001, limits: limits))

        #expect(tooLoud == limits.max)
        #expect(tooQuiet == limits.min)
    }

    @Test("Un facteur nul ou négatif n'est pas un geste")
    func nonPositiveRatioIsRejected() {
        #expect(MiloAPIClient.globalTarget(baseDBs: [-50], ratio: 0, limits: limits) == nil)
        #expect(MiloAPIClient.globalTarget(baseDBs: [], ratio: 1.9, limits: limits) == nil)
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
