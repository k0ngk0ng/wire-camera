import Foundation
import Security

struct CameraRemoteCredentials: Codable, Identifiable {
    let host: String
    let port: Int
    let token: String
    let fingerprint: String
    var password: String?
    var id: String { host.lowercased() + ":" + String(port) }
}

enum CameraRemoteFailure: LocalizedError {
    case message(String)
    case expired
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .expired: return "连接凭据已过期，请重新输入 Mac 上的密码。"
        }
    }
}

final class CameraRemoteClient {
    let credentials: CameraRemoteCredentials
    private let trust: CameraRemoteTrust
    private let session: URLSession

    init(credentials: CameraRemoteCredentials) {
        self.credentials = credentials
        trust = CameraRemoteTrust(fingerprint: credentials.fingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        #if os(iOS)
        let legacy = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("WireCameraMovies")
        try? FileManager.default.removeItem(at: legacy)
        #endif
    }

    static func pair(host: String, port: Int, password: String, fingerprint: String? = nil) async throws -> CameraRemoteClient {
        guard (1...65535).contains(port), !host.isEmpty, !host.contains("/"), !host.contains("@"), !host.contains(" ") else { throw CameraRemoteFailure.message("请输入 Mac 的 IP 地址或主机名，以及 1–65535 的端口。") }
        let trust = CameraRemoteTrust(fingerprint: fingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let challengeURL = try endpoint(host: host, port: port, path: "/v1/challenge")
        let (data, response) = try await session.data(from: challengeURL)
        try validate(response)
        let challenge = try CameraRemoteCoding.decoder.decode(CameraRemoteChallenge.self, from: data)
        guard let fingerprint = trust.fingerprint, CameraRemoteCoding.matches(challenge.proof, message: "server|\(challenge.nonce)|\(fingerprint)", password: password) else { throw CameraRemoteFailure.message("密码不正确，或连接的不是这台 Mac。请核对 Mac 上的连接配置。") }
        trust.pin(fingerprint)
        var request = URLRequest(url: try endpoint(host: host, port: port, path: "/v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try CameraRemoteCoding.encoder.encode(CameraRemotePairRequest(nonce: challenge.nonce, proof: CameraRemoteCoding.proof("client|\(challenge.nonce)|\(fingerprint)", password: password)))
        let (resultData, resultResponse) = try await session.data(for: request)
        try validate(resultResponse)
        let result = try CameraRemoteCoding.decoder.decode(CameraRemotePairResult.self, from: resultData)
        return CameraRemoteClient(credentials: CameraRemoteCredentials(host: host, port: port, token: result.token, fingerprint: fingerprint, password: password))
    }

    func fetch<Value: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        let (data, response) = try await session.data(for: request(path, query: query))
        try Self.validate(response)
        return try CameraRemoteCoding.decoder.decode(Value.self, from: data)
    }

    func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        var request = URLRequest(url: try Self.endpoint(host: credentials.host, port: credentials.port, path: path, query: query))
        request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
        return request
    }

    func playbackResource(_ entry: CameraRecording) throws -> CameraPlaybackResource {
        guard UUID(uuidString: entry.id) != nil else { throw CameraRemoteFailure.message("录像标识不正确。") }
        return CameraPlaybackResource(request: try request("/v1/recordings/\(entry.id)/movie"), fingerprint: credentials.fingerprint)
    }

    func close() { session.invalidateAndCancel() }

    private static func endpoint(host: String, port: Int, path: String, query: [URLQueryItem] = []) throws -> URL {
        var url = URLComponents()
        url.scheme = "https"; url.host = host; url.port = port; url.path = path
        if !query.isEmpty { url.queryItems = query }
        guard let result = url.url else { throw CameraRemoteFailure.message("Mac 地址格式不正确。") }
        return result
    }

    static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw CameraRemoteFailure.message("Mac 返回了无法识别的响应。") }
        if response.statusCode == 401 { throw CameraRemoteFailure.expired }
        if response.statusCode == 429 { throw CameraRemoteFailure.message("连接次数过多，请稍后重试。") }
        guard (200..<300).contains(response.statusCode) else { throw CameraRemoteFailure.message("Mac 暂时无法提供这段画面，请刷新后重试（\(response.statusCode)）。") }
    }
}

enum CameraRemoteKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.wirecamera.iphone", kSecAttrAccount as String: CommandLine.arguments.contains("--ui-test") ? "mac-connection-e2e" : "mac-connection"] }

    static func load() -> CameraRemoteCredentials? {
        loadAll().first
    }

    static func loadAll() -> [CameraRemoteCredentials] {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        if let values = try? JSONDecoder().decode([CameraRemoteCredentials].self, from: data) { return values }
        return (try? JSONDecoder().decode(CameraRemoteCredentials.self, from: data)).map { [$0] } ?? []
    }

    static func save(_ credentials: CameraRemoteCredentials) throws {
        var values = loadAll().filter { $0.id != credentials.id }
        values.insert(credentials, at: 0)
        try persist(values)
    }

    private static func persist(_ values: [CameraRemoteCredentials]) throws {
        let data = try JSONEncoder().encode(values)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw CameraRemoteFailure.message("连接已建立，但无法保存凭据。重新打开 App 后需要再次输入密码。") }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CameraRemoteFailure.message("连接已建立，但无法保存凭据。重新打开 App 后需要再次输入密码。") }
    }

    static func remove() { SecItemDelete(query as CFDictionary) }

    static func forget(_ id: String) throws { try persist(loadAll().filter { $0.id != id }) }
}
