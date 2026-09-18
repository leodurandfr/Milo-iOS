//
//  SceneDelegate.swift
//  oakOS-iOS
//
//  Created by Léo Durand on 06/07/2025.
//

import UIKit
import WidgetKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?


    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard let _ = (scene as? UIWindowScene) else { return }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Forcer une reconnexion immédiate au retour du background
        if let vc = window?.rootViewController as? ViewController {
            vc.handleReturnFromBackground()
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        guard let vc = window?.rootViewController as? ViewController else { return }

        // Afficher l'overlay logo pour masquer le contenu dans l'app switcher
        // et éviter le flash d'erreur au retour
        vc.enterBackground()

        // Rafraîchir le widget pour que le volume soit à jour sur l'écran d'accueil.
        // Sauté au lancement à froid, où UIKit émet cet évènement avant même le
        // premier passage au premier plan : réveiller l'extension n'apprendrait rien.
        guard vc.hasCompletedFirstLoad else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }


}

