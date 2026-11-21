import Foundation
import Network
import Security

struct CameraRemoteSettings: Codable {
    var enabled = false
    var port: UInt16 = 48760
    var password = String(CameraRemoteCoding.randomSecret().prefix(24))
    var identityPassword = CameraRemoteCoding.randomSecret()
}

final class CameraRemoteIdentity {
    let directory: URL
    private(set) var settings: CameraRemoteSettings
    private(set) var fingerprint = ""

    init(directory: URL) {
        self.directory = directory
        settings = (try? Data(contentsOf: directory.appendingPathComponent("settings.json"))).flatMap { try? JSONDecoder().decode(CameraRemoteSettings.self, from: $0) } ?? CameraRemoteSettings()
    }

    func save(_ value: CameraRemoteSettings) throws {
        guard value.password.utf8.count >= 12 else { throw failure("连接密码至少需要 12 个字符。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        settings = value
    }

    func parameters() throws -> NWParameters {
        try save(settings)
        let archive = directory.appendingPathComponent("identity.p12")
        if !FileManager.default.fileExists(atPath: archive.path) { try createIdentity(archive) }
        let data = try Data(contentsOf: archive)
        var imported: CFArray?
        guard #available(macOS 15, *) else { throw failure("手机加密连接需要 macOS 15 或更高版本。") }
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: settings.identityPassword, kSecImportToMemoryOnly as String: true] as CFDictionary, &imported)
        guard status == errSecSuccess, let item = (imported as? [[String: Any]])?.first,
              let identityValue = item[kSecImportItemIdentity as String], let certificates = item[kSecImportItemCertChain as String] as? [SecCertificate],
              let certificate = certificates.first else { throw failure("无法读取手机连接证书，请重新建立连接配置。") }
        let identity = identityValue as! SecIdentity
        guard let protocolIdentity = sec_identity_create(identity) else { throw failure("无法建立加密连接。") }
        fingerprint = CameraRemoteCoding.fingerprint(SecCertificateCopyData(certificate) as Data)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, protocolIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func createIdentity(_ archive: URL) throws {
        let key = directory.appendingPathComponent("identity-key.pem")
        let certificate = directory.appendingPathComponent("identity-cert.pem")
        defer {
            try? FileManager.default.removeItem(at: key)
            try? FileManager.default.removeItem(at: certificate)
        }
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", certificate.path, "-days", "3650", "-subj", "/CN=WireCamera"])
        try run(["pkcs12", "-export", "-out", archive.path, "-inkey", key.path, "-in", certificate.path, "-passout", "env:WIRECAMERA_IDENTITY_PASSWORD"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["WIRECAMERA_IDENTITY_PASSWORD": settings.identityPassword]) { _, value in value }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("无法生成手机连接证书。") }
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "WireCamera.RemoteIdentity", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
