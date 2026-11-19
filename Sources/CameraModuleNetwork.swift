import CommonCrypto
import CoreFoundation
import CoreMedia
import CryptoKit
import Darwin
import Foundation

struct CameraModuleNetworkDevice: Equatable {
    let deviceID: String
    let address: String
    let port: Int
}

struct CameraModuleNetworkTarget {
    let device: CameraModuleNetworkDevice
    let signature: String
}

struct CameraModuleNetworkFrame {
    let command: UInt64
    let sequence: UInt64
    let rpc: UInt8
    let status: UInt64
    let body: Data
}

private func moduleNetworkFailure(_ message: String, systemError: Int32? = nil) -> NSError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: message]
    if let systemError { info[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: Int(systemError)) }
    return NSError(domain: "WireCamera.ModuleNetwork", code: 1, userInfo: info)
}

private struct ModuleNetworkReader {
    let bytes: [UInt8]
    var offset = 0

    var remaining: Int { bytes.count - offset }

    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw moduleNetworkFailure("模块网络报文不完整。") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func data(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw moduleNetworkFailure("模块网络报文长度不正确。") }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let next = try byte()
            guard shift < 63 || next <= 1 else { throw moduleNetworkFailure("模块网络报文的整数超出范围。") }
            value |= UInt64(next & 0x7f) << shift
            if next & 0x80 == 0 {
                guard shift == 0 || next != 0 else { throw moduleNetworkFailure("模块网络报文的整数编码不正确。") }
                return value
            }
        }
        throw moduleNetworkFailure("模块网络报文的整数编码不正确。")
    }
}

enum CameraModuleNetworkProtocol {
    static let maximumFrameSize = 8 * 1024 * 1024
    private static let defaultSeed = Data("A2r0i1m1a2M0a1x6toriQue".utf8)

    static func manualAddress(_ value: String) throws -> String {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = ipv4(address), unicast(parsed), address == [24, 16, 8, 0].map({ String((parsed >> $0) & 255) }).joined(separator: ".") else {
            throw moduleNetworkFailure("请输入有效的 IPv4 地址，例如 192.168.1.100。")
        }
        return address
    }

