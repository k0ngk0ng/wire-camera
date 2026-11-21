import AppKit
import AVFoundation
import CoreImage
import Foundation

@main
struct CameraStreamingE2E {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ready.json"))) as! [String: Any]
        let port = settings["port"] as! Int, token = settings["token"] as! String, fingerprint = settings["fingerprint"] as! String
        let total = settings["firstBytes"] as! Int
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let secondOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let started = Date()
        var phase = 0
        var checks: [[String: Any]] = []
        var errors: [String] = []
        var certificateRejected = false
        var tokenRejected = false
        var firstBytes = 0
        var firstSeconds: Double = 0
        let trust = CameraRemoteTrust(fingerprint: fingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        func request(_ name: String, validToken: Bool = true) -> URLRequest {
            var value = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/v1/recordings/\(name)/movie")!)
            value.setValue("Bearer " + (validToken ? token : "invalid"), forHTTPHeaderField: "Authorization")
            return value
        }
        let first = CameraPlaybackResource(request: request("first"), fingerprint: fingerprint)
        let firstItem = first.makeItem()
        firstItem.add(output)
        var second: CameraPlaybackResource?
        var secondItem: AVPlayerItem?
        var rejected: CameraPlaybackResource?
        first.onError = { error in DispatchQueue.main.async { errors.append(error.localizedDescription) } }
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func frame(_ source: AVPlayerItemVideoOutput, _ name: String) -> Bool {
            let time = player.currentTime()
            guard source.hasNewPixelBuffer(forItemTime: time), let pixels = source.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return false }
            let image = CIImage(cvPixelBuffer: pixels)
            if let cgImage = CIContext().createCGImage(image, from: image.extent) { try? NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png")) }
            return true
        }
        func stats(_ complete: @escaping ([String: Any]) -> Void) {
            session.dataTask(with: URL(string: "https://127.0.0.1:\(port)/stats")!) { data, _, _ in
                let value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                DispatchQueue.main.async { complete(value) }
            }.resume()
        }
        func finish(_ error: String? = nil) {
            player.pause(); player.removeAllItems()
            first.close(); second?.close(); rejected?.close()
            let report: [String: Any] = ["passed": error == nil && errors.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "errors": errors, "error": error ?? "", "startupSeconds": firstSeconds, "bytesBeforeFirstFrame": firstBytes, "movieBytes": total]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("player-result.json"))
            session.invalidateAndCancel()
            app.stop(nil)
            let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
            app.postEvent(event, atStart: true)
        }
        player.insert(firstItem, after: nil)
        player.seek(to: CMTime(seconds: 40, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { completed in if completed { player.play() } }
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            if Date().timeIntervalSince(started) > 55 || !errors.isEmpty { timer.invalidate(); finish(errors.first ?? "Timed out at phase \(phase)"); return }
            switch phase {
            case 0:
                guard player.currentTime().seconds >= 40.1, frame(output, "initial-seek") else { return }
                firstSeconds = Date().timeIntervalSince(started)
                phase = 1
                stats { value in
                    firstBytes = value["bytes"] as? Int ?? total
                    check("starts_before_full_movie_download", firstBytes < total / 3)
                    check("limited_bandwidth_first_frame_is_fast", firstSeconds < 12)
                    player.seek(to: CMTime(seconds: 10, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    player.seek(to: CMTime(seconds: 48, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { completed in if completed { player.play() } }
                    phase = 2
                }
            case 2:
                guard player.currentTime().seconds >= 48.1, player.currentTime().seconds < 51, frame(output, "rapid-seek") else { return }
                check("rapid_seek_keeps_latest_position", true)
                let resource = CameraPlaybackResource(request: request("second"), fingerprint: fingerprint)
                resource.onError = { error in DispatchQueue.main.async { errors.append(error.localizedDescription) } }
                let item = resource.makeItem(); item.add(secondOutput)
                second = resource; secondItem = item
                player.insert(item, after: firstItem)
                player.seek(to: CMTime(seconds: 58.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { completed in if completed { player.play() } }
                phase = 3
            case 3:
                guard player.currentItem === secondItem, player.currentTime().seconds > 0.1, frame(secondOutput, "next-segment") else { return }
                check("queue_continues_to_next_segment", true)
                player.pause(); player.removeAllItems(); first.close(); second?.close()
                let resource = CameraPlaybackResource(request: request("first"), fingerprint: String(repeating: "0", count: 64))
                resource.onError = { _ in DispatchQueue.main.async { certificateRejected = true } }
                rejected = resource
                player.insert(resource.makeItem(), after: nil); player.play()
                phase = 4
            case 4:
                guard certificateRejected else { return }
                check("wrong_certificate_rejected", true)
                player.pause(); player.removeAllItems(); rejected?.close()
                let resource = CameraPlaybackResource(request: request("first", validToken: false), fingerprint: fingerprint)
                resource.onError = { _ in DispatchQueue.main.async { tokenRejected = true } }
                rejected = resource
                player.insert(resource.makeItem(), after: nil); player.play()
                phase = 5
            case 5:
                guard tokenRejected else { return }
                check("unauthorized_stream_rejected", true)
                player.pause(); player.removeAllItems(); rejected?.close()
                phase = 6
            case 6:
                phase = 7
                stats { value in
                    if value["leases"] as? Int == 0 { check("closing_players_releases_leases", true); timer.invalidate(); finish() }
                    else { phase = 6 }
                }
            default: break
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        app.run()
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("player-result.json"))) as! [String: Any]
        if report["passed"] as? Bool != true { exit(1) }
    }
}
