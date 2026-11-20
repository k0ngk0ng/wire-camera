import AudioToolbox
import CoreMedia
import Foundation

@main
struct CameraModuleAudioCheck {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) { checks.append(["name": name, "passed": condition]) }
        func reject(_ name: String, _ body: () throws -> Void) {
            do { try body(); check(name, false) }
            catch { check(name, true) }
        }
        let response = Data([0x28, 21, 0x30, 0xc0, 0x3e, 0x38, 16, 0x40, 1])
        let format = try CameraModuleAudioFormat(response: response)
        check("official_audio_play_command", CameraModuleAudioSampler.playCommand == 2614)
        check("channel_zero_omitted", CameraModuleAudioSampler.playBody().isEmpty)
        check("channel_encoded", CameraModuleAudioSampler.playBody(channel: 2) == Data([8, 2]))
        check("real_response_parameters", format.codec == 21 && format.sampleRate == 8000 && format.channels == 1 && format.bits == 16)
        func frame(_ bytes: Data, format: UInt8 = 21, source: UInt8 = 1, offset: UInt8 = 0, timestamp: UInt64 = 123400) -> CameraModuleVideoFrame {
            CameraModuleVideoFrame(format: format, channel: 0, sequence: 1, timestamp: timestamp, isKeyframe: false, source: source, offset: offset, payload: bytes)
        }
        let sampler = CameraModuleAudioSampler(format: format)
        let sample = try sampler.sample(frame(Data([0xd5, 0x55, 0x00, 0x80, 0x2a, 0xaa])))!
        let description = CMSampleBufferGetFormatDescription(sample)!
        let audio = CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee
        check("decoded_pcm_format", audio.mFormatID == kAudioFormatLinearPCM && audio.mSampleRate == 8000 && audio.mChannelsPerFrame == 1 && audio.mBitsPerChannel == 16)
        check("pcm_sample_count", CMSampleBufferGetNumSamples(sample) == 6)
        check("camera_timestamp_preserved", abs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - 123.4) < 0.0001)
        let data = CMSampleBufferGetDataBuffer(sample)!
        var pcm = [Int16](repeating: 0, count: 6)
        let copied = pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 12, destination: $0.baseAddress!) }
        check("itu_alaw_golden_samples", copied == noErr && pcm == [8, -8, -5504, 5504, -32256, 32256])
        check("video_is_not_audio", try sampler.sample(frame(Data([1]), format: 4)) == nil)
        check("historical_audio_ignored", try sampler.sample(frame(Data([1]), source: 2)) == nil)
        reject("empty_audio_rejected") { _ = try sampler.sample(frame(Data())) }
        reject("unassembled_audio_rejected") { _ = try sampler.sample(frame(Data([1]), offset: 1)) }
        reject("timestamp_overflow_rejected") { _ = try sampler.sample(frame(Data([1]), timestamp: UInt64.max)) }
        for (name, bytes) in [
            ("missing_metadata", Data()),
            ("rejected_audio_play", Data([8, 1]) + response),
            ("unsupported_codec", Data([0x28, 101, 0x30, 0xc0, 0x3e, 0x38, 16, 0x40, 1])),
            ("zero_sample_rate", Data([0x28, 21, 0x38, 16, 0x40, 1])),
            ("unsupported_bit_depth", Data([0x28, 21, 0x30, 0xc0, 0x3e, 0x38, 8, 0x40, 1])),
            ("invalid_channel_count", Data([0x28, 21, 0x30, 0xc0, 0x3e, 0x38, 16, 0x40, 3]))
        ] { reject(name) { _ = try CameraModuleAudioFormat(response: bytes) } }
        let stereo = try CameraModuleAudioFormat(response: Data([0x28, 21, 0x30, 0xc0, 0x3e, 0x38, 16, 0x40, 2]))
        reject("unaligned_stereo_rejected") { _ = try CameraModuleAudioSampler(format: stereo).sample(frame(Data([1]))) }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "realModuleVerified": false, "scope": "golden_alaw_vectors_and_validation", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Module audio checks: \(checks.count), passed: \(passed)")
        if !passed { exit(1) }
    }
}
