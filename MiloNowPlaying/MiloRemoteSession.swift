import Foundation
import NowPlaying
import Observation
import OSLog

/// Journal système de l'extension.
///
/// Préféré au conteneur partagé pour tout ce qui est chronologique : une clé de
/// `UserDefaults` ne garde que le dernier événement, et un échec y est
/// indiscernable d'un appel qui n'a jamais eu lieu — c'est exactement ce qui a
/// fait conclure à tort « le fournisseur n'est jamais appelé » alors que la
/// seule trace du fournisseur s'écrivait *après* la première branche réussie.
///
/// Lisible depuis le Mac, l'iPhone branché en USB :
/// `sudo log collect --device-udid <UDID> --last 5m --output x.logarchive`
/// puis `log show x.logarchive --predicate 'subsystem == "leodurand.Milo-iOS"'`.
let miloLog = Logger(subsystem: "leodurand.Milo-iOS", category: "artwork")

/// Empreinte du binaire **effectivement chargé**, et non de celui qu'on vient de
/// construire.
///
/// Réinstaller par-dessus ne remplace pas une extension que le système tient
/// déjà : on lit alors un code et on en mesure un autre, ce qui a fait conclure
/// deux fois qu'un correctif « ne marchait pas » alors qu'il ne s'exécutait
/// jamais. Le 19/09/2026 le bundle construit à 17:35 tournait encore après le
/// commit de 18:26 — sans repère dans le journal, rien ne le disait.
///
/// `dladdr` sur une adresse de ce fichier rend le chemin de l'image qui contient
/// vraiment ce code : en Debug c'est le `.debug.dylib`, pas l'exécutable du
/// bundle, distinction qui a déjà fait lire « build périmé » à tort. Sa date de
/// modification change à chaque compilation et à chaque signature, si bien que
/// l'empreinte s'actualise seule — rien à éditer avant chaque mesure, donc rien
/// à oublier d'éditer.
func miloBinaryStamp() -> String {
    var info = Dl_info()
    let here = unsafeBitCast(miloBinaryStamp as @convention(thin) () -> String,
                             to: UnsafeRawPointer.self)
    guard dladdr(here, &info) != 0, let raw = info.dli_fname else { return "image inconnue" }
    let path = String(cString: raw)
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let date = (attrs?[.modificationDate] as? Date).map {
        $0.formatted(date: .abbreviated, time: .standard)
    } ?? "date inconnue"
    let size = (attrs?[.size] as? Int).map(String.init) ?? "?"
    return "\((path as NSString).lastPathComponent) \(date) \(size)o"
}

/// Milō vu par l'écran verrouillé, le Centre de contrôle et la Dynamic Island.
///
/// Le système garde cette instance et lui route les mises à jour suivantes : la
/// connexion à Milō se fait donc une fois et se réutilise, plutôt qu'à chaque
/// push.
///
/// Les commandes et le curseur partent d'ici, **sur le LAN** : APNs ne sert qu'à
/// l'état descendant. Ce qui remonte vers Milō est du HTTP ordinaire, et
/// n'emprunte jamais Internet.
@available(iOS 27, *)
@Observable
final class MiloRemoteSession: @MainActor RemoteMediaSessionRepresentable {

    let id: String
    private(set) var attributes: MiloSessionAttributes

    init(attributes: MiloSessionAttributes) {
        self.id = attributes.id
        self.attributes = attributes
        miloLog.info("SESSION CONSTRUITE \(attributes.id, privacy: .public) — instance \(ObjectIdentifier(self).debugDescription, privacy: .public)")
        Self.trace("session construite \(attributes.id)")

        // Le client partagé n'a pas de journal à lui : il écrit dans le nôtre
        // quand on lui en prête un. Sans ça, la décision « geste global ou
        // curseur individuel » ne laisse aucune trace, et c'est précisément
        // celle qu'il faudra relire.
        MiloAPIClient.trace = { Self.trace($0) }

        startObservingPushToken()
    }

    /// Le système remet ici les attributs poussés par Milō. Les stocker suffit :
    /// `@Observable` fait remonter le changement à l'interface Now Playing.
    ///
    /// Le token est redéposé au passage : voir `startObservingPushToken`, cette
    /// session n'a qu'un nombre limité d'occasions de le faire aboutir et
    /// celle-ci en est une.
    func update(_ attributes: MiloSessionAttributes) {
        self.attributes = attributes
        miloLog.info("update reçu \(attributes.id, privacy: .public)")
        Self.trace("update reçu")

        registerPushTokenIfNeeded(occasion: "update")
    }

    // MARK: - Ce qui joue

    var playbackSnapshot: MediaPlaybackSnapshot? {
        MediaPlaybackSnapshot(
            state: attributes.isPlaying ? .playing() : .paused,
            elapsedTime: attributes.elapsedTime,
            timestamp: attributes.capturedAt
        )
    }

