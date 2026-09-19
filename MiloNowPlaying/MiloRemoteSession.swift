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
            id: track.id,
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
                UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                    .set("cache brut \(data.count)o", forKey: "milo_artwork_trace")
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

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                miloLog.error("""
                    réseau : échec \(url.lastPathComponent, privacy: .public) — \
                    \((error as NSError).code, privacy: .public) \
                    \(error.localizedDescription, privacy: .public)
                    """)
                throw error
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            miloLog.info("""
                réseau servi : HTTP \(code, privacy: .public), \
                \(data.count, privacy: .public) o \
                format \(Self.formatTag(data), privacy: .public) \
                depuis \(url.absoluteString, privacy: .public)
                """)
            UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                .set("réseau HTTP \(code) \(data.count)o", forKey: "milo_artwork_trace")

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
                UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                    .set("inaffichable \(Self.formatTag(data))", forKey: "milo_artwork_trace")
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
        miloLog.info("commands lu — source \(source ?? "inconnue", privacy: .public)")
        return [
            .play {
                miloLog.info("RAPPEL COMMANDE play")
                await MiloAPIClient.fireTransport(.play, source: source)
            },
            .pause { await MiloAPIClient.fireTransport(.pause, source: source) },

            // `enabled(_:)` dit au système ce que ces deux-là ne peuvent pas
            // faire, au lieu de le lui laisser découvrir en appelant un rappel
            // qui sort aussitôt.
            //
            // Une commande désactivée reste affichée — c'est le contrat de la
            // documentation — mais son rappel n'est pas invoqué. Ça ne change
            // donc rien à ce qu'on voit, et ça évite un aller-retour qui
            // n'aboutirait nulle part : sur un rappel à qui le système accorde
            // trois secondes, ne pas être appelé vaut mieux que l'être pour
            // rien.
            //
            // `playpause` n'a pas d'équivalent en radio — `name(forSource:)`
            // rend `nil` — et un flux n'a pas de tête de lecture à déplacer :
            // `fireSeek` sortait déjà sans rien envoyer. Source inconnue, les
            // deux restent actives : c'est `nil`, pas « radio », et le repli
            // saura relire ce qu'il faut.
            .togglePlayPause { await MiloAPIClient.fireTransport(.playPause, source: source) }
                .enabled(source != "radio"),
            .next { await MiloAPIClient.fireTransport(.next, source: source) },
            .previous { await MiloAPIClient.fireTransport(.previous, source: source) },
            .seekToPosition { position in
                await MiloAPIClient.fireSeek(toSeconds: position, source: source)
            }
                .enabled((attributes.currentTrack?.duration ?? 0) > 0)
        ]
    }

    // MARK: - Enceintes

    /// Un `MediaDevice` par client snapcast : l'utilisateur obtient un curseur
    /// par pièce dans le Centre de contrôle.
    ///
    /// Le niveau affiché arrive déjà normalisé 0…1 de Milō. À l'écriture il faut
    /// refaire le chemin inverse, parce que le backend raisonne en dB — et c'est
    /// bien une écriture **absolue** : convertir en delta contre
    /// `/api/volume/adjust` serait une lecture-modification-écriture en course
    /// contre l'encodeur rotatif de l'appareil.
    /// Sonde unique : « rien ne marche » ne distingue pas une extension sans
    /// réseau du tout d'une extension à qui seul le LAN est refusé, et les deux
    /// appellent des corrections opposées.
    ///
    /// Un appel explicite plutôt qu'un `static let` paresseux : de type `Void` et
    /// avec son résultat jeté, celui-ci pouvait être éliminé à la compilation —
    /// il ne s'est jamais exécuté.
    nonisolated(unsafe) private static var probed = false

    nonisolated private static func runProbeOnce() {
        guard !probed else { return }
        probed = true
        Task {
            // L'IP est lue dans l'app group, jamais obtenue de `baseURL()` :
            // cette extension pose `prefersHostname = true` dans son `init`, si
            // bien que `baseURL()` rend `milo.local`. Les deux jambes
            // interrogeaient donc la même adresse et rendaient toujours deux
            // valeurs égales — `ip=KO(-1001) mdns=KO(-1001)`, puis `ip=200
            // mdns=200`. La sonde n'existe que pour les distinguer, et elle ne
            // distinguait rien.
            let ipHost = UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                .string(forKey: MiloAPIClient.ipAddressKey) ?? ""

            let ipURL = ipHost.isEmpty ? "" : "http://\(ipHost)/api/volume/state"

            async let net = probeResult("https://www.apple.com")
            async let mdns = probeResult("http://milo.local/api/volume/state")

            // L'IP est sondée **deux fois**, et c'est toute la question du jour.
            //
            // Le journal système du 19/09/2026 montre que le chemin IPv4 *non
            // scopé* est refusé — `Path was denied by NECP policy` — tandis que
            // le chemin IPv4 *scopé sur en0*, essayé quelques millisecondes plus
            // tard par le même `URLSession`, passe et sert la réponse. C'est
            // pour ça que `milo.local` marche et que l'IP directe rend -1009 :
            // un nom produit plusieurs candidats et l'un d'eux tombe après
            // l'autorisation, une IP n'en produit qu'un.
            //
            // Si le second essai répond, l'IP redevient utilisable et `milo.local`
            // quitte le chemin critique — avec lui, la résolution mDNS qui
            // consomme parfois les trois secondes du budget d'une commande.
            // Les deux essais sont séquentiels — c'est tout leur objet — mais
            // courts : un refus NECP revient en quelques millisecondes, et le
            // délai ne joue que si Milō est injoignable. Les allonger ferait
            // dépasser à cette tâche la durée de vie de son propre processus, et
            // l'écriture ci-dessous n'atterrirait jamais — surtout pas dans le
            // cas « LAN injoignable » que la sonde existe pour décrire.
            let ipFirst = await probeResult(ipURL, timeout: 2)
            let ipSecond = await probeResult(ipURL, timeout: 2)

            // Clé dédiée, pas le journal : celui-ci est un tableau réécrit en
            // lecture-modification-écriture par des appelants concurrents, assez
            // sollicité pour en chasser la sonde avant qu'on la lise.
            UserDefaults(suiteName: MiloAPIClient.appGroupID)?.set(
                "internet=\(await net) ip=\(ipFirst) ip2=\(ipSecond) mdns=\(await mdns)",
                forKey: "milo_ext_probe")
        }
    }

    nonisolated private static func probeResult(_ raw: String,
                                                 timeout: TimeInterval = 5) async -> String {
        guard !raw.isEmpty else { return "aucune IP connue" }
        guard let url = URL(string: raw) else { return "url?" }
        var r = URLRequest(url: url); r.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: r)
            return "\((response as? HTTPURLResponse)?.statusCode ?? -1)"
        } catch {
            return "KO(\((error as NSError).code))"
        }
    }

    var devices: [MediaDevice] {
        Self.runProbeOnce()
        miloLog.info("devices lu : \(self.attributes.devices.count, privacy: .public) enceinte(s)")
        return attributes.devices.map { device in
            MediaDevice(
                id: device.id,
                name: device.name,
                type: Self.deviceType(device.type),
                capabilities: [
                    .absoluteVolume(device.volume) { level in
                        // Tracé AVANT le réseau : « rien ne se passe » ne
                        // distingue pas une fermeture jamais appelée d'une
                        // requête qui échoue, et ce sont deux causes opposées.
                        miloLog.info("RAPPEL VOLUME \(device.id, privacy: .public) -> \(level, privacy: .public)")
                        Self.trace("onChange \(device.id) -> \(level)")
                        await MiloAPIClient.setClientVolume(mac: device.id,
                                                            normalized: level)
                    }
                ]
            )
        }
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
    nonisolated static func trace(_ message: String) {
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)
        var lines = defaults?.stringArray(forKey: "milo_ext_trace") ?? []
        lines.append("\(Date().formatted(date: .omitted, time: .standard)) \(message)")
        defaults?.set(Array(lines.suffix(20)), forKey: "milo_ext_trace")
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
