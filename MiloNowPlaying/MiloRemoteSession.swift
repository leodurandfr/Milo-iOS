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
    func update(_ attributes: MiloSessionAttributes) {
        self.attributes = attributes
        miloLog.info("update reçu \(attributes.id, privacy: .public)")
        Self.trace("update reçu")
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
               let data = try? Data(contentsOf: file), !data.isEmpty {
                miloLog.info("cache servi brut : \(data.count, privacy: .public) o")
                UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                    .set("cache brut \(data.count)o", forKey: "milo_artwork_trace")
                return try ArtworkRepresentation(data: data)
            }
            miloLog.info("cache absent ou vide, repli sur le réseau")

            // Repli réseau, mêmes règles : on rend les octets, on ne décode
            // pas. Il ne sert plus que si l'app n'a pas eu le temps de déposer
            // le fichier — elle est le chemin nominal depuis 54fc28c.
            //
            // Le téléchargement est le seul point du fournisseur qui puisse
            // jeter sans qu'on s'en aperçoive : l'erreur remonte au système,
            // qui l'avale, et rien n'était écrit — un échec y était alors
            // indiscernable d'un fournisseur jamais appelé.
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(from: url)
            } catch {
                miloLog.error("""
                    réseau : échec \(url.lastPathComponent, privacy: .public) — \
                    \((error as NSError).code, privacy: .public) \
                    \(error.localizedDescription, privacy: .public)
                    """)
                throw error
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            miloLog.info("réseau servi : HTTP \(code, privacy: .public), \(data.count, privacy: .public) o")
            UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                .set("réseau HTTP \(code) \(data.count)o", forKey: "milo_artwork_trace")
            return try ArtworkRepresentation(data: data)
        }
    }

    // MARK: - Commandes

    var commands: [MediaCommand] {
        miloLog.info("commands lu")
        return [
            .play {
                miloLog.info("RAPPEL COMMANDE play")
                await MiloAPIClient.fireTransport(.play)
            },
            .pause { await MiloAPIClient.fireTransport(.pause) },
            .togglePlayPause { await MiloAPIClient.fireTransport(.playPause) },
            .next { await MiloAPIClient.fireTransport(.next) },
            .previous { await MiloAPIClient.fireTransport(.previous) },
            .seekToPosition { position in
                await MiloAPIClient.fireSeek(toSeconds: position)
            }
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

            async let net = probeResult("https://www.apple.com")
            async let ip = probeResult(
                ipHost.isEmpty ? "" : "http://\(ipHost)/api/volume/state")
            async let mdns = probeResult("http://milo.local/api/volume/state")
            // Clé dédiée, pas le journal : celui-ci est un tableau réécrit en
            // lecture-modification-écriture par des appelants concurrents, assez
            // sollicité pour en chasser la sonde avant qu'on la lise.
            UserDefaults(suiteName: MiloAPIClient.appGroupID)?.set(
                "internet=\(await net) ip=\(await ip) mdns=\(await mdns)",
                forKey: "milo_ext_probe")
        }
    }

    nonisolated private static func probeResult(_ raw: String) async -> String {
        guard !raw.isEmpty else { return "aucune IP connue" }
        guard let url = URL(string: raw) else { return "url?" }
        var r = URLRequest(url: url); r.timeoutInterval = 5
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
    private func startObservingPushToken() {
        let sessionID = id

        if let token = pushToken {
            Task {
                _ = await MiloAPIClient.registerPushToken(
                    token, kind: .session, sessionID: sessionID)
            }
        }

        // Ne capturer que l'identifiant et le flux — surtout pas `self`.
        //
        // `[weak self]` suivi d'un `guard let self` ne protège de rien devant un
        // `for await` sans fin : la garde rend une référence **forte** que la
        // boucle tient jusqu'à la fin du processus, ce que le `[weak self]`
        // était précisément censé empêcher. Le corps n'a besoin de rien d'autre
        // que `sessionID`, donc il ne capture rien d'autre.
        let updates = pushTokenUpdates
        Task {
            for await token in updates {
                _ = await MiloAPIClient.registerPushToken(
                    token, kind: .session, sessionID: sessionID)
            }
        }
    }
}