    var content: (any MediaContentRepresentable)? {
        guard let track = attributes.currentTrack else {
            miloLog.info("content lu : aucune piste")
            return nil
        }

        // Tracé ici parce que c'est le seul endroit qui prouve que le système
        // est allé chercher le contenu — et donc que l'absence de pochette se
        // joue en aval, pas faute d'avoir été construite.
        let cover = artwork(for: track)
        miloLog.info("""
            content lu : \(track.id, privacy: .public) — \
            pochette \(cover == nil ? "absente" : "présente", privacy: .public)
            """)

        // `MusicContent` veut des `String` non optionnels alors que Milō peut
        // n'avoir pas encore de métadonnées. Une chaîne vide laisse le système
        // masquer la ligne ; inventer « Inconnu » l'afficherait pour de bon.
        return MusicContent(
            id: Self.contentID(track),
            songTitle: track.title ?? "",
            artistName: track.artist ?? "",
            albumName: track.album ?? "",
            type: .audio,
            // Une durée à 0 veut dire « pas de durée ». Pour un flux c'est
            // exact et le framework a le mot juste : `.live` retire la barre de
            // progression au lieu d'en afficher une fausse ou de la laisser
            // vide. Les deux cas sont indiscernables ici, et `.live` est le
            // moins trompeur des deux.
            duration: track.duration > 0 ? .finite(track.duration) : .live,
            artwork: cover
        )
    }

    /// L'identité du contenu pour le système : la piste **et** sa pochette.
    ///
    /// Le système ne résout qu'une image par identifiant de contenu. S'il a
    /// déjà lu ce contenu sans pochette, il ne redemande rien quand l'URL
    /// arrive sous le même identifiant — et c'est l'ordre normal : Milō publie
    /// le titre d'abord, avec le logo de la station ou sans image, puis la
    /// pochette une seconde plus tard, une fois résolue. Le fournisseur n'était
    /// alors jamais rappelé pour elle (mesuré le 22/09/2026), et la carte
    /// restait grise ou sur le logo jusqu'à ce que l'app, ouverte,
    /// reconstruise la session.
    ///
    /// Vérifié le 25/09/2026 à 13:56, app endormie : « Annie Rooney » arrive
    /// avec le logo de Classic Vinyl HD, puis sa pochette `mzstatic` sous le
    /// même `currentTrack.id` ; le fournisseur est rappelé, la télécharge en
    /// 83 ms, et la Dynamic Island l'affiche.
    ///
    /// Composé ici plutôt que sur le fil : `currentTrack.id` reste ce que Milō
    /// et l'app écrivent, et `knownSource` le relit tel quel. Seul ce que le
    /// système voit change, une fois de plus par piste au plus.
    private static func contentID(_ track: MiloSessionAttributes.Track) -> String {
        guard let artwork = track.artworkURL else { return track.id }
        return track.id + "\u{1F}" + artwork
    }

