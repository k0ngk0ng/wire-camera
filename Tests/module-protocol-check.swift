import Foundation

struct ProtocolCheckFailure: Error, CustomStringConvertible {
    let description: String
}

struct ProtocolChecks {
    var results: [[String: Any]] = []

    mutating func require(_ name: String, _ condition: Bool) throws {
        guard condition else { throw ProtocolCheckFailure(description: name) }
        results.append(["name": name, "passed": true])
    }

    mutating func rejects(_ name: String, _ action: () throws -> Void) throws {
        var rejected = false
        do { try action() }
        catch { rejected = true }
        try require(name, rejected)
    }
}

func protocolData(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

@main
struct ModuleProtocolCheck {
    static func main() {
        var checks = ProtocolChecks()
        do {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/module-protocol.json"))) as! [String: Any]
            let configurations = fixture["configuration"] as! [[String: Any]]
            for configuration in configurations {
                let name = configuration["name"] as! String
                let expected = (configuration["packetsHex"] as! [String]).map(protocolData)
                let packets = try CameraModuleProtocol.configurationPackets(ssid: configuration["ssid"] as! String, password: configuration["password"] as! String, verificationCode: configuration["verificationCode"] as! String, timestamp: (configuration["timestamp"] as! NSNumber).uint64Value)
                try checks.require("golden_configuration_\(name)", packets == expected)
                var assembler = CameraModulePacketAssembler()
                var combined: Data?
                for packet in packets { combined = try assembler.append(packet) ?? combined }
                try checks.require("assembly_\(name)", combined == protocolData(configuration["encodedHex"] as! String))
            }
            for (name, ssid, password) in [("empty_ssid", "", "password123"), ("long_ssid", String(repeating: "a", count: 33), "password123"), ("long_utf8_ssid", String(repeating: "中", count: 11), "password123"), ("short_password", "Lab", "short"), ("long_password", "Lab", String(repeating: "a", count: 64)), ("control_ssid", "Lab\0", "password123"), ("control_password", "Lab", "password\n123")] {
                try checks.require(name, CameraModuleProtocol.validateCredentials(ssid: ssid, password: password) != nil)
                try checks.rejects("encoding_rejects_\(name)") { _ = try CameraModuleProtocol.configurationPackets(ssid: ssid, password: password, timestamp: 0) }
            }
            try checks.rejects("oversized_verification_code") { _ = try CameraModuleProtocol.configurationPackets(ssid: "Lab", password: "password123", verificationCode: String(repeating: "a", count: 256), timestamp: 0) }
            try checks.rejects("old_sdk_safe_packet_limit") { _ = try CameraModuleProtocol.configurationPackets(ssid: "Lab", password: "password123", verificationCode: String(repeating: "a", count: 230), timestamp: 0) }
            let responses = fixture["responses"] as! [[String: Any]]
            let success = responses.first { $0["name"] as? String == "success" }!
            let encoded = protocolData(success["encodedHex"] as! String)
            let identity = try CameraModuleProtocol.decodeResponse(encoded)
            try checks.require("response_device_id", identity.deviceID == "TEST-DEVICE-001")
            try checks.require("response_second_string", identity.salt == "test-salt-123456")
            let packets = (success["packetsHex"] as! [String]).map(protocolData)
            var assembler = CameraModulePacketAssembler()
            try checks.require("first_fragment_incomplete", try assembler.append(packets[0]) == nil)
            try checks.require("identical_duplicate_incomplete", try assembler.append(packets[0]) == nil)
            var reordered: Data?
            for packet in packets.dropFirst().reversed() { reordered = try assembler.append(packet) ?? reordered }
            try checks.require("reordered_duplicate_assembly", reordered == encoded)
            for (name, packet) in [("empty_fragment", Data()), ("zero_total", Data([0, 1, 1, 0])), ("zero_index", Data([1, 0, 1, 0])), ("index_above_total", Data([1, 2, 1, 0])), ("length_mismatch", Data([1, 1, 2, 0])), ("zero_payload", Data([1, 1, 0])), ("short_nonfinal", Data([2, 1, 1, 0]))] {
                try checks.rejects(name) { var candidate = CameraModulePacketAssembler(); _ = try candidate.append(packet) }
            }
            try checks.rejects("changed_total") {
                var candidate = CameraModulePacketAssembler()
                _ = try candidate.append(packets[0])
                var changed = packets[1]
                changed[0] = changed[0] + 1
                _ = try candidate.append(changed)
            }
            var conflictAssembler = CameraModulePacketAssembler()
            _ = try conflictAssembler.append(packets[0])
            var conflict = packets[0]
            conflict[conflict.count - 1] ^= 1
            try checks.rejects("conflicting_duplicate") { _ = try conflictAssembler.append(conflict) }
            var recovered: Data?
            for packet in packets { recovered = try conflictAssembler.append(packet) ?? recovered }
            try checks.require("assembly_recovers_after_error", recovered == encoded)
            _ = try conflictAssembler.append(packets[0])
            conflictAssembler.reset()
            try checks.require("manual_reset", try conflictAssembler.append(packets[1]) == nil)
            let rejected = responses.first { $0["name"] as? String == "rejected" }!
            try checks.rejects("device_rejected_configuration") { _ = try CameraModuleProtocol.decodeResponse(protocolData(rejected["encodedHex"] as! String)) }
            let invalidPadding = responses.first { $0["name"] as? String == "invalid_padding" }!
            try checks.rejects("strict_pkcs7_padding") { _ = try CameraModuleProtocol.decodeResponse(protocolData(invalidPadding["encodedHex"] as! String)) }
            try checks.rejects("empty_response") { _ = try CameraModuleProtocol.decodeResponse(Data()) }
            try checks.rejects("truncated_response") { _ = try CameraModuleProtocol.decodeResponse(encoded.dropLast()) }
            var unsupported = encoded
            unsupported[0] = 0x13
            try checks.rejects("unsupported_cipher_mode") { _ = try CameraModuleProtocol.decodeResponse(unsupported) }
            try checks.rejects("request_is_not_success_response") { _ = try CameraModuleProtocol.decodeResponse(protocolData(configurations[0]["encodedHex"] as! String)) }
            let directory = root.appendingPathComponent(".build/module-protocol-check")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let report: [String: Any] = ["passed": true, "checks": checks.results, "fixtureAuthority": fixture["authority"]!, "hardwareAccepted": false, "timestamp": ISO8601DateFormatter().string(from: Date())]
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            print("Module protocol checks passed: \(checks.results.count). Report: \(directory.appendingPathComponent("report.json").path)")
        } catch {
            fputs("Module protocol check failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
