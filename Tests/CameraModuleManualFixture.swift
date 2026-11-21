import Darwin
import Foundation

@main
struct CameraModuleManualFixture {
    static let sessionLock = NSLock()
    static var secondSessions = 0
    static func socketAddress(_ ip: String) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = UInt16(20190).bigEndian
        inet_pton(AF_INET, ip, &value.sin_addr)
        return value
    }

    static func listener(_ type: Int32, ip: String) throws -> Int32 {
        let descriptor = socket(AF_INET, type, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = socketAddress(ip)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if type == SOCK_STREAM, listen(descriptor, 4) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return descriptor
    }

    static func sendAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard sent > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            offset += sent
        }
    }

    static func serve(_ descriptor: Int32, jpeg: Data, audio: Bool) {
        defer { close(descriptor) }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var assembler = CameraModuleStreamAssembler()
        var playing = false
        var audioPlaying = false
        var sequence: UInt64 = 1
        var secondCamera = false
        var dropSecond = false
        var streamJPEG = jpeg
        let deadline = Date().addingTimeInterval(90)
        var nextFrame = Date()
        do {
            while Date() < deadline {
                if dropSecond && sequence > 25 { return }
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                if poll(&event, 1, 30) > 0 {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = recv(descriptor, &bytes, bytes.count, 0)
                    guard count > 0 else { return }
                    for packet in try assembler.append(Data(bytes.prefix(count))) {
                        let frame = try CameraModuleNetworkProtocol.decode(packet)
                        let body: Data
                        switch frame.command {
                        case 2650:
                            let deviceID = try CameraModuleNetworkProtocol.protobufString(frame.body, field: 2)
                            secondCamera = CommandLine.arguments.contains("--multi-camera") && deviceID == "fixture-preview-device"
                            guard deviceID == "fixture-manual-device" || secondCamera else { return }
                            if secondCamera {
                                sessionLock.lock()
                                secondSessions += 1
                                let session = secondSessions
                                sessionLock.unlock()
                                dropSecond = !CommandLine.arguments.contains("--keep-second-online") && (!CommandLine.arguments.contains("--recover-second") || session <= 2)
                            }
                            if secondCamera { streamJPEG = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]).deletingLastPathComponent().appendingPathComponent("module-jpeg-frame.jpg")) }
                            body = CameraModuleNetworkProtocol.stringField(1, "fixture-session")
                        case 106: body = Data([8, 1])
                        case 2610:
                            guard frame.body.isEmpty else { return }
                            playing = true
                            body = Data()
                        case 2614:
                            audioPlaying = audio
                            body = audio ? Data([0x28, 21, 0x30, 0xc0, 0x3e, 0x38, 16, 0x40, 1]) : Data([8, 1])
                        case 107: body = Data()
                        default: return
                        }
                        try sendAll(CameraModuleNetworkProtocol.encode(command: frame.command, sequence: frame.sequence, body: body, rpc: 1), to: descriptor)
                    }
                }
                if playing, Date() >= nextFrame {
                    var body = Data([0x84, 0, 0])
                    body.append(contentsOf: CameraModuleNetworkProtocol.varint(sequence))
                    body.append(contentsOf: CameraModuleNetworkProtocol.varint(UInt64(Date().timeIntervalSince1970 * 1000)))
                    body.append(0)
                    body.append(streamJPEG)
                    let packet = Data([0x68]) + Data(CameraModuleNetworkProtocol.varint(UInt64(body.count))) + body
                    try sendAll(packet, to: descriptor)
                    if audioPlaying && (!CommandLine.arguments.contains("--audio-drop") || sequence < 12) {
                        var audioBody = Data([21, 0, 0])
                        audioBody.append(contentsOf: CameraModuleNetworkProtocol.varint(sequence))
                        audioBody.append(contentsOf: CameraModuleNetworkProtocol.varint(UInt64(Date().timeIntervalSince1970 * 1000)))
                        audioBody.append(0)
                        let tone: [UInt8] = secondCamera ? [0xd5, 0xa0, 0x92, 0xa0, 0x55, 0x20, 0x12, 0x20] : [0xd5, 0x87, 0x96, 0xba, 0x9a, 0x85, 0xe3, 0x60, 0x04, 0x1b, 0x3a, 0x16, 0x07, 0x55, 0xd5, 0xd5]
                        audioBody.append(contentsOf: (0..<800).map { tone[$0 % tone.count] })
                        try sendAll(Data([0x68]) + Data(CameraModuleNetworkProtocol.varint(UInt64(audioBody.count))) + audioBody, to: descriptor)
                    }
                    sequence += 1
                    nextFrame = nextFrame.addingTimeInterval(0.1)
                }
            }
        } catch { return }
    }

    static func main() throws {
        let ip = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let udp = try listener(SOCK_DGRAM, ip: ip)
        let tcp = try listener(SOCK_STREAM, ip: ip)
        var requests = 0
        var connections = 0
        try Data("ready".utf8).write(to: directory.appendingPathComponent("ready"))
        while true {
            var events = [pollfd(fd: udp, events: Int16(POLLIN), revents: 0), pollfd(fd: tcp, events: Int16(POLLIN), revents: 0)]
            guard poll(&events, 2, 250) > 0 else { continue }
            if events[0].revents & Int16(POLLIN) != 0 {
                var source = sockaddr_in()
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udp, &bytes, bytes.count, 0, $0, &size) }
                }
                if count > 0 {
                    let request = Data(bytes.prefix(count))
                    let binary = try? CameraModuleNetworkProtocol.decode(request)
                    let json = (try? JSONSerialization.jsonObject(with: request)) as? [String: String]
                    let requested = binary.flatMap { try? CameraModuleNetworkProtocol.protobufString($0.body, field: 1) } ?? json?["did"]
                    let deviceID = CommandLine.arguments.contains("--multi-camera") && requested == "fixture-preview-device" ? "fixture-preview-device" : "fixture-manual-device"
                    let body = CameraModuleNetworkProtocol.stringField(1, deviceID) + Data([32, 0xde, 0x9d, 1]) + CameraModuleNetworkProtocol.stringField(8, "$Lfixture-sign")
                    let response = try CameraModuleNetworkProtocol.encode(command: 2600, sequence: 1, body: body, rpc: 1, udp: true)
                    response.withUnsafeBytes { data in
                        withUnsafePointer(to: &source) { pointer in
                            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(udp, data.baseAddress, response.count, 0, $0, size) }
                        }
                    }
                    requests += 1
                }
            }
            if events[1].revents & Int16(POLLIN) != 0 {
                let connection = accept(tcp, nil, nil)
                if connection >= 0 { connections += 1; DispatchQueue.global().async { serve(connection, jpeg: jpeg, audio: CommandLine.arguments.contains("--audio")) } }
            }
            let report: [String: Any] = ["scope": "synthetic_module_on_direct_ip", "realModuleVerified": false, "requests": requests, "connections": connections]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("server.json"), options: .atomic)
        }
    }
}
