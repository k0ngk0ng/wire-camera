import Foundation

@main
struct CameraModuleStoreCheck {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = directory.appendingPathComponent("modules.json")
        let store = CameraModuleStore(fileURL: file)
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        check("empty_store", store.devices.isEmpty)
        let first = CameraModuleNetworkDevice(deviceID: "fixture-first", address: "192.0.2.10", port: 20190)
        try store.save(first)
        let reopened = CameraModuleStore(fileURL: file)
        check("offline_restart_restores_device", reopened.devices == [first])
        let changed = CameraModuleNetworkDevice(deviceID: first.deviceID, address: "192.0.2.20", port: 20190)
        try reopened.save(changed)
        check("changed_ip_updates_identity", reopened.devices == [changed])
        let second = CameraModuleNetworkDevice(deviceID: "fixture-second", address: "192.0.2.30", port: 20190)
        try reopened.save(second)
        check("multiple_saved_modules", CameraModuleStore(fileURL: file).devices == [changed, second])
        do { try reopened.save(CameraModuleNetworkDevice(deviceID: "invalid", address: "127.0.0.1", port: 20190)); check("invalid_address_rejected", false) }
        catch { check("invalid_address_rejected", true) }
        do { try reopened.save(CameraModuleNetworkDevice(deviceID: "", address: "192.0.2.40", port: 20190)); check("invalid_id_rejected", false) }
        catch { check("invalid_id_rejected", true) }
        check("invalid_write_preserves_records", CameraModuleStore(fileURL: file).devices == [changed, second])
        let encoded = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        check("only_identity_and_address_saved", encoded.allSatisfy { Set($0.keys) == Set(["deviceID", "address"]) })
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failing = CameraModuleStore(fileURL: blocked.appendingPathComponent("modules.json"))
        do { try failing.save(first); check("write_failure_reported", false) }
        catch { check("write_failure_reported", true) }
        check("failed_write_not_remembered", failing.devices.isEmpty)
        try Data("broken".utf8).write(to: file)
        check("corrupt_store_recovers", CameraModuleStore(fileURL: file).devices.isEmpty)
        let report: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "scope": "local_module_persistence"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
        print("Module store checks: \(checks.count), passed: \(report["passed"]!)")
        if report["passed"] as? Bool != true { exit(1) }
    }
}