    /// La pochette est chargée par l'extension, à la demande du système.
    ///
    /// L'URL est publique (Spotify sert la sienne sur `i.scdn.co`), donc ce
    /// chargement ne dépend pas du LAN — il marche même hors de la maison, ce
    /// qui est précisément le cas où l'écran verrouillé sert encore.
    private func artwork(for track: MiloSessionAttributes.Track) -> Artwork? {
        // Milō sert une URL absolue quand la source en a une (Spotify pointe sur
        // i.scdn.co), mais un chemin relatif pour ce qu'il héberge lui-même —
        // `/api/music-library/cover/…`. Passer ce chemin tel quel à `URL(string:)`
        // donne une URL sans hôte, que personne ne peut charger.
        guard let raw = track.artworkURL else {
            miloLog.info("pochette : la piste ne porte aucune URL")
            return nil
        }
        let absolute = raw.hasPrefix("/") ? MiloAPIClient.baseURL() + raw : raw
        guard let url = URL(string: absolute) else {
            miloLog.error("pochette : URL inconstructible — \(absolute, privacy: .public)")
            return nil
        }
        miloLog.info("pochette : Artwork construit, id=\(raw, privacy: .public)")

        // `size` est repris plutôt qu'ignoré, pour être *tracé* et rien d'autre.
        // Le système y passe `CGFloat.greatestFiniteMagnitude` dans au moins un
        // de ses appels (mesuré dans `MPArtworkCatalog`), valeur sur laquelle un
        // `Int(size.width)` piège et tue l'extension sans rien écrire. On la
        // journalise, on ne la convertit jamais.
        return Artwork(id: raw) { size in
            miloLog.info("""
                FOURNISSEUR APPELÉ id=\(raw, privacy: .public) \
                taille=\(size.width, privacy: .public)x\(size.height, privacy: .public)
                """)

            // Le fichier déposé par l'app, rendu **brut**, sans le décoder.
            //
            // Ce fournisseur court contre la mort de son propre processus :
            // `mediaremoted` matérialise la session dans une extension neuve,
            // lit ce qu'il peut lire de façon synchrone, et demande aussitôt sa
            // terminaison — mesuré le 19/09/2026, six millisecondes entre
            // l'entrée dans ce bloc et le `RBSTerminateRequest`, et dix-sept
            // processus en trois minutes. Tout ce qui est asynchrone doit donc
            // tenir dans ce budget, ou ne jamais répondre.
            //
            // **Ce budget ne décrit plus la règle.** Remesuré le 19/09 au soir
            // puis le 25/09/2026 : un même processus a vécu plus de soixante-dix
            // minutes, et le repli réseau ci-dessous aboutit en 20 à 83 ms,
            // app endormie. Les six millisecondes décrivaient des réveils en
            // rafale. Le cache reste le chemin le plus court, pas le seul.
            //
            // D'où le retrait d'ImageIO du chemin critique : une lecture de
            // fichier suffit, `ArtworkRepresentation(data:)` prend les octets
            // tels quels et laisse le système décoder de son côté, quand il
            // veut et sans nous. La borne à 600 px est retirée avec lui — la
            // mesure qui l'avait motivée (« 600×600 s'affiche, 1024×1024 non »)
            // ne décrivait pas une limite de taille mais ce même budget : la
            // grande image perdait la course que la petite gagnait.
            if let file = MiloAPIClient.artworkCacheFile(for: raw),
               let data = try? Data(contentsOf: file), !data.isEmpty,
               // Un fichier qui ne s'affichera pas ne vaut pas mieux qu'un
               // fichier absent : on repasse par le réseau plutôt que de servir
               // à coup sûr du vide. Ce qui a mis quatre WebP de station dans ce
               // dossier est réparé juste en dessous, mais ceux déjà déposés y
               // sont, et cette garde est ce qui les rattrape.
               //
               // Le verdict est celui de l'app, pas un second : deux définitions
               // de « affichable » rendraient ce dossier incohérent, l'un
               // écrivant ce que l'autre rejette.
               MiloAPIClient.isDisplayableArtwork(data) {
                miloLog.info("""
                    cache servi brut : \(data.count, privacy: .public) o \
                    format \(Self.formatTag(data), privacy: .public)
                    """)
                return try ArtworkRepresentation(data: data)
            }
            miloLog.info("cache absent ou vide, repli sur le réseau")

            // Repli réseau, mêmes règles : on rend les octets, on ne décode
            // pas.
            //
            // Ce n'est plus un repli rare. Le cache était rempli par l'app, et
            // l'app dort pendant que l'écran est verrouillé — c'est-à-dire
            // exactement quand cette extension sert. Mesuré le 19/09/2026 sur
            // douze minutes d'écran verrouillé : quatre appels au fournisseur,
            // **zéro** servi par le cache, quatre par le réseau.
            //
            // Le téléchargement est le seul point du fournisseur qui puisse
            // jeter sans qu'on s'en aperçoive : l'erreur remonte au système,
            // qui l'avale, et rien n'était écrit — un échec y était alors
            // indiscernable d'un fournisseur jamais appelé.
            // `Accept` explicite plutôt que celui d'`URLSession`.
            //
            // Milō sert ses images de station en WebP et négocie désormais le
            // format — mais faire reposer l'affichage sur ce qu'`URLSession`
            // met par défaut dans cet en-tête, c'est parier sur une valeur
            // qu'on n'a pas mesurée et qu'Apple peut changer. Le dire est
            // gratuit, et c'est exactement à ça que sert cet en-tête : ce
            // processus ne sait afficher que du JPEG.
            var request = URLRequest(url: url)
            request.setValue("image/jpeg", forHTTPHeaderField: "Accept")

            let (data, code) = try await Self.downloadArtwork(request, from: url)

            // Déposé pour la fois d'après, ici et pas ailleurs : c'est le seul
            // endroit de l'extension que le système attend, donc le seul où une
            // écriture a le temps d'aboutir. Une tâche détachée lancée depuis
            // `update(_:)` meurt avec son processus — et il en change à chaque
            // réveil : cinq processus en sept secondes, mesurés.
            //
            // Ce que ça change : le système redemande la même image à plusieurs
            // reprises, dans des processus différents — `3dffdd56c66f.webp`
            // redemandé à 17:35:55 puis à 17:35:59 — et chaque demande repayait
            // les 13 à 50 ms du réseau. Une lecture de fichier en coûte une, et
            // cette course-là se joue à la milliseconde.
            //
            // `.atomic` : sans lui, un processus tué en cours d'écriture
            // laisserait un fichier tronqué que la branche du dessus lirait
            // comme valide — non vide — et servirait indéfiniment.
            // Ne déposer que ce qui s'affichera, et ne pas faire passer le
            // reste pour une réussite.
            //
            // Mesuré le 19/09/2026 à 19:14:55, une station changée pendant que
            // l'app dormait : `réseau servi : HTTP 200, 5526 o format WEBP
            // depuis http://milo.local/api/radio/images/6239161eaee1.webp`.
            // `ArtworkRepresentation(data:)` a pris ces octets sans broncher et
            // le système n'a rien affiché — il n'affiche pas le WebP. Pire, ils
            // étaient écrits dans le cache : `cacheArtwork` voyait un fichier
            // non vide, sortait aussitôt, et la conversion en JPEG que l'app
            // aurait faite n'avait plus jamais lieu. La station perdait son
            // image définitivement.
            //
            // Milō sert désormais du JPEG à qui n'annonce pas comprendre le
            // WebP, donc cette branche ne devrait plus être atteinte. Elle reste
            // parce qu'un garde-fou qu'on retire le jour où il ne sert plus est
            // un garde-fou qu'on n'avait pas.
            //
            // Elle ne refuse que ce qui a été *mesuré* comme inaffichable. Un
            // PNG passe : rien ne l'a jamais incriminé, et le refuser priverait
            // d'image une pochette parfaitement valide.
            guard MiloAPIClient.isDisplayableArtwork(data) else {
                miloLog.error("""
                    réseau : octets inaffichables, rien mis en cache — \
                    format \(Self.formatTag(data), privacy: .public) \
                    depuis \(url.absoluteString, privacy: .public)
                    """)
                // Jeter plutôt que rendre ces octets : le système retiendrait
                // sinon une image vide sous cet identifiant et ne redemanderait
                // plus rien — `Artwork` est `Identifiable` et c'est bien son
                // `id` que le système retient. Un échec annoncé lui laisse la
                // possibilité de redemander.
                //
                // L'erreur du framework plutôt qu'une des nôtres : c'est le mot
                // que ce rappel est censé rendre quand il n'a pas d'image, et
                // le seul que le système puisse interpréter autrement que comme
                // une panne quelconque.
                throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
            }

            if code == 200, !data.isEmpty,
               let file = MiloAPIClient.artworkCacheFile(for: raw) {
                try? data.write(to: file, options: .atomic)
            }
            return try ArtworkRepresentation(data: data)
        }
    }

