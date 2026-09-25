import Foundation
import NowPlaying

/// La règle d'affichage de la carte, séparée de la session qu'elle commande.
///
/// Hors de `MiloNowPlayingBridge`, qui est `@available(iOS 27, *)` parce que
/// `RemoteMediaSession` l'exige — alors que décider s'il y a quelque chose à
/// montrer ne tient qu'à un dictionnaire. La séparation n'est pas cosmétique :
/// le macro `@Test` refuse une fonction moins disponible que la cible de test,
/// si bien que la règle restait sans test tant qu'elle vivait derrière cette
/// barrière — et c'est une règle qui décide seule si la carte de l'écran
/// verrouillé existe.
enum MiloCardVisibility {

    /// Pourquoi il n'y a rien à montrer — ou `nil` quand il y a quelque chose.
    ///
    /// La règle est celle du fil (« Développeurs : le fil », §9), la même que
    /// Milō applique quand il construit ses notifications, dans cet ordre :
    ///
    /// - **changement de source en cours** (`switching`) : la carte **tient**.
    ///   Rien n'est prêt pendant ce battement, et fermer ferait disparaître
    ///   puis réapparaître la carte à chaque bascule ;
    /// - **aucune source** : la carte se ferme ;
    /// - **la session ou la reprise porte un titre** : la carte vit — en
    ///   lecture, en pause, ou arrêtée sur ce qu'une pression sur play
    ///   reprendrait ;
    /// - sinon la carte se ferme : il n'y a rien à nommer.
    ///
    /// « Porte un titre » est `MiloAudioState.shown`, lu dans le fichier que
    /// l'app partage octet pour octet avec Milo-Mac : la carte de l'écran
    /// verrouillé et la ligne de la barre des menus ne peuvent pas diverger sur
    /// la question.
    ///
    /// Ce qui a changé avec le fil : une source **active** ne garde plus sa
    /// carte sans titre. Le fil publie désormais la phase elle-même, et une
    /// session sans titre est une session qui n'a rien à afficher — AirPlay en
    /// temps réel, un Bluetooth sans lecteur, le Mac. Milō n'ouvre pas de carte
    /// pour elles ; l'app n'en garde pas non plus.
    static func nothingToShow(in state: MiloAudioState) -> String? {
        if state.switching { return nil }
        if state.source != "none", state.shown != nil { return nil }

        // Le verdict a plusieurs moitiés, et une trace qui n'en porte qu'une ne
        // dit pas laquelle a fermé la carte.
        let phase = state.session.map(\.phase.rawValue) ?? "sans session"
        return "\(state.source)/\(state.service.rawValue)/\(phase)/sans titre"
    }
}

/// Ouvre et entretient la session Now Playing pendant que l'app tourne.
///
/// C'est le chemin **sans APNs** : `RemoteMediaSession.update(_:)` est un appel
/// local, et tant que l'app est au premier plan il n'y a aucune raison de passer
/// par Apple pour un état qu'on peut lire directement sur le LAN.
///
/// Le push reste indispensable pour la suite — quand l'app est tuée, seule
/// l'extension réveillée par APNs peut entretenir la session. Mais les deux
/// chemins aboutissent au même endroit : le système demande à l'extension de
/// construire la session, ici comme là.
@available(iOS 27, *)
@MainActor
enum MiloNowPlayingBridge {

    private static var session: RemoteMediaSession<MiloSessionAttributes>?

    /// Trace du dernier essai, lisible depuis le Mac via le conteneur de l'app.
    /// Sans elle, un `start` refusé est indiscernable d'un `start` jamais tenté.
    private static let statusKey = "milo_nowplaying_status"

    private static var pump: Task<Void, Never>?

    /// Les sessions dont on a constaté qu'elles refusent leurs `update`.
    ///
    /// Un ensemble, et pas un seul identifiant : `sessions()` peut en énumérer
    /// plusieurs mortes à la fois, et n'en écarter qu'une ferait reprendre la
    /// suivante au tour d'après. Vidé dès qu'un `update` aboutit — un
    /// identifiant écarté pour toujours interdirait de reprendre une session
    /// que le système aurait légitimement rouverte sous le même nom.
    private static var disowned: Set<String> = []

