import Foundation
import Security
import UniformTypeIdentifiers

// MARK: - Preferences


/// Settings › Drop. The password lives in the Keychain, never here.
struct DropPreferences: Codable, Equatable, Sendable {
    var baseURL = "https://drop.thibthev.com"
    var expiry: DropExpiry = .never
    var linkStyle: DropLinkStyle = .page
    var copyLink = true
    var openLink = false
    var showInFinder = true
    var showInShare = true
    /// Main window: send every result to Drop once the batch is processed.
    var afterProcessing = false
}

// MARK: - Errors

enum DropError: LocalizedError {
    case notConfigured
    case badURL(String)
    case wrongPassword
    case tooManyAttempts
    case server(Int, String?)
    case network(String)
    case missingFile(String)
    case zipFailed(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Drop n'est pas configuré : ouvrez Réglages › Drop (ou `forma drop login`)."
        case .badURL(let s): "Adresse Drop invalide : « \(s) »."
        case .wrongPassword: "Mot de passe Drop refusé."
        case .tooManyAttempts: "Trop de tentatives : réessayez dans une minute."
        case .server(let code, let message): "Drop a répondu \(code)\(message.map { " : \($0)" } ?? "")."
        case .network(let m): "Drop est injoignable : \(m)"
        case .missingFile(let n): "« \(n) » n'existe plus."
        case .zipFailed(let n): "Impossible de compresser le dossier « \(n) »."
        case .badResponse: "Réponse inattendue de Drop."
        }
    }
}

// MARK: - Keychain

enum DropKeychain {
    static let service = "com.thibault.forma.drop"

    static func password(for host: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: host, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(for host: String) -> Bool { password(for: host) != nil }

    static func save(_ password: String, for host: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: host]
        let data = Data(password.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Forma — Drop (\(host))"
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw DropError.network("Trousseau : erreur \(s)") }
        } else if status != errSecSuccess {
            throw DropError.network("Trousseau : erreur \(status)")
        }
    }

    static func delete(for host: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: host]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Server

/// A Drop server and the password to open its API (`/api/auth` gives a session cookie).
struct DropServer: Sendable {
    var base: URL
    var password: String
    var host: String { base.host() ?? base.absoluteString }

    /// "drop.example.com" and "https://drop.example.com/" both give `https://drop.example.com`.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    static func host(of prefs: DropPreferences) -> String? { normalize(prefs.baseURL)?.host() }

    /// Throws `.notConfigured` until a password is stored for the host.
    static func current(_ prefs: DropPreferences) throws -> DropServer {
        guard let base = normalize(prefs.baseURL) else { throw DropError.badURL(prefs.baseURL) }
        guard let host = base.host(), let pw = DropKeychain.password(for: host), !pw.isEmpty else { throw DropError.notConfigured }
        return DropServer(base: base, password: pw)
    }

    static func isConfigured(_ prefs: DropPreferences) -> Bool {
        host(of: prefs).map(DropKeychain.hasPassword(for:)) ?? false
    }
}

/// One file as the dashboard API describes it.
struct DropFile: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var size: Int64
    /// Milliseconds since 1970.
    var modified: Double
    var kind: String
    var expiresAt: Double?
    var views: Int
    var downloads: Int
    var id: String { key }
    var name: String { key.split(separator: "/").last.map(String.init) ?? key }
    var expiry: Date? { expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var date: Date { Date(timeIntervalSince1970: modified / 1000) }
}


// MARK: - Client

/// HTTP client of the Drop dashboard API: `PUT /api/files?name=&ttl=` (streaming upload), `GET /api/files`,
/// `PATCH` and `DELETE /api/files/<clé>`. One login per server per process.
final class DropClient: @unchecked Sendable {
    static let shared = DropClient()

    private let lock = NSLock()
    private var cookies: [String: String] = [:]
    private let session: URLSession

