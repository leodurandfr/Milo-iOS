import CoreGraphics
import Foundation
import ImageIO
import NowPlaying
import Observation

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
        Self.trace("session construite \(attributes.id)")
        startObservingPushToken()
    }

    /// Le système remet ici les attributs poussés par Milō. Les stocker suffit :
    /// `@Observable` fait remonter le changement à l'interface Now Playing.
    func update(_ attributes: MiloSessionAttributes) {
        self.attributes = attributes
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
        guard let track = attributes.currentTrack else { return nil }

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
            artwork: artwork(for: track)
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
        guard let raw = track.artworkURL else { return nil }
        let absolute = raw.hasPrefix("/") ? MiloAPIClient.baseURL() + raw : raw
        guard let url = URL(string: absolute) else { return nil }
        return Artwork(id: raw) { _ in
            // Le fichier déposé par l'app d'abord : c'est le chemin nominal, et
            // le seul qui tienne dans le budget de dix secondes du système.
            if let file = MiloAPIClient.artworkCacheFile(for: raw),
               let data = try? Data(contentsOf: file), !data.isEmpty,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = Self.bounded(source) {
                UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                    .set("cache \(data.count)o \(image.width)x\(image.height)",
                         forKey: "milo_artwork_trace")
                return try ArtworkRepresentation(cgImage: image)
            }

            // Décodage par ImageIO puis `cgImage`, sans redimensionnement.
            //
            // Une version intermédiaire produisait une vignette à la taille
            // demandée — ce qui est en principe la bonne façon de faire, une
            // pochette de station faisant 1024×1024 pour un affichage de
            // 69 points. Elle a fait disparaître toutes les pochettes, y compris
            // celles qui marchaient, et sans laisser la moindre trace : ni
            // succès, ni échec, alors que les deux étaient écrits dans des clés
            // séparées. Une extension qui meurt n'écrit rien.
            //
            // Cette forme-ci est celle dont on a la preuve qu'elle aboutit
            // (mesuré : JPEG 600×600, 72 ko, décodé et rendu). Y revenir tant
            // qu'on n'a pas les journaux système de l'extension.
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1

            func note(_ step: String) {
                UserDefaults(suiteName: MiloAPIClient.appGroupID)?
                    .set("\(url.lastPathComponent) HTTP \(code) \(data.count)o \(step)",
                         forKey: "milo_artwork_trace")
            }

            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                note("source illisible, repli données brutes")
                return try ArtworkRepresentation(data: data)
            }

            // Borner la taille. Mesuré : une pochette décodée en 600×600
            // s'affiche, la même chaîne en 1024×1024 ne s'affiche pas, alors que
            // le téléchargement et le décodage réussissent dans les deux cas —
            // ce qui casse est en aval de nous.
            //
            // La borne est une constante, et c'est délibéré : une version
            // précédente la calculait depuis la taille demandée par le système,
            // avec un `Int(size.width)`. Une conversion qui **piège** en Swift
            // si la valeur est nulle ou non finie, ce qui tue l'extension sans
            // rien écrire — d'où « aucune image et aucune trace », jusque sur
            // les pochettes qui marchaient. On ne convertit plus rien.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                note("vignette \(image.width)x\(image.height)")
                return try ArtworkRepresentation(cgImage: image)
            }
            if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                note("original \(image.width)x\(image.height)")
                return try ArtworkRepresentation(cgImage: image)
            }
            note("repli données brutes")
            return try ArtworkRepresentation(data: data)
        }
    }

    // MARK: - Commandes

    var commands: [MediaCommand] {
        [
            .play { await MiloAPIClient.fireTransport(.play) },
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
            async let net = probeResult("https://www.apple.com")
            async let ip = probeResult(MiloAPIClient.baseURL() + "/api/volume/state")
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
                        Self.trace("onChange \(device.id) -> \(level)")
                        await MiloAPIClient.setClientVolume(mac: device.id,
                                                            normalized: level)
                    }
                ]
            )
        }
    }

    /// Décode en bornant la taille.
    ///
    /// Tout le reste a été éliminé par la mesure : le fichier est lu depuis le
    /// cache partagé, décodé, et rendu au système — et il ne s'affiche pourtant
    /// pas. La seule différence restante avec les pochettes qui passent est la
    /// taille : 600×600 s'affiche, 1024×1024 non, et le journal système demande
    /// un `fittingSize` de 171 points.
    ///
    /// La borne est une constante, délibérément. Une version antérieure la
    /// calculait depuis la taille demandée par le système, avec un
    /// `Int(size.width)` — conversion qui **piège** en Swift sur une valeur
    /// nulle ou non finie, et tue l'extension sans rien écrire. On ne convertit
    /// plus rien.
    nonisolated static func bounded(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
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
        if let token = pushToken {
            Task { await MiloAPIClient.registerPushToken(token, kind: .session, sessionID: id) }
        }
        Task { [weak self] in
            guard let self else { return }
            for await token in pushTokenUpdates {
                await MiloAPIClient.registerPushToken(token, kind: .session, sessionID: self.id)
            }
        }
    }
}