    /// Ce qu'on accorde à un essai de téléchargement de pochette.
    ///
    /// Deux essais tiennent dans les dix secondes au-delà desquelles le système
    /// abandonne (`playbackQueueRequest timed out after 10s`, puis `Catalog
    /// returned nil image`), avec de la marge. Et c'est large pour ce qu'on
    /// demande : une pochette de 525 ko est arrivée en 64 ms le 19/09/2026.
    private static let artworkAttemptTimeout: TimeInterval = 2.5

    /// Le téléchargement lui-même, en deux essais courts plutôt qu'un sans
    /// borne.
    ///
    /// Sans `timeoutInterval`, cette requête héritait des **soixante secondes**
    /// par défaut d'`URLSession` — dans un rappel dont le système n'attend pas
    /// tant, et depuis un processus que `mediaremoted` peut terminer entre
    /// temps. Une résolution qui traîne n'y était donc pas un échec qu'on
    /// rattrape : c'était une image qui n'arrivait jamais, sans que rien ne le
    /// dise.
    ///
    /// Le second essai vise la même chose que celui de `sendControl` : l'échec
    /// mesuré n'est pas un refus, c'est une connexion qui n'aboutit jamais —
    /// zéro chemin `ready` à 19:39:21, un chemin qui passe à 19:40:35 sans rien
    /// changer d'autre. Un second tirage est exactement ce qui peut le sauver,
    /// et il compte double ici : le fournisseur est épinglé sur `milo.local`,
    /// dont la résolution est elle-même un tirage sur ce réseau.
    ///
    /// Une **réponse** n'est jamais rejouée, quel que soit son code : un 404 est
    /// une réponse, et le répéter ne ferait que le répéter plus lentement. Seule
    /// une requête qui jette a droit au second essai.
    private static func downloadArtwork(_ request: URLRequest,
                                        from url: URL) async throws -> (Data, Int) {
        let attempts = 2
        var request = request
        request.timeoutInterval = artworkAttemptTimeout

        for attempt in 1...attempts {
            do {
                // Par `lanData` : une pochette hébergée par Milō part alors sur le
                // chemin lié au Wi-Fi, les autres restent sur `URLSession.shared`.
                let (data, response) = try await MiloAPIClient.lanData(for: request,
                                                                       session: .shared)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                miloLog.info("""
                    réseau servi : HTTP \(code, privacy: .public), \
                    \(data.count, privacy: .public) o \
                    format \(Self.formatTag(data), privacy: .public) \
                    depuis \(url.absoluteString, privacy: .public)\
                    \(attempt == 1 ? "" : " (2e essai)", privacy: .public)
                    """)
                return (data, code)
            } catch {
                // Tracé à chaque essai, pas seulement au dernier : « ça a marché
                // au second » et « ça a marché du premier coup » appellent des
                // lectures différentes du réseau.
                miloLog.error("""
                    réseau : échec \(url.lastPathComponent, privacy: .public) — \
                    \((error as NSError).code, privacy: .public) \
                    \(error.localizedDescription, privacy: .public) \
                    (essai \(attempt, privacy: .public)/\(attempts, privacy: .public))
                    """)
                // Une annulation n'est pas un tirage perdu : c'est le système
                // qui démonte le processus ou qui n'a plus besoin de cette
                // image. Relancer 2,5 s de requête là-dedans ne peut rien
                // ramener et retient un processus qu'on est en train de tuer.
                //
                // Le domaine est vérifié avant le code : `-999` ne veut dire
                // « annulé » que dans `NSURLErrorDomain`, et le prendre au mot
                // ailleurs supprimerait le second essai qu'on vient d'ajouter.
                let failure = error as NSError
                if Task.isCancelled
                    || (failure.domain == NSURLErrorDomain
                        && failure.code == NSURLErrorCancelled) {
                    throw error
                }
                if attempt == attempts { throw error }
                // Rien à attendre avant de retenter : la boucle rouvre une
                // connexion, et c'est le nouveau tirage qu'on veut.
            }
        }

        // Inatteignable : la dernière itération rend ou jette.
        throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
    }

