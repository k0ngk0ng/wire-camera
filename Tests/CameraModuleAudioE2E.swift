import CoreMedia
import Foundation

@main
struct CameraModuleAudioE2E {
    static func main() throws {
        let deviceID = CommandLine.arguments[1]
        let address = CommandLine.arguments[2]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let network = CameraModuleNetwork()
        let lock = NSLock()
        var videoFrames = 0
        var audioFrames = 0
        var connected = false
        var failure: String?
        var pcm = Data()
        var firstAudio: Double?
        var lastAudio: Double?
        network.onSampleBuffer = { _ in
            lock.lock()
            videoFrames += 1
            lock.unlock()
        }
        network.onAudioSampleBuffer = { sample in
            lock.lock()
            defer { lock.unlock() }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { failure = "Missing PCM data"; return }
            let count = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: count)
            let copied = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
            guard copied == noErr else { failure = "PCM copy failed"; return }
            pcm.append(bytes)
            audioFrames += 1
            let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if firstAudio == nil { firstAudio = timestamp }
            lastAudio = timestamp + Double(CMSampleBufferGetNumSamples(sample)) / 8000
        }
        network.onError = { message in lock.lock(); failure = message; lock.unlock() }
        network.onAudioError = { message in lock.lock(); failure = message; lock.unlock() }
        network.connect(identity: CameraModuleIdentity(deviceID: deviceID, salt: "", address: address)) { result in
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .success(let device): connected = device.deviceID == deviceID
            case .failure(let error): failure = error.localizedDescription
            }
        }
        let deadline = Date().addingTimeInterval(14)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            lock.lock()
            let finished = failure != nil || audioFrames >= 80
            lock.unlock()
            if finished { break }
        }
        network.stop()
        lock.lock()
        let audioSeconds = Double(pcm.count / 2) / 8000
        let timestampSeconds = (lastAudio ?? 0) - (firstAudio ?? 0)
        let passed = connected && failure == nil && videoFrames >= 20 && audioFrames >= 30 && audioSeconds >= 3 && abs(timestampSeconds - audioSeconds) < 1
        let report: [String: Any] = ["passed": passed, "scope": "real_wifi_module_network_audio_video", "realModuleVerified": connected && audioFrames > 0, "deviceID": deviceID, "address": address, "videoFrames": videoFrames, "audioFrames": audioFrames, "audioSeconds": audioSeconds, "timestampSeconds": timestampSeconds, "error": failure ?? ""]
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var bytes = value.littleEndian; withUnsafeBytes(of: &bytes) { wav.append(contentsOf: $0) } }
        append(UInt32(pcm.count + 36))
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(8000))
        append(UInt32(16000))
        append(UInt16(2))
        append(UInt16(16))
        wav.append(Data("data".utf8))
        append(UInt32(pcm.count))
        wav.append(pcm)
        lock.unlock()
        try wav.write(to: directory.appendingPathComponent("audio.wav"))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        if !passed { exit(1) }
    }
}