    /// Ce qui, dans les attributs, change réellement ce qui est affiché.
    private static var lastSignature = ""

    /// Dernière position connue, l'instant qu'elle décrivait, et si ça jouait.
    /// Sert uniquement à `positionJumped(_:)`.
    private static var lastElapsed: TimeInterval?
    private static var lastCapturedAt = Date.distantPast
    private static var lastWasPlaying = false

    /// Au-delà de trois secondes, l'écart ne s'explique plus par le temps qui
    /// passe ni par la gigue du réseau.
    private static let seekTolerance: TimeInterval = 3

    /// La position a-t-elle bougé autrement qu'en avançant toute seule ?
    ///
    /// La position est exclue de `displaySignature`, et c'est justifié : elle
    /// change en permanence, et l'annoncer à chaque passe ferait reconstruire la
    /// session toutes les deux secondes pour ne rien dire de neuf.
    ///
    /// Mais un `seek` fait **ailleurs** — depuis l'app, l'écran de Milō, un
    /// autre client — la déplace d'un coup sans toucher à aucun autre champ.
    /// Rien ne l'annonçait, et la tête de lecture continuait d'interpoler depuis
    /// un horodatage périmé jusqu'au changement de piste. On compare donc la
    /// position reçue à celle qu'on extrapolait.
    ///
    /// **Met à jour son propre état de suivi** : à appeler exactement une fois
    /// par passe, et avant toute sortie anticipée.
    private static func positionJumped(_ a: MiloSessionAttributes) -> Bool {
        defer {
            lastElapsed = a.elapsedTime
            lastCapturedAt = a.capturedAt
            lastWasPlaying = a.isPlaying
        }
        guard let previous = lastElapsed else { return false }

        // Un flux n'a pas de tête de lecture : `duration` y vaut 0 et
        // `elapsedTime` reste à zéro pour toujours. L'extrapolation, elle,
        // continue d'avancer — si bien que toute passe un peu espacée
        // (arrière-plan, réseau lent) serait lue comme un saut et
        // reconstruirait la session pour rien, exactement ce que la signature
        // est là pour éviter. Rien à comparer, donc rien à annoncer.
        guard (a.currentTrack?.duration ?? 0) > 0 else { return false }

        // À l'arrêt, rien ne doit avoir avancé. Une bascule lecture/pause change
        // déjà la signature, donc elle pousse de toute façon.
        let advance = lastWasPlaying ? a.capturedAt.timeIntervalSince(lastCapturedAt) : 0
        return abs(a.elapsedTime - (previous + advance)) > seekTolerance
    }

    private static func displaySignature(_ a: MiloSessionAttributes) -> String {
        let track = a.currentTrack
        let speakers = a.devices
            .map { "\($0.id)=\(Int(($0.volume * 1000).rounded()))" }
            .joined(separator: ",")
        return [
            a.isPlaying ? "1" : "0",
            track?.id ?? "-",
            track?.title ?? "-",
            track?.artist ?? "-",
            track?.album ?? "-",
            track?.artworkURL ?? "-",
            String(Int((track?.duration ?? 0).rounded())),
            speakers
        ].joined(separator: "|")
    }