    // MARK: - Commandes

    /// La source que Milō dit jouer, lue dans les attributs plutôt que sur le
    /// réseau.
    ///
    /// Elle voyage dans `currentTrack.id`, sous la forme `<source>:<titre>` —
    /// c'est le contrat que les deux côtés écrivent déjà : l'app le fabrique
    /// dans `MiloNowPlayingBridge.buildAttributes`, Milō dans
    /// `payloads.build_attributes`. Le titre peut contenir des `:`, pas le nom
    /// de source : on coupe au premier.
    ///
    /// Ce qu'elle évite : l'aller-retour `/api/audio/state` que chaque commande
    /// posait devant son `POST`. Le système n'accorde que trois secondes au
    /// rappel, et deux requêtes n'y tiennent pas — voir `activeSource()`.
    ///
    /// `nil` quand aucune piste n'est annoncée ; l'appelant relit alors, comme
    /// avant.
    /// Deux valeurs ne nomment aucune source et rendent `nil` plutôt que de
    /// partir sur le réseau : `milo`, le bouchon que
    /// `MiloNowPlayingBridge.buildAttributes` écrit quand `/api/audio/state`
    /// n'annonce pas de source, et `none`, la façon dont Milō dit lui-même que
    /// rien ne joue. Les laisser passer frappait
    /// `/api/audio/control/milo`, une route qui n'existe pas, et la trace
    /// disait « envoyé » pour une commande qui ne pouvait pas aboutir.
    private var knownSource: String? {
        guard let id = attributes.currentTrack?.id,
              let separator = id.firstIndex(of: ":"), separator > id.startIndex
        else { return nil }
        let source = String(id[id.startIndex..<separator])
        return source == "milo" || source == "none" ? nil : source
    }

    var commands: [MediaCommand] {
        let source = knownSource
        let playing = attributes.isPlaying
        // `nil` : un Milō qui n'envoie pas encore la liste — tout reste actif,
        // comme avant. Sinon un bouton n'est actif que si Milō accepte sa
        // commande à cet instant : Qobuz et un Mac n'en prennent aucune, Tidal
        // pas `seek`, et chacune d'elles répondait 400 (mesuré le 25/09/2026).
        let controls = attributes.controls
        func offers(_ command: MiloAPIClient.TransportCommand) -> Bool {
            guard let controls else { return true }
            guard let name = command.name(forSource: source ?? "") else { return false }
            return controls.contains(name)
        }
        // Le bouton unique lecture/pause envoie ce que l'état appelle : `pause`
        // quand ça joue, sinon `resume` (`stop` et `resume_playback` en radio).
        // `playpause` n'existe que chez Spotify ; ailleurs, il était refusé.
        let toggle: MiloAPIClient.TransportCommand = playing ? .pause : .play
        miloLog.info("commands lu — source \(source ?? "inconnue", privacy: .public)")
        return [
            .play {
                miloLog.info("RAPPEL COMMANDE play")
                await MiloAPIClient.fireTransport(.play, source: source)
            }
                .enabled(offers(.play)),
            .pause { await MiloAPIClient.fireTransport(.pause, source: source) }
                .enabled(offers(.pause)),

            // `enabled(_:)` dit au système ce que ces commandes ne peuvent pas
            // faire, au lieu de le lui laisser découvrir en appelant un rappel
            // qui sort aussitôt. Une commande désactivée reste affichée — c'est
            // le contrat de la documentation — mais son rappel n'est pas invoqué.
            .togglePlayPause { await MiloAPIClient.fireTransport(toggle, source: source) }
                .enabled(offers(toggle)),
        ] + steps(source: source, controls: controls, offers: offers) + [
            // Un flux n'a pas de tête de lecture à déplacer, et une source sans
            // `seek` (Tidal) ne le fait pas non plus.
            .seekToPosition { position in
                await MiloAPIClient.fireSeek(toSeconds: position, source: source)
            }
                .enabled((attributes.currentTrack?.duration ?? 0) > 0
                         && (controls?.contains("seek") ?? true))
        ]
    }

    /// Les deux boutons autour de lecture/pause.
    ///
    /// Le podcast avance par bonds, −15 / +30, comme sur l'écran de Milō ; les
    /// autres sources changent de piste (ou de station favorite en radio). Un
    /// seul des deux jeux est déclaré, pour que le système dessine celui-là.
    ///
    /// **iOS ne dessine −15 / +30 que s'ils sont actifs.** Désactivés, il
    /// affiche à leur place les flèches précédent / suivant, grisées — constaté
    /// le 25/09/2026 sur une carte de podcast au repos, les −15 / +30 revenant
    /// dès la lecture. Ils sont désactivés dès qu'aucune session n'est en
    /// cours : Milō et l'app ne laissent alors dans `controls` que la reprise
    /// (`lock_screen_controls`, `MiloSourceCard.lockScreenControls`).
    ///
    /// `skip` n'a pas de repli « tout actif » quand `controls` manque : un Milō
    /// qui n'envoie pas la liste ne connaît pas non plus la commande.
    private func steps(
        source: String?, controls: [String]?,
        offers: (MiloAPIClient.TransportCommand) -> Bool
    ) -> [MediaCommand] {
        guard source == "podcast" else {
            return [
                .next { await MiloAPIClient.fireTransport(.next, source: source) }
                    .enabled(offers(.next)),
                .previous { await MiloAPIClient.fireTransport(.previous, source: source) }
                    .enabled(offers(.previous)),
            ]
        }
        let skips = controls?.contains("skip") ?? false
        return [
            .skipBackward(preferredIntervals: [15]) { interval in
                await MiloAPIClient.fireSkip(seconds: -interval, source: source)
            }
                .enabled(skips),
            .skipForward(preferredIntervals: [30]) { interval in
                await MiloAPIClient.fireSkip(seconds: interval, source: source)
            }
                .enabled(skips),
        ]
    }

