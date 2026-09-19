//
//  AppDelegate.swift
//  oakOS-iOS
//
//  Created by Léo Durand on 06/07/2025.
//

import UIKit
import WidgetKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {



    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Le token du widget est émis par WidgetKit, mais il est lisible d'ici :
        // l'app est le seul des deux processus dont on sait qu'il vient de
        // tourner. L'extension, elle, n'est réveillée qu'au bon vouloir du
        // système, et attendre son prochain passage retarderait d'autant
        // l'enregistrement chez Milō. L'appel est idempotent et ne coûte rien
        // une fois le token confirmé.
        // Inscrit l'appareil auprès d'APNs. Sans cet appel, aucun topic de ce
        // bundle n'existe côté Apple, et WidgetKit n'a pas de quoi frapper son
        // propre token — ce qui se voit comme une absence totale, sans erreur.
        // N'ouvre aucune autorisation et n'affiche rien : demander la permission
        // d'alerter l'utilisateur relève de UserNotifications, dont on n'a pas
        // besoin ici puisque le push widget ne notifie personne.
        application.registerForRemoteNotifications()

        if #available(iOS 26.0, *) {
            Task { await MiloAPIClient.reconcileWidgetPushToken() }
        }

        // Sans ce token, Milō ne peut ouvrir aucune session Now Playing quand
        // l'app ne tourne pas — c'est-à-dire presque toujours.
        if #available(iOS 27.0, *) {
            MiloPushToStart.begin()
            // Chemin local : pendant que l'app tourne, la session n'a pas besoin
            // d'APNs. Elle passe quand même par l'extension, que le système
            // appelle pour la construire — c'est donc aussi le seul essai qui
            // dise si cette extension est utilisable.
            MiloNowPlayingBridge.startPump()
        }

        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }

    // MARK: - APNs

    /// Le token de l'app elle-même, dont on n'a pas l'usage : c'est WidgetKit qui
    /// fournit celui du widget. On ne le retient que pour tracer que
    /// l'inscription a bien abouti.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        UserDefaults(suiteName: MiloAPIClient.appGroupID)?
            .set("ok", forKey: "milo_apns_registration")

        // Le token du widget peut n'avoir été frappé qu'une fois l'inscription
        // aboutie : c'est le moment de redemander.
        if #available(iOS 26.0, *) {
            Task { await MiloAPIClient.reconcileWidgetPushToken() }
        }
    }

    /// Échec d'inscription. Consigné plutôt que tu : sans cette trace, un
    /// provisioning incomplet est indiscernable d'un token qui tarde.
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults(suiteName: MiloAPIClient.appGroupID)?
            .set("fail: \(error.localizedDescription)", forKey: "milo_apns_registration")
    }

}
