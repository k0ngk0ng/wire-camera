import CommonCrypto
import Foundation

struct CameraModuleIdentity {
    let deviceID: String
    let salt: String
    let address: String?

    init(deviceID: String, salt: String, address: String? = nil) {
        self.deviceID = deviceID
        self.salt = salt
        self.address = address
    }
}

private func moduleProtocolFailure(_ message: String) -> NSError {
    NSError(domain: "WireCamera.ModuleProtocol", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private struct ModuleProtocolReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    var remaining: Int { bytes.count - offset }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw moduleProtocolFailure("模块报文不完整。") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func data(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw moduleProtocolFailure("模块报文长度不正确。") }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let next = try byte()
            guard shift < 63 || next <= 1 else { throw moduleProtocolFailure("模块报文中的整数超出范围。") }
            value |= UInt64(next & 0x7f) << shift
            if next & 0x80 == 0 {
                guard shift == 0 || next != 0 else { throw moduleProtocolFailure("模块报文中的整数编码不正确。") }
                return value
            }
        }
        throw moduleProtocolFailure("模块报文中的整数编码不正确。")
    }

    mutating func string() throws -> String {
        let length = Int(try byte())
        let value = try data(count: length)
        guard let string = String(data: value, encoding: .utf8) else { throw moduleProtocolFailure("模块报文包含无效的文本编码。") }
        return string
    }
}

enum CameraModuleProtocol {
    private static let key = Data("UI3lQZ920C57E972YvuvvhRbIea3KXjj".utf8)
    private static let iv = Data("YvuvvhRbIea3KXjj".utf8)

