import Foundation
import Network

/// Une requête HTTP vers Milō, **liée à l'interface Wi-Fi**.
///
/// `URLSession` ne sait pas lier une requête à une interface, et c'est ce qui
/// manquait ici. Mesuré le 25/09/2026 à 10:46:18 : la résolution de
/// `milo.local` part sur deux chemins concurrents, le mDNS du Wi-Fi et le DNS
/// unicast du tunnel Tailscale (`utun5`, route Split DNS `local`). Le tunnel a
/// répondu le premier, en 23 ms, et son adresse n'est liée à aucune interface —
/// or `mediaremoted` pose une restriction réseau sur cette extension, et un
/// chemin non lié vers le LAN y est `denied by NECP policy`. Échec en 27 ms,
/// sans second tirage : le token de session n'est jamais arrivé à Milō, qui n'a
/// donc envoyé aucun `update`, et la carte est restée sur l'instantané du
/// `start` — en pause, à 0:00.
///
/// `requiredInterfaceType = .wifi` fait tout partir d'en0, résolution comprise :
/// le tunnel n'entre plus dans la course.
///
/// Volontairement minimal — HTTP/1.1, `Connection: close`, un corps lu jusqu'à
/// la fermeture. Milō est derrière nginx sur le LAN, et c'est tout ce qu'on
/// lui demande.
enum MiloScopedHTTP {

    struct Response {
        let status: Int
        let body: Data
    }

    enum Failure: Error, CustomStringConvertible {
        case timedOut(String)
        case connection(NWError)
        case malformed

        var description: String {
            switch self {
            case .timedOut(let state): return "délai dépassé (\(state))"
            case .connection(let error): return "\(error)"
            case .malformed: return "réponse illisible"
            }
        }
    }

    /// Le transport posé dans `MiloAPIClient.scopedTransport`.
    ///
    /// L'adresse que l'app a résolue et sondée d'abord : liée au Wi-Fi, une IP
    /// passe (sonde du 25/09/2026 à 12:31:09 — `wifi 192.168.1.55=200 38ms`,
    /// quand la même IP non liée échoue en -1009), et elle ne demande aucune
    /// résolution, donc aucune course contre le tunnel. `milo.local` ensuite,
    /// lié lui aussi, si l'adresse manque ou ne répond pas — le bail a pu
    /// changer depuis que l'app l'a notée.
    ///
    /// Le délai de la requête est partagé entre les deux essais : l'appelant
    /// l'a réglé sur le budget de son rappel, et on ne le dépasse pas.
    static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?" + query }

        let cachedIP = UserDefaults(suiteName: MiloAPIClient.appGroupID)?
            .string(forKey: MiloAPIClient.ipAddressKey)
        let hosts = [cachedIP, "milo.local"].compactMap { $0 }.filter { !$0.isEmpty }
        let total = request.timeoutInterval > 0 ? min(request.timeoutInterval, 10) : 3