    // MARK: - Enceintes

    /// Un `MediaDevice` par client snapcast : l'utilisateur obtient un curseur
    /// par pièce dans le Centre de contrôle.
    ///
    /// Le niveau arrive normalisé 0…1 de Milō, et repart tel quel : Milō accepte
    /// désormais `volume` sur cette même échelle. L'extension ne convertit plus
    /// rien en décibels, et ne lit donc plus `volume_limits` — la copie qu'elle
    /// en gardait était périmée, et c'est elle qui faisait monter le son de
    /// trois fois trop peu. C'est toujours une écriture **absolue** : passer par
    /// `/api/volume/adjust` serait une lecture-modification-écriture en course
    /// contre l'encodeur rotatif de l'appareil.
    var devices: [MediaDevice] {
        miloLog.info("devices lu : \(self.attributes.devices.count, privacy: .public) enceinte(s)")

        // Dédupliqué avant tout le reste. `attributes.devices` est un simple
        // tableau décodé d'un payload APNs : rien ne garantit que Milō n'y
        // mette pas deux fois le même snapclient, et deux entrées de même
        // identifiant donneraient deux `MediaDevice` de même id — donc deux
        // curseurs pour une seule enceinte, et deux fermetures qui s'écrivent
        // dessus — en plus de faire trapper le `Dictionary` ci-dessous.
        var identifiers = Set<String>()
        let unique = attributes.devices.reversed()
            .filter { identifiers.insert($0.id).inserted }
            .reversed()

        let shown = unique.map { (device: $0, level: Self.displayedVolume($0)) }

        // Ce que le système a sous les yeux, figé ici et passé en entier à
        // chaque rappel. Il en faut l'ensemble, pas seulement un compte : le
        // curseur maître ne pose pas une valeur, il **multiplie** les niveaux
        // qu'on lui rend par un facteur commun — mesuré le 19/09/2026, trois
        // enceintes, même rapport à sept chiffres — et ses rafales ne portent
        // pas toujours les mêmes enceintes. Reconstituer la moyenne qu'il vise
        // demande donc de savoir où sont celles qu'une rafale n'a pas citées.
        // `uniquingKeysWith` et non `uniqueKeysWithValues`, qui fait un trap
        // sur une clé répétée : la déduplication ci-dessus la rend déjà
        // impossible, et c'est précisément pour ça qu'on ne veut pas d'un trap
        // ici — il n'y aurait plus rien pour l'attraper si elle cessait de
        // l'être. Même règle que la déduplication : la dernière l'emporte.
        let snapshot = Dictionary(shown.map { ($0.device.id, $0.level) },
                                  uniquingKeysWith: { _, last in last })

        // Tracée quand elle change : sans elle au journal, le facteur que le
        // système applique ensuite n'est pas interprétable.
        Self.traceBase(shown
            .map { "\($0.device.id)=\(((($0.level * 10000).rounded()) / 10000))" }
            .joined(separator: " "))

        return shown.map { device, level in
            MediaDevice(
                id: device.id,
                name: device.name,
                type: Self.deviceType(device.type),
                capabilities: [
                    .absoluteVolume(level) { newLevel in
                        // Tracé AVANT le réseau : « rien ne se passe » ne
                        // distingue pas une fermeture jamais appelée d'une
                        // requête qui échoue, et ce sont deux causes opposées.
                        miloLog.info("RAPPEL VOLUME \(device.id, privacy: .public) -> \(newLevel, privacy: .public)")
                        Self.trace("onChange \(device.id) -> \(newLevel)")
                        await MiloAPIClient.applyVolume(mac: device.id,
                                                        to: newLevel,
                                                        snapshot: snapshot)
                    }
                ]
            )
        }
    }