    static func validateCredentials(ssid: String, password: String) -> String? {
        guard !ssid.isEmpty else { return "请输入 2.4 GHz Wi-Fi 名称。" }
        guard ssid.utf8.count <= 32 else { return "Wi-Fi 名称的 UTF-8 编码不能超过 32 字节。" }
        guard !ssid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "Wi-Fi 名称不能包含控制字符。" }
        guard password.isEmpty || (8...63).contains(password.utf8.count) else { return "Wi-Fi 密码需要为 8 至 63 字节；开放网络可留空。" }
        guard !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "Wi-Fi 密码不能包含控制字符。" }
        return nil
    }

    static func configurationPackets(ssid: String, password: String, verificationCode: String = "", timestamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) throws -> [Data] {
        if let message = validateCredentials(ssid: ssid, password: password) { throw moduleProtocolFailure(message) }
        var plaintext = Data([0x06, 0, 0, 0])
        plaintext.append(contentsOf: varint(timestamp))
        plaintext.append(1)
        plaintext.append(contentsOf: varint(10008))
        plaintext.append(contentsOf: [0, 3])
        for string in [ssid, password, verificationCode] {
            let bytes = Data(string.utf8)
            guard bytes.count <= 255 else { throw moduleProtocolFailure("模块配置字段过长。") }
            guard !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw moduleProtocolFailure("模块配置字段不能包含控制字符。") }
            plaintext.append(UInt8(bytes.count))
            plaintext.append(bytes)
        }
        plaintext.append(contentsOf: [0, 0])
        let ciphertext = try crypt(plaintext, operation: CCOperation(kCCEncrypt))
        var encoded = Data([0x03])
        encoded.append(contentsOf: varint(UInt64(ciphertext.count)))
        encoded.append(ciphertext)
        guard encoded.count <= 255 else { throw moduleProtocolFailure("模块配置报文超过当前协议支持的长度。") }
        let total = (encoded.count + 16) / 17
        return (0..<total).map { index in
            let start = index * 17
            let end = min(start + 17, encoded.count)
            var packet = Data([UInt8(total), UInt8(index + 1), UInt8(end - start)])
            packet.append(encoded.subdata(in: start..<end))
            return packet
        }
    }

    static func decodeResponse(_ data: Data) throws -> CameraModuleIdentity {
        guard !data.isEmpty, data.count <= 4335 else { throw moduleProtocolFailure("模块响应长度不正确。") }
        var outer = ModuleProtocolReader(bytes: Array(data))
        guard try outer.byte() == 0x03 else { throw moduleProtocolFailure("模块响应使用了不支持的加密格式。") }
        let length = try outer.varint()
        guard length > 0, length <= UInt64(outer.remaining), length % 16 == 0, length == UInt64(outer.remaining) else { throw moduleProtocolFailure("模块响应的密文长度不正确。") }
        let plaintext = try crypt(try outer.data(count: Int(length)), operation: CCOperation(kCCDecrypt))
        var body = ModuleProtocolReader(bytes: Array(plaintext))
        guard try body.byte() >> 2 == 1 else { throw moduleProtocolFailure("模块响应使用了不支持的数据版本。") }
        _ = try body.string()
        _ = try body.string()
        _ = try body.varint()
        _ = try body.varint()
        let commandCount = Int(try body.byte())
        var identity: CameraModuleIdentity?
        for _ in 0..<commandCount {
            let command = try body.varint()
            let integerCount = Int(try body.byte())
            var integers: [UInt64] = []
            for _ in 0..<integerCount { integers.append(try body.varint()) }
            let stringCount = Int(try body.byte())
            var strings: [String] = []
            for _ in 0..<stringCount { strings.append(try body.string()) }
            let byteCount = try body.varint()
            guard byteCount <= UInt64(body.remaining) else { throw moduleProtocolFailure("模块响应中的数据长度不正确。") }
            _ = try body.data(count: Int(byteCount))
            let floatCount = Int(try body.byte())
            _ = try body.data(count: floatCount * 4)
            if command == 10008 {
                guard identity == nil else { throw moduleProtocolFailure("模块响应包含重复的配置结果。") }
                guard let status = integers.first else { throw moduleProtocolFailure("模块响应缺少配置状态。") }
                guard status == 0 else { throw moduleProtocolFailure("摄像头模块拒绝了配置（状态 \(Int64(bitPattern: status))）。") }
                guard strings.count >= 2, !strings[0].isEmpty, !strings[1].isEmpty else { throw moduleProtocolFailure("模块响应缺少设备标识或连接信息。") }
                identity = CameraModuleIdentity(deviceID: strings[0], salt: strings[1])
            }
        }
        guard body.remaining == 0 else { throw moduleProtocolFailure("模块响应包含多余的数据。") }
        guard let identity else { throw moduleProtocolFailure("模块响应没有包含配置结果。") }
        return identity
    }

    private static func varint(_ input: UInt64) -> [UInt8] {
        var value = input
        var bytes: [UInt8] = []
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
        return bytes
    }

    private static func crypt(_ input: Data, operation: CCOperation) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let options = operation == CCOperation(kCCEncrypt) ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(0)
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options, keyBytes.baseAddress, key.count, ivBytes.baseAddress, inputBytes.baseAddress, input.count, outputBytes.baseAddress, outputBytes.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw moduleProtocolFailure(operation == CCOperation(kCCEncrypt) ? "模块配置报文加密失败。" : "模块响应解密失败。") }
        output.removeSubrange(written..<output.count)
        if operation == CCOperation(kCCDecrypt) {
            guard let padding = output.last, (1...kCCBlockSizeAES128).contains(Int(padding)), Int(padding) <= output.count,
                  output.suffix(Int(padding)).allSatisfy({ $0 == padding }) else { throw moduleProtocolFailure("模块响应的加密填充不正确。") }
            output.removeLast(Int(padding))
        }
        return output
    }
}

struct CameraModulePacketAssembler {
    private var total: Int?
    private var fragments: [Int: Data] = [:]

    mutating func append(_ data: Data) throws -> Data? {
        do {
            let bytes = Array(data)
            guard bytes.count >= 4 else { throw moduleProtocolFailure("模块分包不完整。") }
            let count = Int(bytes[0])
            let index = Int(bytes[1])
            let length = Int(bytes[2])
            guard (1...255).contains(count), (1...count).contains(index), (1...17).contains(length), length == bytes.count - 3 else { throw moduleProtocolFailure("模块分包的序号或长度不正确。") }
            guard index == count || length == 17 else { throw moduleProtocolFailure("模块分包的中间片段长度不正确。") }
            guard total == nil || total == count else { throw moduleProtocolFailure("模块分包的总数发生变化。") }
            total = count
            let payload = Data(bytes.dropFirst(3))
            if let previous = fragments[index], previous != payload { throw moduleProtocolFailure("模块重复分包的内容不一致。") }
            fragments[index] = payload
            guard fragments.count == count else { return nil }
            var result = Data()
            for number in 1...count {
                guard let fragment = fragments[number] else { return nil }
                result.append(fragment)
            }
            reset()
            return result
        } catch {
            reset()
            throw error
        }
    }

    mutating func reset() {
        total = nil
        fragments.removeAll()
    }
}