    static func discovery(deviceID: String? = nil) throws -> Data {
        var fields = ["cmd": "Discovery"]
        if let deviceID {
            guard validIdentifier(deviceID) else { throw moduleNetworkFailure("摄像头模块的设备标识不正确。") }
            fields["did"] = deviceID
        }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    static func binaryDiscovery(deviceID: String? = nil) throws -> Data {
        if let deviceID, !validIdentifier(deviceID) { throw moduleNetworkFailure("摄像头模块的设备标识不正确。") }
        return try encode(command: 2600, sequence: 1, body: deviceID.map { stringField(1, $0) } ?? Data(), udp: true)
    }

    static func discoveryResponse(_ data: Data, address: String, sourcePort: Int, expectedID: String? = nil, expectedAddress: String? = nil) throws -> CameraModuleNetworkTarget {
        guard data.count > 0, data.count <= 4096, (1...65535).contains(sourcePort), let source = ipv4(address), unicast(source), expectedAddress == nil || address == expectedAddress else {
            throw moduleNetworkFailure("发现响应的来源不正确。")
        }
        if data.starts(with: [0x51, 0x70]) {
            let response = try decode(data)
            guard response.command == 2600, response.rpc == 1, response.status == 0,
                  let identifier = try protobufString(response.body, field: 1), validIdentifier(identifier), expectedID == nil || identifier == expectedID,
                  try protobufInteger(response.body, field: 4) == 20190,
                  let signature = try protobufString(response.body, field: 8), signature.hasPrefix("$L"), (3...512).contains(signature.utf8.count),
                  !signature.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw moduleNetworkFailure("二进制发现响应与目标摄像头不匹配，或缺少有效的连接信息。")
            }
            return CameraModuleNetworkTarget(device: CameraModuleNetworkDevice(deviceID: identifier, address: address, port: 20190), signature: signature)
        }
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = document["result"] as? NSNumber, CFGetTypeID(result) != CFBooleanGetTypeID(), result.doubleValue == 0,
              let body = document["body"] as? [String: Any],
              let identifier = body["did"] as? String, validIdentifier(identifier), expectedID == nil || identifier == expectedID,
              let port = body["lis_port"] as? NSNumber, CFGetTypeID(port) != CFBooleanGetTypeID(), port.intValue == 20190, port.doubleValue == 20190,
              let signature = body["lsign"] as? String, signature.hasPrefix("$L"), (3...512).contains(signature.utf8.count),
              !signature.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw moduleNetworkFailure("发现响应与目标摄像头不匹配，或缺少有效的连接信息。")
        }
        return CameraModuleNetworkTarget(device: CameraModuleNetworkDevice(deviceID: identifier, address: address, port: 20190), signature: signature)
    }

    static func encode(command: UInt64, sequence: UInt64, body: Data, rpc: UInt8 = 0, status: UInt64 = 0, udp: Bool = false) throws -> Data {
        guard command <= 0x0fff_ffff, sequence <= 0x0fff_fffa, rpc <= 1, status <= 0x0fff_ffff, body.count <= maximumFrameSize - 64 else {
            throw moduleNetworkFailure("模块命令超出协议支持的范围。")
        }
        var payload = Data(varint(sequence))
        payload.append(contentsOf: varint(command))
        payload.append(0x0c | rpc)
        if rpc == 1 { payload.append(contentsOf: varint(status)) }
        if !body.isEmpty { payload.append(try crypt(body, command: command, sequence: sequence, rpc: rpc, operation: CCOperation(kCCEncrypt))) }
        var packet = udp ? Data([0x51, 0x70, 0x48]) : Data([0x48])
        packet.append(contentsOf: varint(UInt64(payload.count)))
        packet.append(payload)
        return packet
    }

    static func decode(_ data: Data) throws -> CameraModuleNetworkFrame {
        guard data.count <= maximumFrameSize + 16 else { throw moduleNetworkFailure("模块返回的网络报文过大。") }
        var reader = ModuleNetworkReader(bytes: Array(data))
        if data.starts(with: [0x51, 0x70]) { reader.offset = 2 }
        guard try reader.byte() == 0x48 else { throw moduleNetworkFailure("模块返回了不支持的网络帧类型。") }
        let length = try reader.varint()
        guard length > 0, length <= maximumFrameSize, length == UInt64(reader.remaining) else {
            throw moduleNetworkFailure("模块返回的网络帧长度不正确。")
        }
        let sequence = try reader.varint()
        let command = try reader.varint()
        let control = try reader.byte()
        let rpc = control & 3
        guard sequence <= 0x0fff_fffa, command <= 0x0fff_ffff, rpc <= 1, control >> 2 == 3 else {
            throw moduleNetworkFailure("模块返回了不支持的命令或加密格式。")
        }
        let status = rpc == 1 ? try reader.varint() : 0
        guard status <= 0x0fff_ffff else { throw moduleNetworkFailure("模块返回的状态超出协议支持的范围。") }
        let ciphertext = try reader.data(reader.remaining)
        let body = ciphertext.isEmpty ? Data() : try crypt(ciphertext, command: command, sequence: sequence, rpc: rpc, operation: CCOperation(kCCDecrypt))
        return CameraModuleNetworkFrame(command: command, sequence: sequence, rpc: rpc, status: status, body: body)
    }

    static func protobufString(_ data: Data, field: UInt64) throws -> String? {
        guard let value = try protobufFields(data)[field] as? Data else { return nil }
        guard let text = String(data: value, encoding: .utf8) else { throw moduleNetworkFailure("模块响应包含无效的文本编码。") }
        return text
    }

    static func protobufInteger(_ data: Data, field: UInt64) throws -> UInt64? {
        try protobufFields(data)[field] as? UInt64
    }

    static func stringField(_ field: UInt64, _ value: String) -> Data {
        guard !value.isEmpty else { return Data() }
        let bytes = Data(value.utf8)
        return Data(varint(field * 8 + 2)) + Data(varint(UInt64(bytes.count))) + bytes
    }

    static func varint(_ input: UInt64) -> [UInt8] {
        var value = input
        var bytes: [UInt8] = []
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
        return bytes
    }

    static func ipv4(_ address: String) -> UInt32? {
        var parsed = in_addr()
        guard inet_pton(AF_INET, address, &parsed) == 1 else { return nil }
        return UInt32(bigEndian: parsed.s_addr)
    }

    static func unicast(_ address: UInt32) -> Bool {
        let first = address >> 24
        return first > 0 && first < 224 && first != 127 && address != 0xffff_ffff
    }

    private static func validIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.count <= 128 && !identifier.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func protobufFields(_ data: Data) throws -> [UInt64: Any] {
        var reader = ModuleNetworkReader(bytes: Array(data))
        var fields: [UInt64: Any] = [:]
        while reader.remaining > 0 {
            let tag = try reader.varint()
            let field = tag >> 3
            guard field > 0 else { throw moduleNetworkFailure("模块响应包含无效的字段。") }
            let value: Any
            switch tag & 7 {
            case 0: value = try reader.varint()
            case 1: value = try reader.data(8)
            case 2:
                let count = try reader.varint()
                guard count <= UInt64(reader.remaining) else { throw moduleNetworkFailure("模块响应字段不完整。") }
                value = try reader.data(Int(count))
            case 5: value = try reader.data(4)
            default: throw moduleNetworkFailure("模块响应使用了不支持的字段类型。")
            }
            guard fields[field] == nil else { throw moduleNetworkFailure("模块响应包含重复的字段。") }
            fields[field] = value
        }
        return fields
    }

    private static func crypt(_ data: Data, command: UInt64, sequence: UInt64, rpc: UInt8, operation: CCOperation) throws -> Data {
        var material = defaultSeed
        material.append(Data(",ID:\(command)-SEQ:\(sequence)-RPC:\(rpc)".utf8))
        let digest = Insecure.MD5.hash(data: material)
        let key = Data(digest.map { String(format: "%02x", $0) }.joined().utf8)
        guard operation != CCOperation(kCCDecrypt) || (!data.isEmpty && data.count % 16 == 0) else {
            throw moduleNetworkFailure("模块网络密文长度不正确。")
        }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var count = 0
        let capacity = output.count
        let options = operation == CCOperation(kCCDecrypt) ? CCOptions(0) : CCOptions(kCCOptionPKCS7Padding)
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options, keyBytes.baseAddress, key.count, keyBytes.baseAddress, source.baseAddress, data.count, destination.baseAddress, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw moduleNetworkFailure("无法解密或编码模块的网络报文。") }
        output.count = count
        if operation == CCOperation(kCCDecrypt) {
            guard let padding = output.last, padding > 0, padding <= kCCBlockSizeAES128,
                  output.count >= Int(padding), output.suffix(Int(padding)).allSatisfy({ $0 == padding }) else {
                throw moduleNetworkFailure("模块网络报文的加密填充不正确。")
            }
            output.removeLast(Int(padding))
        }
        return output
    }
}

