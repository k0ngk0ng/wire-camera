import Foundation

@main
struct CameraModuleNetworkCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/module-network-vectors.json"))
        let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let vectors = document["vectors"] as! [[String: Any]]
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) {
            checks.append(["name": name, "passed": condition])
        }
        func reject(_ name: String, _ body: () throws -> Void) {
            do { try body(); check(name, false) }
            catch { check(name, true) }
        }
        func bytes(_ text: String) -> Data {
            var result = Data()
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                result.append(UInt8(text[index..<next], radix: 16)!)
                index = next
            }
            return result
        }
        for vector in vectors {
            let name = vector["name"] as! String
            let packet = bytes(vector["packetHex"] as! String)
            let expected = vector["decoded"] as! [String: Any]
            let decoded = try CameraModuleNetworkProtocol.decode(packet)
            check("\(name)_decoded", decoded.command == expected["command"] as! UInt64 && decoded.sequence == expected["sequence"] as! UInt64 && decoded.rpc == expected["rpc"] as! UInt8 && decoded.status == expected["code"] as! UInt64 && decoded.body == bytes(expected["body"] as! String))
            let encoded = try CameraModuleNetworkProtocol.encode(command: decoded.command, sequence: decoded.sequence, body: decoded.body, rpc: decoded.rpc, status: decoded.status, udp: packet.starts(with: [0x51, 0x70]))
            check("\(name)_golden_bytes", encoded == packet)
        }
        check("json_discovery_filters_full_id", try JSONSerialization.jsonObject(with: CameraModuleNetworkProtocol.discovery(deviceID: "fixture-device")) as? [String: String] == ["cmd": "Discovery", "did": "fixture-device"])
        let response: [String: Any] = ["result": 0, "body": ["did": "fixture-device", "ipaddr": "192.168.1.20", "lis_port": 20190, "lsign": "$Lfixture-sign"]]
        let responseData = try JSONSerialization.data(withJSONObject: response)
        let target = try CameraModuleNetworkProtocol.discoveryResponse(responseData, address: "192.168.1.20", sourcePort: 20190, expectedID: "fixture-device")
        check("matching_discovery_accepted", target.device.deviceID == "fixture-device" && target.device.address == "192.168.1.20" && target.device.port == 20190)
        reject("wrong_device_rejected") { _ = try CameraModuleNetworkProtocol.discoveryResponse(responseData, address: "192.168.1.20", sourcePort: 20190, expectedID: "another-device") }
        check("nat_source_address_used", try CameraModuleNetworkProtocol.discoveryResponse(responseData, address: "192.168.1.21", sourcePort: 20190, expectedID: "fixture-device").device.address == "192.168.1.21")
        check("ephemeral_source_port_accepted", try CameraModuleNetworkProtocol.discoveryResponse(responseData, address: "192.168.1.20", sourcePort: 49152, expectedID: "fixture-device").device.port == 20190)
        reject("invalid_source_port_rejected") { _ = try CameraModuleNetworkProtocol.discoveryResponse(responseData, address: "192.168.1.20", sourcePort: 0, expectedID: "fixture-device") }
        let binary = bytes(document["binaryDiscoveryResponseHex"] as! String)
        let binaryTarget = try CameraModuleNetworkProtocol.discoveryResponse(binary, address: "192.168.1.20", sourcePort: 20190, expectedID: "fixture-device")
        check("binary_discovery_with_nat", binaryTarget.device.address == "192.168.1.20" && binaryTarget.device.deviceID == "fixture-device")
        reject("binary_wrong_device_rejected") { _ = try CameraModuleNetworkProtocol.discoveryResponse(binary, address: "192.168.1.20", sourcePort: 20190, expectedID: "different-device") }
        for address in ["127.0.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "not-an-ip"] {
            reject("invalid_source_\(address)") { _ = try CameraModuleNetworkProtocol.discoveryResponse(responseData, address: address, sourcePort: 20190, expectedID: "fixture-device") }
        }
        for field in ["did", "lis_port", "lsign"] {
            var value = response
            var body = value["body"] as! [String: Any]
            body.removeValue(forKey: field)
            value["body"] = body
            let malformed = try JSONSerialization.data(withJSONObject: value)
            reject("missing_\(field)_rejected") { _ = try CameraModuleNetworkProtocol.discoveryResponse(malformed, address: "192.168.1.20", sourcePort: 20190, expectedID: "fixture-device") }
        }
        for packet in [Data(), Data([0x48]), Data([0x48, 0x80]), Data([0x48, 0x80, 0]), Data([0x48, 4, 1]), Data([0x47, 0]), Data([0x48, 3, 1, 1, 0x1c]), Data([0x48, 3, 1, 1, 0x0f])] {
            reject("malformed_frame_\(packet.map { String(format: "%02x", $0) }.joined())") { _ = try CameraModuleNetworkProtocol.decode(packet) }
        }
        var corrupted = bytes(vectors[1]["packetHex"] as! String)
        corrupted[corrupted.count - 17] ^= 0xff
        reject("corrupt_padding_rejected") { _ = try CameraModuleNetworkProtocol.decode(corrupted) }
        let auth = try CameraModuleNetworkProtocol.encode(command: 2650, sequence: 1, body: Data([0x0a, 3, 0x61, 0x62, 0x63]), rpc: 1)
        let decodedAuth = try CameraModuleNetworkProtocol.decode(auth)
        check("session_key_protobuf", try CameraModuleNetworkProtocol.protobufString(decodedAuth.body, field: 1) == "abc")
        reject("truncated_protobuf_rejected") { _ = try CameraModuleNetworkProtocol.protobufString(Data([0x0a, 5, 1]), field: 1) }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "scope": "static_protocol_vectors_and_validation", "realModuleVerified": false, "checks": checks]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Module network checks: \(checks.count), passed: \(passed)")
        if !passed { exit(1) }
    }
}