    /// Le niveau à montrer pour cette enceinte : ce que le doigt vient de
    /// demander tant que c'est assez frais, sinon ce que Milō rapporte.
    ///
    /// Le même raccommodage existe déjà dans l'app — `buildDevices` — mais il
    /// ne couvre que le chemin de l'app. Des attributs arrivés par APNs sont
    /// construits par Milō, qui ignore tout d'une écriture encore en vol : un
    /// `update` qui atterrit **pendant** un glissement repose alors un niveau
    /// d'avant. Et comme le système recalcule son facteur sur la base qu'on lui
    /// rend, le reste du geste s'applique à partir d'un niveau périmé —
    /// c'est-à-dire avec le mauvais écart.
    ///
    /// Mesuré le 19/09/2026 : `update reçu` apparaît deux fois au milieu d'un
    /// glissement de six secondes, et l'app pousse de toute façon sa propre
    /// passe toutes les deux secondes tant qu'elle est au premier plan.
    ///
    /// Les deux valeurs sont désormais sur la même échelle, celle du curseur.
    /// Tant qu'elles ne l'étaient pas — un niveau venu de Milō normalisé sur
    /// -78…-8, une valeur optimiste reconvertie sur -80…-21 — ce choix entre
    /// les deux déplaçait le curseur à lui seul, à chaque expiration de la
    /// fenêtre.
    /// Le plancher n'est pas cosmétique : le curseur maître **multiplie** ce
    /// qu'on lui rend, et zéro le rend inerte pour toujours. Voir
    /// `MiloAPIClient.renderedLevel`.
    private static func displayedVolume(_ device: MiloSessionAttributes.Device) -> Float {
        let raw = MiloAPIClient.optimisticLevel(mac: device.id) ?? Double(device.volume)
        return Float(MiloAPIClient.renderedLevel(raw))
    }

    /// Ce que sont vraiment les octets qu'on s'apprête à rendre.
    ///
    /// Le format et la taille ont déjà été confondus une fois sur ce chemin — le
    /// WebP arrivait en 1024 et le JPEG en 600, et « la grande ne s'affiche
    /// pas » se lisait comme une limite de taille. Le consommateur de
    /// `ArtworkRepresentation(data:)` n'affiche pas le WebP : il l'accepte, ne
    /// jette rien, et ne montre rien. Sans ce mot dans le journal, cette panne-là
    /// est indiscernable d'une pochette qui n'est jamais arrivée.
    nonisolated static func formatTag(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 12 else { return "trop court" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "JPEG" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "PNG" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "WEBP" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "GIF" }
        if b[0] == 0x3C { return "texte/SVG" }
        return "inconnu " + b.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Journal de l'extension, lisible depuis le Mac par le conteneur partagé.
    /// L'extension n'a pas d'écran et ses logs système ne se lisent qu'en USB
    /// avec les droits root ; l'app group est le seul canal praticable.
    /// Le verrou n'est pas une précaution de style : ce journal est une
    /// lecture-modification-écriture d'un tableau, et les rappels de volume
    /// arrivent par rafales de trois dans la même milliseconde. Sans lui, des
    /// lignes se perdent — et c'est ainsi qu'un geste a paru n'avoir touché que
    /// deux enceintes sur trois alors que les valeurs optimistes, écrites par le
    /// même rappel, portaient bien les trois.
    private static let traceLock = NSLock()

    /// Les secondes ne suffisent pas à ordonner une rafale.
    private static let traceClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    nonisolated static func trace(_ message: String) {
        traceLock.lock()
        defer { traceLock.unlock() }
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)
        var lines = defaults?.stringArray(forKey: "milo_ext_trace") ?? []
        lines.append("\(traceClock.string(from: Date())) \(message)")
        // Soixante plutôt que vingt : un glissement de quelques secondes sur
        // trois enceintes dépassait la fenêtre avant même d'être relu.
        defaults?.set(Array(lines.suffix(60)), forKey: "milo_ext_trace")
    }

    /// N'écrit que si la base a bougé : `devices` est relu à chaque changement
    /// observé, et le tracer à chaque lecture chasserait le geste du journal.
    nonisolated(unsafe) private static var lastBase = ""

    nonisolated private static func traceBase(_ base: String) {
        traceLock.lock()
        let changed = base != lastBase
        lastBase = base
        traceLock.unlock()
        guard changed else { return }
        trace("base \(base)")
    }

    private static func deviceType(_ raw: String) -> MediaDevice.DeviceType {
        switch raw {
        case "tv": return .tv
        case "phone": return .phone
        case "tablet": return .tablet
        case "desktop": return .desktop
        case "laptop": return .laptop
        default: return .speaker
        }
    }

    // MARK: - Token de session

