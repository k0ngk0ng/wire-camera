import Foundation

@main
struct CameraModuleScanE2E {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let scanner = CameraModuleNetwork()
        var finished = false
        var devices: [CameraModuleNetworkDevice] = []
        var scanError: String?
        let started = Date()
        scanner.scanNearby(timeout: 2, onDevice: { devices.append($0) }, completion: { error in
            scanError = error
            finished = true
        })
        while !finished && Date().timeIntervalSince(started) < 7 {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let elapsed = Date().timeIntervalSince(started)
        var staleCallbacks = 0
        scanner.scanNearby(timeout: 8, onDevice: { _ in staleCallbacks += 1 }, completion: { _ in staleCallbacks += 1 })
        scanner.stop()
        let cancellationEnd = Date().addingTimeInterval(1)
        while Date() < cancellationEnd { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        let checks: [[String: Any]] = [
            ["name": "live_socket_scan_completed", "passed": finished && scanError == nil],
            ["name": "scan_timeout_bounded", "passed": elapsed < 6],
            ["name": "cancel_suppresses_callbacks", "passed": staleCallbacks == 0]
        ]
        let report: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "elapsedSeconds": elapsed, "deviceIDs": devices.map(\.deviceID), "error": scanError ?? "", "realModuleVerified": false, "scope": "live_network_scan_timeout_and_cancellation", "timestamp": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Live module scan: completed=\(finished), devices=\(devices.count), staleCallbacks=\(staleCallbacks)")
        if report["passed"] as? Bool != true { exit(1) }
    }
}