    /// Entretient la session tant que l'app est au premier plan.
    ///
    /// Sans ça, la session gardait ce qui était vrai au lancement : on voyait
    /// encore la piste Spotify d'avant pendant que la bibliothèque musicale
    /// jouait.
    ///
    /// Cette boucle ne tient que pendant que l'app est ouverte, et elle s'arrête
    /// dès qu'elle ne l'est plus — interroger Milō toutes les deux secondes
    /// depuis l'arrière-plan ne servirait qu'à vider la batterie. Le relais,
    /// c'est le push : Milō pousse ses `update` à la session, et c'est ce qui
    /// tient l'écran verrouillé. Tant que ce relais était muet, l'arrêt de cette
    /// boucle *était* le gel de l'affichage — voir `reconcileSession`, qui est
    /// la moitié de ce qui l'empêchait de fonctionner.
    ///
    /// `startPump` part de **deux** endroits — `didFinishLaunching` et
    /// `sceneDidBecomeActive` — et les deux se suivent de près au démarrage à
    /// froid. Annuler la boucle précédente ne suffit pas : l'annulation n'arrête
    /// pas un `refresh()` déjà engagé au-delà de ses `await`, si bien que deux
    /// passes pouvaient se chevaucher, et se disputer la session qu'elles
    /// tiennent.
    ///
    /// La nouvelle boucle attend donc que l'ancienne ait vraiment rendu la main
    /// avant de commencer. `refresh()` n'est jamais réentrant.
    static func startPump() {
        let previous = pump
        // Annulée ici, de façon synchrone, et pas depuis la nouvelle tâche : un
        // `stopPump()` immédiat annulerait celle-ci avant qu'elle n'exécute sa
        // première ligne, et l'ancienne boucle tournerait alors pour toujours.
        previous?.cancel()

        pump = Task {
            await previous?.value

            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // À côté de la boucle, pas dedans : c'est un dépôt d'avance pour
        // l'extension, dont rien n'attend le résultat. Il se borne lui-même à un
        // passage toutes les dix minutes.
        Task { await MiloAPIClient.primeFavoriteStationArtwork() }
    }

    static func stopPump() {
        pump?.cancel()
        // `pump` n'est **pas** remis à nil : c'est la référence dont le prochain
        // `startPump` a besoin pour attendre que cette boucle-ci ait vraiment
        // rendu la main. L'oublier ici rouvrait la fenêtre de chevauchement à
        // chaque aller-retour arrière-plan → premier plan, qui est de loin le
        // chemin le plus fréquent — bien plus que le double départ au lancement.
        // Une tâche terminée ne coûte que sa référence.
    }

    static func refresh() async {
        // Ce que l'extension n'a pas pu enregistrer elle-même — voir
        // `MiloAPIClient.pendingSessionTokenKey`. Sans token, Milō ne peut pas
        // pousser ses `update` à la session, la déclare inadressable, et en
        // ouvre une rivale que le système n'affiche pas.
        await MiloAPIClient.drainPendingSessionToken()

        // Ne rien changer si Milō est injoignable : une coupure réseau n'est
        // pas une fin de lecture, et effacer la carte à chaque paquet perdu la
        // ferait clignoter. C'est l'opposé de « rien à montrer », juste en
        // dessous, qui doit au contraire l'effacer — les deux se lisaient comme
        // « pas d'attributs » et menaient au même `return`, d'où la carte figée
        // sur la piste d'avant à chaque changement de source.
        guard let audioData = try? await MiloAPIClient.get(path: "/api/audio/state") else {
            note("pas d'état exploitable depuis Milō")
            return
        }

        // Un état que cette version ne sait pas lire — une valeur inconnue de
        // `service` ou de `phase`, un champ manquant — ne change rien non plus :
        // c'est un désaccord de contrat avec Milō, pas une fin de lecture. Tracé
        // à part, parce que « injoignable » ne se corrige pas pareil.
        let state: MiloAudioState
        do {
            state = try MiloAudioState.decode(audioData)
        } catch {
            note("état illisible : \(error)")
            return
        }

        if let seen = MiloCardVisibility.nothingToShow(in: state) {
            // Réconcilier d'abord : on ferme ce que le système tient vraiment,
            // pas ce que l'app croit tenir.
            await reconcileSession()
            guard session != nil else {
                // Passage muet jusqu'ici, et c'est ce qui a rendu la panne
                // illisible : le statut gardait son « update ok » d'avant, si
                // bien qu'une app qui tournait sans rien trouver à fermer
                // ressemblait trait pour trait à une app qui ne tournait pas.
                note("rien à montrer (\(seen)), aucune session tenue")
                return
            }
            await endSession(reason: seen)
            return
        }

        // Réconcilier à **chaque** passe, et ici plutôt qu'après la
        // construction.
        //
        // L'app se contentait d'adopter quand elle ne tenait rien, puis gardait
        // sa prise pour toujours. Milō, lui, termine et rouvre des sessions
        // selon ce qui joue : l'app restait alors accrochée à une session morte
        // de son côté pendant que la vivante, invisible, recevait tout.
        await reconcileSession()

        // **Décider avant de payer.** Construire les attributs coûte deux
        // requêtes de plus — `/api/volume/state` et `/api/multiroom/state`,
        // dans `buildDevices` — plus le dépôt de la pochette. Tant qu'une
        // source arrêtée rendait « rien à montrer », ce chemin ne s'ouvrait que
        // pour quelque chose qui jouait ; depuis qu'elle garde sa carte, il
        // s'ouvre aussi quand personne ne tient de session et n'en ouvrira, et
        // ces trois requêtes toutes les deux secondes partaient alors à la
        // poubelle — pour toute la durée où l'app reste au premier plan.
        let isPlaying = state.session?.phase == .playing
        guard session != nil || mayOpenSession(isPlaying: isPlaying) else {
            note("aucune session, et rien à ouvrir")
            return
        }

        let attributes = await buildAttributes(from: state)

        // Ne pousser que ce qui change l'affichage.
        //
        // Pousser toutes les deux secondes faisait reconstruire la session à
        // chaque fois — mesuré, quatre fois en deux secondes — et chaque
        // reconstruction jette l'objet `Artwork` en cours avec son
        // téléchargement : la pochette n'avait jamais le temps d'arriver.
        //
        // La position n'entre pas dans la signature, délibérément : elle change
        // en permanence, et `MediaPlaybackSnapshot` porte déjà un horodatage à
        // partir duquel le système interpole. L'annoncer à chaque seconde ne
        // dirait rien de plus et coûterait tout.
        // `positionJumped` met à jour son propre suivi, et n'est donc appelé
        // que sur les passes qui construisent vraiment des attributs. Les
        // sorties au-dessus n'en produisent aucun : il n'y a rien à comparer,
        // et `endSession` remet `lastElapsed` à nil de son côté.
        let jumped = positionJumped(attributes)
        let signature = displaySignature(attributes)

        // Personne n'a ouvert ? On ouvre, si quelque chose joue.
        if session == nil {
            await openSession(attributes)
        }

        guard let session else {
            note("aucune session, et rien à ouvrir")
            return
        }

        // Ne pousser que ce qui change l'affichage.
        //
        // Pousser toutes les deux secondes faisait reconstruire la session à
        // chaque fois — mesuré, quatre fois en deux secondes — et chaque
        // reconstruction jette l'objet `Artwork` en cours avec son
        // téléchargement : la pochette n'avait jamais le temps d'arriver.
        //
        // La position n'entre pas dans la signature, délibérément : elle change
        // en permanence, et `MediaPlaybackSnapshot` porte déjà un horodatage à
        // partir duquel le système interpole. L'annoncer à chaque seconde ne
        // dirait rien de plus et coûterait tout.
        if signature == lastSignature, !jumped { return }

        do {
            // L'identifiant est celui de la session, jamais le nôtre :
            // `update(_:)` refuse des attributs qui n'en portent pas le sien.
            try await session.update(attributes.with(id: session.id))
            lastSignature = signature
            disowned.removeAll()
            note("update ok (\(session.id))")
        } catch {
            // Une session que Milō ou le système a close continue de refuser
            // chaque `update`. On la lâche, et son identifiant est retenu :
            // `sessions()` peut continuer de l'énumérer, et la réconciliation
            // la reprendrait au tour suivant — on refuserait alors en boucle.
            Self.session = nil
            disowned.insert(session.id)
            lastSignature = ""
            note("update refusé, session lâchée : \(error)")
        }
    }

    /// Aligne ce qu'on tient sur ce que le système tient, et réclame l'écran.
    ///
    /// **L'app n'ouvre plus de session.** Elle l'a fait, et c'était la rivalité
    /// qu'on croyait supprimer : mesuré le 19/09/2026 à 17:46:30, deux sessions
    /// vivantes en même temps — `9AA6ACC5`, ouverte ici, principale et donc
    /// seule visible, mais que Milō avait déjà terminée de son côté ; et
    /// `7e148d0e`, ouverte par le push de Milō, qui recevait tous les `update`
    /// sans que personne ne les voie. Une session ouverte par push ne peut pas
    /// réclamer l'écran elle-même — `requestToBecomeSystemPrimary()` exige le
    /// premier plan, et quand elle naît l'app dort. La seule qui pouvait le
    /// faire était donc celle qu'il ne fallait pas.
    ///
    /// Milō est propriétaire du cycle de vie ; l'app ne fait que suivre, et
    /// pousse ses `update` sur le LAN tant qu'elle est ouverte parce que c'est
    /// plus rapide qu'un aller-retour par Apple. Quand rien n'est ouvert, il n'y
    /// a rien à afficher et rien à faire : Milō pousse un `start` dès que la
    /// lecture reprend.
    /// Ferme la session et efface la carte.
    ///
    /// L'app ne possède pas le cycle de vie — Milō ouvre, l'app suit. Mais elle
    /// est la seule à savoir que plus rien ne joue **et** que la carte est
    /// encore là : Milō, lui, a déjà tourné la page. `reportLiveSessions`, appelé
    /// à chaque passe, lui apprend aussitôt que le téléphone ne tient plus rien,
    /// donc le token est retiré au lieu d'être adressé dans le vide.
    private static func endSession(reason: String) async {
        guard let live = session else { return }
        session = nil
        systemHoldsAny = false
        lastSignature = ""
        lastElapsed = nil
        do {
            try await live.end()
            note("session close (\(reason))")
        } catch {
            note("fermeture refusée : \(error)")
        }
    }

    /// Le système tient-il **une** session, même lâchée par l'app ?
    ///
    /// Distinct de `session != nil` : une session écartée dans `disowned` reste
    /// vivante côté système. Ouvrir alors en créerait une seconde — exactement
    /// la panne du 19/09.
    private static var systemHoldsAny = false

    /// Dernière tentative d'ouverture. Sans ce frein, un refus relancerait une
    /// ouverture toutes les deux secondes.
    private static var lastStartAttempt = Date.distantPast
    private static let startRetryDelay: TimeInterval = 10

    /// Ouvre une session quand personne ne l'a fait et que la lecture est en cours.
    ///
    /// **C'est le retour d'un chemin retiré le 19/09/2026, et ce n'est pas un
    /// oubli de l'avoir retiré.** Ce qui avait cassé n'était pas l'ouverture :
    /// c'était d'ouvrir *pendant* que Milō en ouvrait une autre par push. Deux
    /// sessions vivantes, la visible déjà morte côté Milō, l'autre recevant tout
    /// sans être vue.
    ///
    /// Trois gardes, et la première est celle qui manquait alors :
    ///
    /// - **le système ne tient rien** — `sessions()` vide, pas seulement « l'app
    ///   n'en tient pas » ; c'est la distinction qui a coûté la panne ;
    /// - **quelque chose joue** — et depuis qu'une source arrêtée garde sa
    ///   carte, cette garde-là mérite sa propre justification, plus bas ;
    /// - **un essai toutes les dix secondes** au plus.
    ///
    /// Et l'app peut ce que le push ne peut pas : `requestToBecomeSystemPrimary()`
    /// exige le premier plan. Une session née d'un push naît pendant que l'app
    /// dort, donc elle ne peut jamais réclamer l'écran elle-même. Celle-ci, si.
    ///
    /// Ça ne remplace pas le `start` de Milō, qui reste le seul chemin quand
    /// l'app n'a jamais été lancée. Ça couvre le cas où la musique jouait déjà
    /// avant qu'on ouvre l'app — où rien n'ouvrait de session, puisque Milō
    /// n'envoie un `start` que sur un événement de lecture.
    ///
    /// **`isPlaying` reste, et ce n'est pas un oubli depuis que `nothingToShow`
    /// tient la carte sur une source arrêtée.** Ouvrir et ne pas fermer sont
    /// deux droits distincts, et Milō ne s'accorde que le second : son
    /// `_start_session` n'est atteint que sous `_has_active_source`, donc il
    /// n'ouvre jamais pour une source arrêtée, et il ferme celle qui existe au
    /// bout de cinq minutes d'inactivité.
    ///
    /// Laisser passer une source arrêtée ici ferait donc rouvrir, deux secondes
    /// plus tard, la carte que Milō vient de fermer — et pour toujours, la
    /// boucle de premier plan n'ayant aucune expiration à elle. Ce serait
    /// reprendre à Milō le cycle de vie que tout ce fichier lui laisse.
    ///
    /// La carte en pause s'ouvre donc comme avant : pendant que ça jouait. Ce
    /// qui a changé est qu'elle ne se ferme plus à l'arrêt.
    /// Les trois conditions d'une ouverture, lisibles avant d'avoir construit
    /// quoi que ce soit.
    ///
    /// Extraites pour que `refresh()` puisse poser la question avec la seule
    /// `phase` de `/api/audio/state`, sans payer les deux requêtes de
    /// `buildDevices`. Une seule définition : deux réponses divergentes à
    /// « va-t-on ouvrir ? » feraient soit construire pour rien, soit renoncer à
    /// une ouverture légitime.
    private static func mayOpenSession(isPlaying: Bool) -> Bool {
        !systemHoldsAny && isPlaying
            && Date().timeIntervalSince(lastStartAttempt) > startRetryDelay
    }

    private static func openSession(_ attributes: MiloSessionAttributes) async {
        guard mayOpenSession(isPlaying: attributes.isPlaying) else { return }
        lastStartAttempt = Date()

        do {
            // L'identifiant est minté ici : c'est une session à nous, et Milō
            // apprendra son token par l'extension, qui l'enregistre à la
            // construction comme pour n'importe quelle autre.
            let opened = try await RemoteMediaSession.start(
                attributes: attributes.with(id: UUID().uuidString))
            session = opened
            systemHoldsAny = true
            // La signature décrit ce qu'on a poussé ailleurs ; sur une session
            // neuve elle ne vaut rien.
            lastSignature = ""

            // Réclamer l'écran maintenant, tant qu'on est au premier plan.
            try? await opened.requestToBecomeSystemPrimary()
            await MiloAPIClient.reportLiveSessions([opened.id])
            note("session ouverte par l'app (\(opened.id))")
        } catch {
            note("ouverture refusée : \(error)")
        }
    }

    private static func reconcileSession() async {
        let all = (try? await RemoteMediaSession<MiloSessionAttributes>.sessions()) ?? []
        systemHoldsAny = !all.isEmpty

        // Dit à Milō ce que le téléphone tient réellement, **avant** de filtrer.
        //
        // Une session que l'app a lâchée reste vivante côté système ; ce qu'on
        // rapporte ici est l'état de l'appareil, pas la prise de l'app. Filtrer
        // d'abord ferait retirer chez Milō une session bien présente, et la
        // rouvrirait pour rien.
        //
        // C'est la moitié manquante du problème des sessions fantômes : sans ce
        // rapport, un token de session survit à sa session et Milō pousse dans
        // le vide pour toujours. Voir `MiloAPIClient.reportLiveSessions`.
        await MiloAPIClient.reportLiveSessions(all.map(\.id))

        let existing = all.filter { !disowned.contains($0.id) }

        guard let live = existing.first(where: { $0.isSystemPrimary }) ?? existing.first else {
            if session != nil { note("session disparue") }
            session = nil
            return
        }

        if live.id != session?.id {
            session = live
            // La signature décrit ce qu'on a poussé à la session d'avant ; sur
            // une autre elle ne vaut rien, et la garder sauterait la première
            // mise à jour de la nouvelle.
            lastSignature = ""
            note("session adoptée (\(live.id))")
        }

        // Réclamé tant que ce n'est pas obtenu. Une seule demande ne suffit
        // pas : `startPump()` part aussi de `didFinishLaunching`, où la scène
        // n'est pas encore active et où la demande est ignorée sans erreur —
        // c'est ce qui obligeait à lancer l'app **deux** fois pour voir la
        // carte apparaître.
        if !live.isSystemPrimary {
            try? await live.requestToBecomeSystemPrimary()
        }
    }

    /// Ferme la session. Milō décide normalement de sa fin, mais une session
    /// ouverte localement doit pouvoir l'être aussi.
    static func end() async {
        guard let session else { return }
        try? await session.end()
        self.session = nil
    }

    // MARK: - Construction

    /// Ce que Milō dit de lui-même, en trois cas qu'il ne faut surtout pas
    /// confondre.
    ///
    /// `injoignable` et `rienÀMontrer` se lisaient jusqu'ici tous les deux comme
    /// « pas d'attributs » et menaient au même `return` : on ne touchait à rien.
    /// D'où le symptôme — on change de source, plus rien n'est prêt, et la carte
    /// reste figée sur la piste d'avant, en pause. Ce sont deux situations
    /// opposées : une coupure réseau ne doit **rien** changer à l'affichage, une
    /// absence de source doit l'effacer.
    /// Les attributs complets, à partir de l'état déjà lu.
    ///
    /// Ne décide plus s'il y a quelque chose à montrer — `refresh()` l'a
    /// tranché avant d'appeler, et c'est tout l'intérêt : cette fonction coûte
    /// deux requêtes et un dépôt de pochette, et on ne les paie que pour une
    /// session que quelqu'un lira.
    ///
    /// Construits comme Milō construit ses notifications (§9, « Notifications
    /// iOS ») — et c'est la raison d'être de cette fonction : la même session
    /// reçoit les deux, et deux lectures différentes du même état feraient
    /// sauter la carte d'une version à l'autre à chaque aller-retour.
    ///
    /// - `isPlaying` : `phase == playing`, et rien d'autre — ni le chargement,
    ///   ni la pause, ni « connecté » ;
    /// - `elapsedTime` et `timestamp` : l'ancrage tel quel, `position.ms` à
    ///   l'instant `position.at`. Le système interpole à partir de là, comme
    ///   la formule du fil. Sans ancrage (radio, reprise seule), `0` et
    ///   l'heure de construction ;
    /// - la piste vient de la session, sinon de la reprise :
    ///   `MiloAudioState.shown`, la règle même qui décide que la carte existe.
    private static func buildAttributes(from state: MiloAudioState) async -> MiloSessionAttributes {
        let session = state.session
        let anchor = session?.position

        var track: MiloSessionAttributes.Track?
        if let shown = state.shown {
            // « Connecté à X » : l'émetteur est là, mais Milō ne sait pas dire
            // lecture ou pause. C'est ce que la ligne d'artiste dit alors, avec
            // les noms que le fil publie pour ça.
            var artist = shown.artist
            if session?.phase == .connected, let senders = session?.senders, !senders.isEmpty {
                artist = String(localized: "connectedTo \(senders.joined(separator: ", "))")
            }

            track = MiloSessionAttributes.Track(
                // L'identifiant change avec ce qui est affiché : sans ça, le
                // système garde la pochette et le titre précédents, faute de
                // savoir que le contenu a changé. Il porte aussi la source, que
                // `fireTransport` relit pour adresser ses commandes.
                id: state.source + ":" + shown.title,
                title: shown.title,
                artist: artist,
                album: shown.album,
                // Millisecondes côté Milō, secondes côté framework ; une durée
                // inconnue vaut 0, jamais `nil`.
                duration: TimeInterval(shown.durationMs ?? 0) / 1000,
                artworkURL: shown.artwork
            )

            // La déposer avant d'annoncer la session : l'extension la lira sur
            // disque, sans réseau ni délai.
            if let artwork = track?.artworkURL {
                await MiloAPIClient.cacheArtwork(from: artwork)
            }
        } else if state.source == "mac", let senders = session?.senders, !senders.isEmpty {
            // Un Mac envoie un flux, pas des pistes : la carte nomme qui émet,
            // sous l'icône macOS du dock — ce que le push de Milō envoie aussi.
            let title = senders.joined(separator: ", ")
            track = MiloSessionAttributes.Track(
                id: state.source + ":" + title,
                title: title,
                artist: nil,
                album: nil,
                duration: 0,
                artworkURL: macArtwork
            )
            await MiloAPIClient.cacheArtwork(from: macArtwork)
        }

        return MiloSessionAttributes(
            // Place tenue, jamais envoyée telle quelle : `refresh()` la remplace
            // par l'identifiant de la session qu'il tient, seul que
            // `update(_:)` accepte. L'app n'en mint plus aucun — voir
            // `reconcileSession`.
            id: "",
            isPlaying: session?.phase == .playing,
            elapsedTime: anchor.map { TimeInterval($0.ms) / 1000 } ?? 0,
            timestamp: anchor.map { anchorTimestamp.string(from: Date(timeIntervalSince1970: $0.at)) }
                ?? anchorTimestamp.string(from: .now),
            currentTrack: track,
            devices: await buildDevices(),
            controls: state.controls
        )
    }

    /// L'icône macOS du dock, servie par Milō à la taille de l'écran verrouillé.
    private static let macArtwork = "/api/push/artwork/macos"

    /// Avec la fraction de seconde : l'ancrage de Milō la porte (`at` vaut
    /// `1790270000.25`), et la jeter décalerait la tête de lecture d'autant.
    /// `capturedAt` relit les deux formes.
    private static let anchorTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Un device par client snapcast, avec son vrai nom.
    ///
    /// Les noms ne sont pas dans `/api/volume/state` — seules les zones y sont
    /// nommées, si bien que deux enceintes d'une même zone s'appelaient toutes
    /// deux « Salon ». Ils vivent dans `/api/multiroom/state`, qui n'est plus
    /// interrogé que pour eux.
    ///
    /// Le niveau et le filtre viennent tous deux de `/api/volume/state` : il
    /// porte maintenant `volume` (0…1, normalisé par Milō sur ses propres
    /// bornes), `available` et `volume_control`. Prendre les trois à la même
    /// source est ce qui met cette liste d'accord avec celle que Milō pousse
    /// par APNs, et avec la moyenne qu'il appelle son volume global — les
    /// mêmes enceintes exactement, aux mêmes niveaux, sur la même échelle.
    /// Reconvertir `volume_db` ici avec des bornes gardées de notre côté est
    /// précisément ce qui faisait diverger l'app ouverte et l'app endormie.
    private static func buildDevices() async -> [MiloSessionAttributes.Device] {
        async let volumeTask = MiloAPIClient.get(path: "/api/volume/state")
        async let roomsTask = MiloAPIClient.get(path: "/api/multiroom/state")

        guard let volumeData = try? await volumeTask,
              let volumeJSON = try? JSONSerialization.jsonObject(with: volumeData) as? [String: Any],
              let payload = volumeJSON["data"] as? [String: Any],
              let clients = payload["clients"] as? [String: [String: Any]]
        else { return [] }

        let rooms = (try? await roomsTask)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0?["clients"] as? [String: [String: Any]] } ?? [:]

        return clients.keys.sorted().compactMap { mac -> MiloSessionAttributes.Device? in
            let client = clients[mac]
            guard client?["available"] as? Bool ?? true else { return nil }
            guard client?["volume_control"] as? Bool ?? true else { return nil }

            // Ce qu'on vient de demander l'emporte sur ce que Milō rapporte
            // pendant quelques secondes : sinon cette boucle repousse un niveau
            // lu avant l'écriture, et le curseur recule sous le doigt.
            let level = MiloAPIClient.optimisticLevel(mac: mac)
                ?? client?["volume"] as? Double ?? 0
            return MiloSessionAttributes.Device(
                id: mac,
                name: rooms[mac]?["name"] as? String ?? "Milō \(mac.suffix(5))",
                type: "speaker",
                // Même plancher que `displayedVolume` : deux définitions du
                // niveau rendu donneraient deux bases au même curseur selon que
                // l'app est devant ou endormie, et c'est la base qui décide du
                // facteur que le système applique.
                volume: Float(MiloAPIClient.renderedLevel(level))
            )
        }
    }

    private static func note(_ message: String) {
        UserDefaults(suiteName: MiloAPIClient.appGroupID)?
            .set(message, forKey: statusKey)
    }
}