        var lastError: Error = URLError(.cannotConnectToHost)
        for (index, host) in hosts.enumerated() {
            let isLast = index == hosts.count - 1
            let timeout = isLast ? total / Double(index + 1) : total / 2
            let start = Date()
            do {
                let response = try await send(method: request.httpMethod ?? "GET",
                                              host: host, path: target,
                                              body: request.httpBody,
                                              contentType: request.value(forHTTPHeaderField: "Content-Type")
                                                  ?? "application/json",
                                              accept: request.value(forHTTPHeaderField: "Accept"),
                                              timeout: timeout)
                miloLog.info("""
                    LAN lié \(host, privacy: .public) \(target, privacy: .public) → \
                    \(response.status, privacy: .public) en \
                    \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms
                    """)
                let http = HTTPURLResponse(url: url, statusCode: response.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)
                return (response.body, http ?? URLResponse())
            } catch {
                miloLog.error("""
                    LAN lié \(host, privacy: .public) \(target, privacy: .public) : \
                    \(String(describing: error), privacy: .public) après \
                    \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms
                    """)
                lastError = error
                if Task.isCancelled { throw URLError(.cancelled) }
            }
        }
        // Rendu en erreur d'URL : les appelants trient sur `NSURLErrorDomain`
        // — un délai n'appelle pas la même lecture qu'un refus.
        if case Failure.timedOut = lastError { throw URLError(.timedOut) }
        throw URLError(.cannotConnectToHost)
    }

    static func send(method: String,
                     host: String,
                     path: String,
                     body: Data? = nil,
                     contentType: String = "application/json",
                     accept: String? = nil,
                     timeout: TimeInterval) async throws -> Response {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 80, using: parameters)

        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
        head += "User-Agent: MiloNowPlayingExtension/1 scoped\r\n"
        if let accept { head += "Accept: \(accept)\r\n" }
        if let body {
            head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var request = Data(head.utf8)
        if let body { request.append(body) }

        let payload = request
        let queue = DispatchQueue(label: "milo.scoped-http")
        let exchange = Exchange()
        let raw: Data = try await withCheckedThrowingContinuation { continuation in
            @Sendable func finish(_ result: Result<Data, Error>) {
                guard exchange.close() else { return }
                connection.cancel()
                continuation.resume(with: result)
            }

            @Sendable func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { chunk, _, complete, error in
                    let received = exchange.append(chunk)
                    if complete || Self.isComplete(received) {
                        finish(.success(received))
                    } else if let error {
                        finish(.failure(Failure.connection(error)))
                    } else {
                        receive()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                exchange.note(state)
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error { finish(.failure(Failure.connection(error))) }
                    })
                    receive()
                case .failed(let error):
                    finish(.failure(Failure.connection(error)))
                default:
                    // `waiting` compris : un chemin refusé attend, et c'est le
                    // délai qui tranche — l'état noté dit alors pourquoi.
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(Failure.timedOut(exchange.lastState)))
            }
            connection.start(queue: queue)
        }
        return try parse(raw)
    }

    /// Ce que les rappels de `NWConnection` partagent, sous verrou : ils
    /// arrivent sur la file de la connexion, le délai sur la même, mais rien
    /// ne garantit l'ordre entre une fin de lecture et l'expiration.
    private final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var received = Data()
        private var state = "setup"

        var lastState: String { lock.withLock { state } }

        func note(_ state: NWConnection.State) { lock.withLock { self.state = "\(state)" } }

        func append(_ chunk: Data?) -> Data {
            lock.withLock {
                if let chunk { received.append(chunk) }
                return received
            }
        }

        /// Vrai pour le seul premier appelant.
        func close() -> Bool {
            lock.withLock {
                defer { finished = true }
                return !finished
            }
        }
    }

    /// Le corps est-il complet d'après `Content-Length` ? Sans lui, on attend
    /// la fermeture, que `Connection: close` garantit.
    private static func isComplete(_ data: Data) -> Bool {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8)
        else { return false }
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
               let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                return data.count - split.upperBound >= length
            }
        }
        return false
    }

    private static func parse(_ data: Data) throws -> Response {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8),
              let statusLine = head.split(separator: "\r\n").first
        else { throw Failure.malformed }
        let fields = statusLine.split(separator: " ")
        guard fields.count >= 2, let status = Int(fields[1]) else { throw Failure.malformed }
        let body = Data(data[split.upperBound...])
        let chunked = head.lowercased().contains("transfer-encoding: chunked")
        return Response(status: status, body: chunked ? try dechunk(body) : body)
    }

    /// Un corps que nginx relaie en morceaux, rendu d'un seul tenant.
    private static func dechunk(_ data: Data) throws -> Data {
        var out = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while let lineEnd = data.range(of: crlf, in: index..<data.endIndex) {
            let sizeField = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16)
            else { throw Failure.malformed }
            if size == 0 { return out }
            let start = lineEnd.upperBound
            guard data.distance(from: start, to: data.endIndex) >= size else { throw Failure.malformed }
            let end = data.index(start, offsetBy: size)
            out.append(data[start..<end])
            index = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}
