import CryptoKit
import Foundation

struct CameraPersonEvent: Codable {
    var start: Double
    var end: Double
}

struct CameraRecording: Codable, Identifiable {
    let id: String
    let sourceID: String
    let sourceName: String
    let startedAt: Date
    let duration: Double
    var events: [CameraPersonEvent]
    var indexState: String
    var motionEvents: [CameraPersonEvent]?
    var motionIndexState: String?
    var motionIndexVersion: Int?

    var filename: String { id + ".mov" }
}

struct CameraRemoteDevice: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let online: Bool
    let recording: Bool
}

struct CameraRemoteChallenge: Codable {
    let nonce: String
    let proof: String
}

struct CameraRemotePairRequest: Codable {
    let nonce: String
    let proof: String
}

struct CameraRemotePairResult: Codable {
    let token: String
}

struct CameraPlaybackTicket: Codable {
    let id: String
    let expiresIn: Double
}

enum CameraRemoteCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func proof(_ message: String, password: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(password.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ proof: String, message: String, password: String) -> Bool {
        guard proof.utf8.count == 64, proof.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return false }
        let bytes = stride(from: 0, to: 64, by: 2).compactMap { index -> UInt8? in
            let start = proof.index(proof.startIndex, offsetBy: index)
            return UInt8(proof[start..<proof.index(start, offsetBy: 2)], radix: 16)
        }
        return bytes.count == 32 && HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Data(message.utf8), using: SymmetricKey(data: Data(password.utf8)))
    }

    static func fingerprint(_ certificate: Data) -> String { SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined() }

    static func randomSecret() -> String { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
}