    private init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 6 * 3600
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpMaximumConnectionsPerHost = 4
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c)
    }

    // MARK: Session

    private func cookie(for server: DropServer) -> String? { lock.withLock { cookies[server.base.absoluteString] } }
    private func store(_ cookie: String?, for server: DropServer) { lock.withLock { cookies[server.base.absoluteString] = cookie } }

    /// Opens a session (a 90-day cookie). Called lazily and again whenever the server answers 401.
    @discardableResult
    func login(_ server: DropServer) async throws -> String {
        var req = URLRequest(url: server.base.appendingPathComponent("api/auth"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["password": server.password])
        let (data, response) = try await perform { try await self.session.data(for: req) }
        guard let http = response as? HTTPURLResponse else { throw DropError.badResponse }
        switch http.statusCode {
        case 200:
            let fields = http.allHeaderFields.reduce(into: [String: String]()) { if let k = $1.key as? String, let v = $1.value as? String { $0[k] = v } }
            let found = HTTPCookie.cookies(withResponseHeaderFields: fields, for: server.base).first { $0.name == "drop_session" }
            guard let found else { throw DropError.badResponse }
            let header = "\(found.name)=\(found.value)"
            store(header, for: server)
            return header
        case 401: throw DropError.wrongPassword
        case 429: throw DropError.tooManyAttempts
        default: throw DropError.server(http.statusCode, Self.message(data))
        }
    }

    private func ensureCookie(_ server: DropServer) async throws -> String {
        if let c = cookie(for: server) { return c }
        return try await login(server)
    }

    /// Network errors become `DropError.network`, with up to two retries for the transient ones.
    private func perform<T>(_ op: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await op() }
            catch let e as URLError where e.code == .cancelled { throw CancellationError() }
            catch let e as URLError {
                let transient: Set<URLError.Code> = [.networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed]
                attempt += 1
                if transient.contains(e.code), attempt <= 2 {
                    try await Task.sleep(for: .seconds(Double(attempt)))
                    continue
                }
                throw DropError.network(e.localizedDescription)
            }
        }
    }

    private static func message(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    /// Sends an authenticated request, logging in again once if the session expired.
    private func send(_ make: (String) -> URLRequest, server: DropServer,
                      body: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> (Data, HTTPURLResponse) {
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = body ?? { [session] in try await session.data(for: $0) }
        for attempt in 0..<2 {
            let cookie = try await ensureCookie(server)
            let req = make(cookie)
            let (data, response) = try await perform { try await transport(req) }
            guard let http = response as? HTTPURLResponse else { throw DropError.badResponse }
            if http.statusCode == 401, attempt == 0 { store(nil, for: server); continue }
            if http.statusCode == 401 { throw DropError.wrongPassword }
            return (data, http)
        }
        throw DropError.badResponse
    }

    // MARK: API

    /// Uploads one file and returns the server's record. `progress` is 0…1 (capped at 0.99 until the server confirms).
    func upload(_ file: URL, name: String, expiry: DropExpiry, server: DropServer,
                progress: @escaping @Sendable (Double) -> Void) async throws -> DropFile {
        var comps = URLComponents(url: server.base.appendingPathComponent("api/files"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "name", value: name)]
        if let ttl = expiry.seconds { items.append(URLQueryItem(name: "ttl", value: String(ttl))) }
        comps.queryItems = items
        let endpoint = comps.url!
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let delegate = UploadProgress(progress)
        let (data, http) = try await send({ cookie in
            var r = URLRequest(url: endpoint)
            r.httpMethod = "PUT"
            r.setValue(mime, forHTTPHeaderField: "Content-Type")
            r.setValue(cookie, forHTTPHeaderField: "Cookie")
            return r
        }, server: server, body: { req in try await self.session.upload(for: req, fromFile: file, delegate: delegate) })
        guard http.statusCode == 200 else { throw DropError.server(http.statusCode, Self.message(data)) }
        struct Envelope: Decodable { var file: DropFile }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { throw DropError.badResponse }
        progress(1)
        return env.file
    }

    func list(server: DropServer) async throws -> [DropFile] {
        let endpoint = server.base.appendingPathComponent("api/files")
        let (data, http) = try await send({ cookie in
            var r = URLRequest(url: endpoint)
            r.setValue(cookie, forHTTPHeaderField: "Cookie")
            return r
        }, server: server)
        guard http.statusCode == 200 else { throw DropError.server(http.statusCode, Self.message(data)) }
        struct Envelope: Decodable { var files: [DropFile] }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { throw DropError.badResponse }
        return env.files
    }

    private func fileEndpoint(_ key: String, _ server: DropServer) -> URL {
        URL(string: server.base.absoluteString + "/api/files/" + DropLinks.encode(key))!
    }

    func delete(key: String, server: DropServer) async throws {
        let endpoint = fileEndpoint(key, server)
        let (data, http) = try await send({ cookie in
            var r = URLRequest(url: endpoint)
            r.httpMethod = "DELETE"
            r.setValue(cookie, forHTTPHeaderField: "Cookie")
            return r
        }, server: server)
        guard http.statusCode == 200 else { throw DropError.server(http.statusCode, Self.message(data)) }
    }

    /// `nil` removes the expiry.
    func setExpiry(key: String, to date: Date?, server: DropServer) async throws {
        let endpoint = fileEndpoint(key, server)
        let value: Any = date.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull()
        let body = try JSONSerialization.data(withJSONObject: ["expiresAt": value])
        let (data, http) = try await send({ cookie in
            var r = URLRequest(url: endpoint)
            r.httpMethod = "PATCH"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(cookie, forHTTPHeaderField: "Cookie")
            r.httpBody = body
            return r
        }, server: server)
        guard http.statusCode == 200 else { throw DropError.server(http.statusCode, Self.message(data)) }
    }

    /// Logs in and lists: proves URL, password and network at once. Returns the number of files.
    func verify(_ server: DropServer) async throws -> Int {
        store(nil, for: server)
        try await login(server)
        return try await list(server: server).count
    }

    func forget(_ server: DropServer) { store(nil, for: server) }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let handler: @Sendable (Double) -> Void
    private var last = -1.0
    init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        guard p - last >= 0.01 else { return }
        last = p
        handler(p)
    }
}