final class CameraModuleNetwork {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onFrame: ((Int32, Int32, Double) -> Void)?
    var onError: ((String) -> Void)?
    private struct Interface {
        let address: UInt32
        let mask: UInt32

        var broadcast: UInt32 { address | ~mask }

        func contains(_ candidate: UInt32) -> Bool {
            candidate & mask == address & mask && candidate != address && candidate != broadcast && candidate != address & mask
        }
    }

    private let queue = DispatchQueue(label: "camera.module.network")
    private let lock = NSLock()
    private var generation = 0
    private var sockets: Set<Int32> = []
    private var sessionKey = Data()

    func find(address: String, timeout: TimeInterval = 8, completion: @escaping (Result<CameraModuleNetworkDevice, Error>) -> Void) {
        stop()
        lock.lock()
        let request = generation
        lock.unlock()
        queue.async {
            let result: Result<CameraModuleNetworkDevice, Error>
            do {
                var found: CameraModuleNetworkDevice?
                try self.scan(expectedID: nil, destinationAddress: address, timeout: timeout, request: request) { target in
                    found = target.device
                    return false
                }
                guard let found else { throw moduleNetworkFailure("该 IP 未返回有效的摄像头模块信息，请检查地址、模块供电和网络连接后重试。") }
                result = .success(found)
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                if self.current(request) { completion(result) }
            }
        }
    }