    /// Rend à Milō le token de cette session.
    ///
    /// Tant qu'il n'est pas arrivé, Milō n'envoie **aucun** `update` : il n'a pas
    /// d'adresse où les mettre. Ce n'est pas une erreur, c'est l'aller-retour du
    /// protocole — `start` part au token push-to-start, la suite part à celui-ci.
    ///
    /// **Cet aller-retour ne se faisait jamais pour une session ouverte par
    /// Milō.** Mesuré le 19/09/2026 : le registre du Pi ne contenait que des
    /// identifiants en majuscules, c'est-à-dire des `UUID().uuidString` de
    /// sessions ouvertes par l'app ; aucun des identifiants que Milō mint en
    /// `uuid4`. `SESSION CONSTRUITE 87fdc61a-…` à 16:44:16.770, et le seul
    /// enregistrement arrivé à Milō dans cette seconde portait celui de l'app.
    /// `token_for_session` rendait donc `None` à chaque cycle et pas un seul
    /// `update` n'est jamais parti.
    ///
    /// D'où la reprise à chaque réveil plutôt qu'au seul `init` : une tâche
    /// détachée que personne n'attend meurt avec son processus, et celui-ci est
    /// terminé quelques millisecondes après avoir été lu. Le système réveille
    /// l'extension sans arrêt — dix-sept processus en trois minutes — si bien
    /// qu'un enregistrement manqué une fois aboutit au passage suivant. La garde
    /// d'idempotence le rend gratuit une fois qu'il a abouti.
    private func startObservingPushToken() {
        registerPushTokenIfNeeded(occasion: "init")

        // Ne capturer que l'identifiant et le flux — surtout pas `self`.
        //
        // `[weak self]` suivi d'un `guard let self` ne protège de rien devant un
        // `for await` sans fin : la garde rend une référence **forte** que la
        // boucle tient jusqu'à la fin du processus, ce que le `[weak self]`
        // était précisément censé empêcher. Le corps n'a besoin de rien d'autre
        // que `sessionID`, donc il ne capture rien d'autre.
        let sessionID = id
        let updates = pushTokenUpdates
        Task {
            for await token in updates {
                // Par la garde, comme les autres. Sans elle ce flux redéposait
                // le même token à chaque réveil — deux POST par changement de
                // station, mesurés dans le journal de Milō — et chacun pris sur
                // les quelques millisecondes que vit ce processus.
                guard Self.lastRegistered != Self.stamp(sessionID, token) else { continue }
                MiloAPIClient.notePendingSessionToken(token, sessionID: sessionID)
                await Self.register(token, for: sessionID, occasion: "rotation")
            }
        }
    }

    /// Dépose le token courant s'il n'a pas déjà abouti pour cette session.
    private func registerPushTokenIfNeeded(occasion: String) {
        let sessionID = id
        guard let token = pushToken else {
            // Tracé, parce que c'est l'hypothèse qui reste à départager : un
            // token pas encore frappé au moment de la construction n'est pas la
            // même panne qu'un enregistrement qui part et n'arrive pas.
            miloLog.info("""
                token de session absent (\(occasion, privacy: .public)) \
                \(sessionID, privacy: .public)
                """)
            return
        }
        guard Self.lastRegistered != Self.stamp(sessionID, token) else { return }

        // Déposé pour l'app **avant** toute tentative réseau, et de façon
        // synchrone : c'est la seule branche qui aboutisse à coup sûr dans un
        // processus que le système termine quelques millisecondes plus tard.
        MiloAPIClient.notePendingSessionToken(token, sessionID: sessionID)

        // L'essai direct reste, derrière. Quand mDNS répond — c'est le cas le
        // plus fréquent — Milō a le token tout de suite plutôt qu'au prochain
        // passage de l'app au premier plan.
        Task { await Self.register(token, for: sessionID, occasion: occasion) }
    }

    /// L'envoi, et ce qu'il en advient.
    ///
    /// Le verdict est retenu : seul un succès arme la garde d'idempotence. Un
    /// refus ou une panne réseau doit pouvoir être rejoué au réveil suivant,
    /// sinon la garde transformerait un échec unique en silence définitif —
    /// exactement la panne qu'on répare ici.
    nonisolated private static func register(_ token: Data,
                                             for sessionID: String,
                                             occasion: String) async {
        let outcome = await MiloAPIClient.registerPushToken(
            token, kind: .session, sessionID: sessionID)
        switch outcome {
        case .registered:
            lastRegistered = stamp(sessionID, token)
            miloLog.info("""
                token de session déposé (\(occasion, privacy: .public)) \
                \(sessionID, privacy: .public)
                """)
        case .refused(let detail):
            miloLog.error("token de session refusé : \(detail, privacy: .public)")
        case .unavailable:
            miloLog.error("token de session : Milō injoignable")
        }
        trace("token \(sessionID) \(occasion) → \(outcome)")
    }

    /// Ce qui a déjà abouti, dans le conteneur partagé : la garde doit survivre
    /// au processus, qui ne vit que quelques millisecondes.
    ///
    /// Elle survit *trop* pour être laissée seule. Si Milō perd son registre —
    /// fichier effacé, restauration, réinstallation — plus aucun `update` ne
    /// vient, donc l'occasion « update » ne se présente plus, et l'`init` est
    /// gardé : la session cesserait d'être enregistrable pour toujours, sans
    /// rien qui le signale. `MiloPushToStart.begin()` remet donc le compteur à
    /// zéro à chaque lancement de l'app, qui est déjà le moment où elle
    /// redéclare ses autres tokens. Coût : un POST par lancement.
    nonisolated private static var lastRegistered: String? {
        get { UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                .string(forKey: MiloAPIClient.sessionTokenStampKey) }
        set { UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                .set(newValue, forKey: MiloAPIClient.sessionTokenStampKey) }
    }

    /// Le couple (session, token) : c'est leur *paire* qui doit changer pour
    /// qu'un nouvel envoi soit dû. Le token seul rotationne sans changer de
    /// session, et une session nouvelle réutilise parfois le même token.
    nonisolated private static func stamp(_ sessionID: String, _ token: Data) -> String {
        "\(sessionID)/\(token.map { String(format: "%02x", $0) }.joined())"
    }
}
