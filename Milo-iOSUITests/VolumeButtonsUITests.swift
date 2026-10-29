import XCTest

// Les boutons de volume n'existent pas dans le simulateur : sans cette garde,
// la cible de tests UI ne compile plus pour lui.
#if !targetEnvironment(simulator)

/// Appuie sur les vrais boutons de volume de l'iPhone, écran verrouillé,
/// pour que le Mac mesure côté Milō ce que chaque appui produit.
///
/// Verrouillé et non simplement en arrière-plan : déverrouillé, iOS envoie les
/// boutons au haut-parleur de l'iPhone (mesuré le 12/10/2026, `route: Speaker`)
/// et Milō ne voit rien. `XCUIDevice.Button.volumeUp/Down` n'existe que sur un
/// appareil physique, et le verrou vient d'un doigt : ni `pressLockButton` ni
/// `pymobiledevice3 diagnostics sleep` ne verrouillent sous iOS 27. Le test ne vérifie rien lui-même : il horodate ses appuis
/// dans la sortie, et le Mac les confronte à `/api/volume/state`.
final class VolumeButtonsUITests: XCTestCase {

    @MainActor
    func testVolumeButtonsReachMilo() throws {
        XCUIDevice.shared.press(.home)
        // Le test ne sait pas verrouiller : `pressLockButton` est ignoré sur
        // iOS 27 (testmanagerd attend « ButtonEventsCompleted » et abandonne).
        // La mise en veille par USB non plus. Vingt secondes pour le doigt.
        print("VOLBENCH WAITING_LOCK \(Date().timeIntervalSince1970)")
        sleep(20)

        // Espacés : la carte a le temps d'afficher notre rendu entre deux appuis.
        for _ in 0..<5 { press(.volumeUp) }
        sleep(3)
        for _ in 0..<5 { press(.volumeDown) }
        sleep(3)
        // Rapprochés, comme un doigt : la carte affiche encore ce qu'iOS vient de
        // poser, et c'est de là qu'il calcule l'appui suivant (12/10, 22:36:14 :
        // dix « + » bloqués vers -77 dB).
        for _ in 0..<5 { press(.volumeUp, pause: 0.25) }
        sleep(3)
        for _ in 0..<5 { press(.volumeDown, pause: 0.25) }
        sleep(3)
    }

    /// Le premier appui après une pause : le push de Milō arrive plus d'une
    /// seconde après le cran, et c'est lui qui faisait perdre au modèle son
    /// rapport (29/10, 15:11:52 : un « + » relu « − »). Dix appuis, pour que
    /// la trace de l'extension (60 lignes) les garde tous.
    @MainActor
    func testFirstPressAfterAPause() throws {
        XCUIDevice.shared.press(.home)
        print("VOLBENCH WAITING_LOCK \(Date().timeIntervalSince1970)")
        sleep(20)

        for button: XCUIDevice.Button in [.volumeUp, .volumeDown, .volumeUp, .volumeUp,
                                          .volumeDown, .volumeDown] {
            press(button, pause: 4)
        }
        press(.volumeUp, pause: 0.4)
        press(.volumeUp, pause: 4)
        press(.volumeDown, pause: 0.4)
        press(.volumeDown, pause: 4)
    }

    /// Le volume a changé ailleurs pendant que l'iPhone était déverrouillé :
    /// le premier appui verrouillé part-il de notre rendu, ou de ce que la
    /// carte montrait au dernier verrouillage (29/10, 17:06:59 : un « − »
    /// engagé depuis 0,9615 quand Milō était à 0,2937) ?
    @MainActor
    func testPressesAfterAnExternalChange() throws {
        XCUIDevice.shared.press(.home)
        print("VOLBENCH WAITING_LOCK \(Date().timeIntervalSince1970)")
        sleep(25)

        for button: XCUIDevice.Button in [.volumeUp, .volumeUp, .volumeDown, .volumeDown] {
            press(button, pause: 4)
        }
    }

    /// Le même, volume baissé ailleurs : le plafond d'iOS reste en haut, et
    /// c'est un « − » qui part le premier.
    @MainActor
    func testPressesAfterAnExternalDecrease() throws {
        XCUIDevice.shared.press(.home)
        print("VOLBENCH WAITING_LOCK \(Date().timeIntervalSince1970)")
        sleep(25)

        for button: XCUIDevice.Button in [.volumeDown, .volumeDown, .volumeUp, .volumeUp] {
            press(button, pause: 4)
        }
    }

    private func press(_ button: XCUIDevice.Button, pause: TimeInterval = 1.5) {
        let name = button == .volumeUp ? "UP" : "DOWN"
        print("VOLBENCH PRESS \(name) \(Date().timeIntervalSince1970)")
        XCUIDevice.shared.press(button)
        Thread.sleep(forTimeInterval: pause)
    }
}
#endif