    func scanNearby(timeout: TimeInterval = 8, onDevice: @escaping (CameraModuleNetworkDevice) -> Void, completion: @escaping (String?) -> Void) {
        stop()
        lock.lock()
        let request = generation
        lock.unlock()
        queue.async {
            var failure: String?
            do {
                try self.scan(expectedID: nil, timeout: timeout, request: request) { target in
                    DispatchQueue.main.async {
                        if self.current(request) { onDevice(target.device) }
                    }
                    return true
                }
            } catch { failure = error.localizedDescription }
            let message = failure
            DispatchQueue.main.async {
                if self.current(request) { completion(message) }
            }
        }
    }

    func connect(identity: CameraModuleIdentity, completion: @escaping (Result<CameraModuleNetworkDevice, Error>) -> Void) {
        stop()
        lock.lock()
        let request = generation
        lock.unlock()
        queue.async {
            do {
                let target = try self.discover(identity: identity, request: request)
                let descriptor = try self.connectedSocket(target.device, request: request)
                do {
                    let body = CameraModuleNetworkProtocol.stringField(2, target.device.deviceID) + CameraModuleNetworkProtocol.stringField(3, target.signature)
                    let authentication = try self.exchange(descriptor, command: 2650, sequence: 1, body: body, request: request)
                    guard let secret = try CameraModuleNetworkProtocol.protobufString(authentication.body, field: 1), !secret.isEmpty, secret.utf8.count <= 1024 else {
                        throw moduleNetworkFailure("摄像头模块没有返回有效的局域网会话密钥。")
                    }
                    usleep(150_000)
                    let sync = try self.exchange(descriptor, command: 106, sequence: 2, body: Data([8, 1]), request: request)
                    guard try CameraModuleNetworkProtocol.protobufInteger(sync.body, field: 1) == 1 else {
                        throw moduleNetworkFailure("摄像头模块没有确认局域网连接。")
                    }
                    self.lock.lock()
                    guard self.generation == request else { self.lock.unlock(); self.closeSocket(descriptor); return }
                    self.sessionKey = Data(secret.utf8)
                    self.lock.unlock()
                    DispatchQueue.main.async {
                        if self.current(request) { completion(.success(target.device)) }
                    }
                    do {
                        try self.stream(descriptor, sessionKey: Data(secret.utf8), request: request)
                    } catch {
                        self.closeSocket(descriptor)
                        self.lock.lock()
                        if self.generation == request {
                            self.sessionKey.resetBytes(in: self.sessionKey.startIndex..<self.sessionKey.endIndex)
                            self.sessionKey = Data()
                        }
                        self.lock.unlock()
                        DispatchQueue.main.async {
                            if self.current(request) { self.onError?(error.localizedDescription) }
                        }
                    }
                    self.closeSocket(descriptor)
                } catch {
                    self.closeSocket(descriptor)
                    throw error
                }
            } catch {
                DispatchQueue.main.async {
                    if self.current(request) { completion(.failure(error)) }
                }
            }
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        sessionKey.resetBytes(in: sessionKey.startIndex..<sessionKey.endIndex)
        sessionKey = Data()
        let previous = Array(sockets)
        for descriptor in previous { Darwin.shutdown(descriptor, SHUT_RDWR) }
        sockets.removeAll()
        lock.unlock()
        queue.async { for descriptor in previous { Darwin.close(descriptor) } }
    }

    deinit { stop() }

    private func current(_ request: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == request
    }

    private func openSocket(_ type: Int32, request: Int) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, type, 0)
        guard descriptor >= 0 else { throw moduleNetworkFailure("无法创建模块网络连接。") }
        lock.lock()
        guard generation == request else { lock.unlock(); Darwin.close(descriptor); throw moduleNetworkFailure("模块连接已取消。") }
        sockets.insert(descriptor)
        lock.unlock()
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        if type == SOCK_DGRAM {
            let flags = fcntl(descriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                closeSocket(descriptor)
                throw moduleNetworkFailure("无法启动模块的局域网扫描。")
            }
        }
        return descriptor
    }

    private func closeSocket(_ descriptor: Int32) {
        lock.lock()
        if sockets.remove(descriptor) != nil { Darwin.close(descriptor) }
        lock.unlock()
    }

    private func interfaces() -> [Interface] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }
        var result: [Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee
            guard value.ifa_flags & UInt32(IFF_UP) != 0, value.ifa_flags & UInt32(IFF_BROADCAST) != 0,
                  value.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let netmask = value.ifa_netmask else { continue }
            let parsed = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            let mask = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in.self).pointee
            let local = UInt32(bigEndian: parsed.sin_addr.s_addr)
            let subnet = UInt32(bigEndian: mask.sin_addr.s_addr)
            guard CameraModuleNetworkProtocol.unicast(local), subnet != 0, subnet != UInt32.max else { continue }
            result.append(Interface(address: local, mask: subnet))
        }
        return result
    }

    private func address(_ value: UInt32, port: Int) -> sockaddr_in {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = UInt16(port).bigEndian
        socketAddress.sin_addr = in_addr(s_addr: value.bigEndian)
        return socketAddress
    }

    private func discover(identity: CameraModuleIdentity, request: Int) throws -> CameraModuleNetworkTarget {
        var result: CameraModuleNetworkTarget?
        try scan(expectedID: identity.deviceID, destinationAddress: identity.address, timeout: identity.address == nil ? 45 : 8, request: request) { target in
            result = target
            return false
        }
        guard let result else { throw moduleNetworkFailure(current(request) ? (identity.address == nil ? "摄像头模块尚未出现在当前局域网。请确认模块已连上与 Mac 相通的 2.4 GHz Wi-Fi。" : "指定 IP 未返回该模块，请检查地址是否变化后重新查找。") : "模块连接已取消。") }
        return result
    }

    private func scan(expectedID: String?, destinationAddress: String? = nil, timeout: TimeInterval, request: Int, receive: (CameraModuleNetworkTarget) -> Bool) throws {
        let packet = try CameraModuleNetworkProtocol.discovery(deviceID: expectedID)
        let binaryPacket = try CameraModuleNetworkProtocol.binaryDiscovery(deviceID: expectedID)
        let networks = interfaces()
        let directAddress = try destinationAddress.map { try CameraModuleNetworkProtocol.manualAddress($0) }
        let directValue = directAddress.flatMap(CameraModuleNetworkProtocol.ipv4)
        guard directValue != nil || !networks.isEmpty else { throw moduleNetworkFailure("没有可用于发现摄像头模块的局域网连接。") }
        if let directValue, networks.contains(where: { directValue == $0.broadcast || directValue == $0.address & $0.mask }) {
            throw moduleNetworkFailure("请输入摄像头模块的 IP，不能使用网段或广播地址。")
        }
        let destinations = directValue.map { [$0] } ?? networks.map(\.broadcast)
        let descriptor = try openSocket(SOCK_DGRAM, request: request)
        defer { closeSocket(descriptor) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw moduleNetworkFailure("无法启用摄像头模块的局域网发现。")
        }
        let deadline = Date().addingTimeInterval(max(1, min(timeout, 45)))
        var nextSend = Date.distantPast
        var targetResponseError: Error?
        var discovered: Set<String> = []
        while current(request), Date() < deadline {
            if Date() >= nextSend {
                for destinationValue in destinations {
                    var destination = address(destinationValue, port: 20190)
                    for outgoing in [packet, binaryPacket] {
                        outgoing.withUnsafeBytes { bytes in
                            withUnsafePointer(to: &destination) { pointer in
                                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                    _ = sendto(descriptor, bytes.baseAddress, outgoing.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                        }
                    }
                }
                nextSend = Date().addingTimeInterval(2)
            }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 250) > 0, event.revents & Int16(POLLIN) != 0 else { continue }
            var source = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            var bytes = [UInt8](repeating: 0, count: 4097)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &bytes, bytes.count, 0, $0, &size) }
            }
            guard count > 0, count <= 4096 else { continue }
            let candidate = UInt32(bigEndian: source.sin_addr.s_addr)
            if let directValue {
                guard candidate == directValue else { continue }
            } else if !networks.contains(where: { $0.contains(candidate) }) { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &source.sin_addr, &text, socklen_t(text.count)) != nil else { continue }
            let response = Data(bytes.prefix(count))
            do {
                let target = try CameraModuleNetworkProtocol.discoveryResponse(response, address: String(cString: text), sourcePort: Int(UInt16(bigEndian: source.sin_port)), expectedID: expectedID, expectedAddress: directAddress)
                if discovered.insert(target.device.deviceID).inserted, !receive(target) { return }
            } catch {
                if let document = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                   let body = document["body"] as? [String: Any], let expectedID, body["did"] as? String == expectedID {
                    targetResponseError = error
                }
            }
        }
        if current(request), let targetResponseError {
            throw moduleNetworkFailure("已发现目标模块，但无法验证其连接信息：\(targetResponseError.localizedDescription)")
        }
    }

    private func connectedSocket(_ target: CameraModuleNetworkDevice, request: Int) throws -> Int32 {
        let deadline = Date().addingTimeInterval(12)
        var failure: Error = moduleNetworkFailure("模块连接已取消。")
        while current(request), Date() < deadline {
            let descriptor = try openSocket(SOCK_STREAM, request: request)
            do {
                try connectTCP(descriptor, target: target, request: request)
                return descriptor
            } catch {
                closeSocket(descriptor)
                failure = error
                let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                guard let code = underlying?.code, [EHOSTUNREACH, ENETUNREACH, EACCES, EPERM, ECONNREFUSED, ETIMEDOUT].map(Int.init).contains(code) else { throw error }
                usleep(250_000)
            }
        }
        guard current(request) else { throw moduleNetworkFailure("模块连接已取消。") }
        throw failure
    }

    private func connectTCP(_ descriptor: Int32, target: CameraModuleNetworkDevice, request: Int) throws {
        guard let ip = CameraModuleNetworkProtocol.ipv4(target.address) else { throw moduleNetworkFailure("摄像头模块的网络地址不正确。") }
        var destination = address(ip, port: target.port)
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw moduleNetworkFailure("无法设置模块网络连接。") }
        let result = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address -> (Int32, Int32) in
                let status = Darwin.connect(descriptor, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                return (status, errno)
            }
        }
        if result.0 != 0 {
            guard result.1 == EINPROGRESS else {
                NSLog("Module TCP connection failed: %@, errno=%d", target.address, result.1)
                if result.1 == EACCES || result.1 == EPERM { throw moduleNetworkFailure("需要局域网访问权限，请在系统设置的「隐私与安全性 → 本地网络」中允许 WireCamera。", systemError: result.1) }
                throw moduleNetworkFailure("摄像头模块的局域网连接未能建立，请确认模块在线并允许 WireCamera 访问本地网络后重试。", systemError: result.1)
            }
            let deadline = Date().addingTimeInterval(5)
            var connected = false
            var socketError: Int32 = ETIMEDOUT
            while current(request), Date() < deadline {
                var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                if poll(&event, 1, 250) > 0 {
                    var error: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    connected = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
                    socketError = error
                    break
                }
            }
            guard connected else { throw moduleNetworkFailure("连接摄像头模块超时或被拒绝。", systemError: socketError) }
        }
        guard current(request), fcntl(descriptor, F_SETFL, flags) == 0 else { throw moduleNetworkFailure("模块连接已取消。") }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func write(_ data: Data, descriptor: Int32, request: Int) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                guard current(request) else { throw moduleNetworkFailure("模块连接已取消。") }
                let count = send(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw moduleNetworkFailure("无法向摄像头模块发送网络命令。") }
                offset += count
            }
        }
    }

    private func read(_ count: Int, descriptor: Int32, request: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                guard current(request) else { throw moduleNetworkFailure("模块连接已取消。") }
                let received = recv(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw moduleNetworkFailure(received == 0 ? "摄像头模块中断了网络连接。" : "等待摄像头模块响应超时。") }
                offset += received
            }
        }
        return data
    }

    private func readPacket(_ descriptor: Int32, request: Int) throws -> Data {
        var packet = try read(1, descriptor: descriptor, request: request)
        var encodedLength = Data()
        for _ in 0..<5 {
            let next = try read(1, descriptor: descriptor, request: request)
            encodedLength.append(next)
            if next[0] & 0x80 == 0 { break }
        }
        var reader = ModuleNetworkReader(bytes: Array(encodedLength))
        let length = try reader.varint()
        guard length > 0, length <= CameraModuleNetworkProtocol.maximumFrameSize else { throw moduleNetworkFailure("摄像头模块返回的网络帧过大。") }
        packet.append(encodedLength)
        packet.append(try read(Int(length), descriptor: descriptor, request: request))
        return packet
    }

    private func exchange(_ descriptor: Int32, command: UInt64, sequence: UInt64, body: Data, request: Int) throws -> CameraModuleNetworkFrame {
        try write(CameraModuleNetworkProtocol.encode(command: command, sequence: sequence, body: body), descriptor: descriptor, request: request)
        for _ in 0..<10 {
            let packet = try readPacket(descriptor, request: request)
            if packet == Data([0x2a, 2, 0x48, 0x59]) { continue }
            let response = try CameraModuleNetworkProtocol.decode(packet)
            if try answer(response, descriptor: descriptor, request: request) { continue }
            guard response.command == command, response.sequence == sequence, response.rpc == 1 else { throw moduleNetworkFailure("摄像头模块返回了不匹配的认证响应。") }
            guard response.status == 0 else { throw moduleNetworkFailure("摄像头模块拒绝了网络命令（状态 \(response.status)）。") }
            return response
        }
        throw moduleNetworkFailure("摄像头模块没有返回认证结果。")
    }

    private func answer(_ frame: CameraModuleNetworkFrame, descriptor: Int32, request: Int) throws -> Bool {
        guard frame.rpc == 0 else { return false }
        let body: Data
        switch frame.command {
        case 107:
            let timestamp = try CameraModuleNetworkProtocol.protobufInteger(frame.body, field: 1) ?? 0
            body = integerField(1, timestamp) + integerField(3, UInt64(Date().timeIntervalSince1970 * 1000))
        case 2780: body = Data()
        default: throw moduleNetworkFailure("摄像头模块请求了尚未支持的网络命令（\(frame.command)）。")
        }
        try write(CameraModuleNetworkProtocol.encode(command: frame.command, sequence: frame.sequence, body: body, rpc: 1), descriptor: descriptor, request: request)
        return true
    }

    private func integerField(_ field: UInt64, _ value: UInt64) -> Data {
        value == 0 ? Data() : Data(CameraModuleNetworkProtocol.varint(field * 8)) + Data(CameraModuleNetworkProtocol.varint(value))
    }

    private func stream(_ descriptor: Int32, sessionKey: Data, request: Int) throws {
        usleep(150_000)
        let play = CameraModuleVideoProtocol.playBody()
        try write(CameraModuleNetworkProtocol.encode(command: CameraModuleVideoProtocol.playCommand, sequence: 3, body: play), descriptor: descriptor, request: request)
        NSLog("Module video preview requested")
        var assembler = CameraModuleStreamAssembler()
        var frameAssembler = CameraModuleVideoFrameAssembler()
        let sampler = CameraModuleVideoSampler()
        var nextHeartbeat = Date().addingTimeInterval(1)
        var heartbeatSequence: UInt64 = 10
        var acknowledgedSequence: UInt64 = 0
        var previousSequences: [UInt64: UInt64] = [:]
        var lastImage = Date()
        var lastReport: TimeInterval?
        var frameCount = 0
        while current(request) {
            if Date() >= nextHeartbeat {
                let body = integerField(1, UInt64(Date().timeIntervalSince1970 * 1000)) + integerField(4, acknowledgedSequence)
                try write(CameraModuleNetworkProtocol.encode(command: 107, sequence: heartbeatSequence, body: body), descriptor: descriptor, request: request)
                heartbeatSequence += 1
                nextHeartbeat = Date().addingTimeInterval(1)
            }
            guard Date().timeIntervalSince(lastImage) <= 15 else { throw moduleNetworkFailure("摄像头模块已通过网络认证，但尚未收到可解码的视频画面。") }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                throw moduleNetworkFailure("摄像头模块的网络连接已中断。")
            }
            guard ready > 0 else { continue }
            if event.revents & Int16(POLLERR | POLLNVAL) != 0 { throw moduleNetworkFailure("摄像头模块的网络连接已中断。") }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let received = recv(descriptor, &bytes, bytes.count, 0)
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { throw moduleNetworkFailure("摄像头模块关闭了网络视频连接。") }
            for packet in try assembler.append(Data(bytes.prefix(received))) {
                guard current(request) else { return }
                if packet[0] == 0x2a { continue }
                if packet[0] == 0x48 {
                    let response = try CameraModuleNetworkProtocol.decode(packet)
                    if try answer(response, descriptor: descriptor, request: request) { continue }
                    guard response.status == 0 else { throw moduleNetworkFailure("摄像头模块拒绝了视频命令（状态 \(response.status)）。") }
                    continue
                }
                let fragment = try CameraModuleVideoProtocol.decode(packet, sessionKey: sessionKey)
                acknowledgedSequence = max(acknowledgedSequence, fragment.sequence)
                guard fragment.format <= 20, fragment.source != 2, let frame = try frameAssembler.append(fragment) else { continue }
                let key = (frame.channel << 8) | UInt64(frame.format)
                if let previous = previousSequences[key], frame.sequence <= previous { continue }
                previousSequences[key] = frame.sequence
                guard let sample = try sampler.imageSample(frame), let format = CMSampleBufferGetFormatDescription(sample) else { continue }
                guard current(request) else { return }
                onSampleBuffer?(sample)
                if lastReport == nil {
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                    NSLog("Module video decoded: %d x %d", dimensions.width, dimensions.height)
                }
                lastImage = Date()
                frameCount += 1
                let now = ProcessInfo.processInfo.systemUptime
                if lastReport == nil || now - lastReport! >= 1 {
                    let fps = lastReport.map { Double(frameCount) / (now - $0) } ?? 0
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                    DispatchQueue.main.async {
                        if self.current(request) { self.onFrame?(dimensions.width, dimensions.height, fps) }
                    }
                    frameCount = 0
                    lastReport = now
                }
            }
        }
    }
}
