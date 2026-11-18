import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

private final class ModuleDecodedFrame {
    var width = 0
    var height = 0
}

@main
struct CameraModuleVideoCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/module-video-vectors.json"))
        let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let vectors = document["vectors"] as! [[String: Any]]
        let h264 = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/module-h264-frame.h264"))
        let secret = Data((document["sessionKey"] as! String).utf8)
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func reject(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); check(name, false) }
            catch { check(name, true) }
        }
        let body = CameraModuleVideoProtocol.playBody()
        check("official_video_play_defaults", body.isEmpty && CameraModuleVideoProtocol.playCommand == 2610)
        check("official_video_play_packet", try CameraModuleNetworkProtocol.encode(command: CameraModuleVideoProtocol.playCommand, sequence: 3, body: body) == Data([0x48, 4, 3, 0xb2, 0x14, 0x0c]))
        check("video_play_protobuf_fields", CameraModuleVideoProtocol.playBody(channel: 2, qos: 1, speed: 0) == Data([8, 2, 16, 1]))
        let jpeg = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/module-jpeg-frame.jpg"))
        func jpegFrame(_ payload: Data, source: UInt8 = 1, offset: UInt8 = 0) -> CameraModuleVideoFrame {
            CameraModuleVideoFrame(format: 4, channel: 0, sequence: 1, timestamp: 1700000000000, isKeyframe: true, source: source, offset: offset, payload: payload)
        }
        let jpegImage = try CameraModuleVideoSampler().imageSample(jpegFrame(jpeg))
        let jpegBuffer = jpegImage.flatMap(CMSampleBufferGetImageBuffer)
        check("mjpeg_pixel_buffer", jpegBuffer.map { CVPixelBufferGetWidth($0) == 64 && CVPixelBufferGetHeight($0) == 48 } == true)
        check("mjpeg_timestamp", jpegImage.map { CMSampleBufferGetPresentationTimeStamp($0) == CMTime(value: 1700000000000, timescale: 1000) } == true)
        check("mjpeg_device_trailer", try CameraModuleVideoSampler().imageSample(jpegFrame(jpeg + Data([0, 0xb1, 0x1a, 0, 0]))).flatMap(CMSampleBufferGetImageBuffer) != nil)
        check("mjpeg_file_source_ignored", try CameraModuleVideoSampler().imageSample(jpegFrame(jpeg, source: 2)) == nil)
        reject("mjpeg_fragment_offset") { _ = try CameraModuleVideoSampler().imageSample(jpegFrame(jpeg, offset: 1)) }
        for (index, payload) in [Data(), Data(jpeg.prefix(24)), Data([0xff, 0xd8, 0xff, 0xd9])].enumerated() {
            reject("mjpeg_invalid_\(index)") { _ = try CameraModuleVideoSampler().imageSample(jpegFrame(payload)) }
        }
        let cut = jpeg.count / 3
        func fragment(_ offset: UInt8, sequence: UInt64 = 7, channel: UInt64 = 0) -> CameraModuleVideoFrame {
            let payload = offset == 1 ? Data(jpeg.prefix(cut)) : offset == 2 ? Data(jpeg.dropFirst(cut).prefix(cut)) : Data(jpeg.dropFirst(cut * 2))
            return CameraModuleVideoFrame(format: 4, channel: channel, sequence: sequence, timestamp: 1700000000000 + UInt64(offset), isKeyframe: offset == 1, source: 1, offset: offset, payload: payload)
        }
        var fragments = CameraModuleVideoFrameAssembler()
        check("mjpeg_first_fragment_pending", try fragments.append(fragment(1)) == nil)
        check("mjpeg_middle_fragment_pending", try fragments.append(fragment(2)) == nil)
        let complete = try fragments.append(fragment(255))
        check("mjpeg_complete_frame", complete.map { $0.payload == jpeg && $0.offset == 0 && $0.isKeyframe && $0.sequence == 7 && $0.timestamp == 1700000000001 } == true)
        check("mjpeg_fragment_decode", try complete.flatMap { try CameraModuleVideoSampler().imageSample($0) }.flatMap(CMSampleBufferGetImageBuffer) != nil)
        check("mjpeg_orphan_tail_ignored", try fragments.append(fragment(255)) == nil)
        _ = try fragments.append(fragment(1))
        check("mjpeg_wrong_sequence_ignored", try fragments.append(fragment(255, sequence: 8)) == nil)
        _ = try fragments.append(fragment(1))
        _ = try fragments.append(fragment(3))
        check("mjpeg_missing_fragment_ignored", try fragments.append(fragment(255)) == nil)
        _ = try fragments.append(fragment(1))
        _ = try fragments.append(fragment(2))
        check("mjpeg_duplicate_middle_ignored", try fragments.append(fragment(2)) == nil)
        check("mjpeg_duplicate_middle_recovery", try fragments.append(fragment(255))?.payload == jpeg)
        _ = try fragments.append(fragment(1))
        _ = try fragments.append(fragment(1, sequence: 8))
        _ = try fragments.append(fragment(2, sequence: 8))
        check("mjpeg_new_frame_replaces_partial", try fragments.append(fragment(255, sequence: 8))?.payload == jpeg)
        _ = try fragments.append(fragment(1, channel: 0))
        _ = try fragments.append(fragment(1, channel: 1))
        _ = try fragments.append(fragment(2, channel: 0))
        _ = try fragments.append(fragment(2, channel: 1))
        check("mjpeg_channels_independent", try fragments.append(fragment(255, channel: 0))?.payload == jpeg && fragments.append(fragment(255, channel: 1))?.payload == jpeg)
        var sample: CMSampleBuffer?
        for vector in vectors {
            let name = vector["name"] as! String
            let packet = Data(base64Encoded: vector["packetBase64"] as! String)!
            let frame = try CameraModuleVideoProtocol.decode(packet, sessionKey: secret)
            check("\(name)_payload", frame.payload == h264 && frame.sequence == 1 && frame.timestamp == 1700000000000 && frame.isKeyframe)
            let decoder = CameraModuleVideoSampler()
            sample = try decoder.sample(frame)
            check("\(name)_sample", sample != nil)
            let image = try CameraModuleVideoSampler().imageSample(frame)
            check("\(name)_pixel_buffer", image.flatMap(CMSampleBufferGetImageBuffer).map { CVPixelBufferGetWidth($0) == 64 && CVPixelBufferGetHeight($0) == 48 } == true)
            var assembler = CameraModuleStreamAssembler()
            var received: [Data] = []
            for byte in packet { received += try assembler.append(Data([byte])) }
            check("\(name)_bytewise_stream", received == [packet])
        }
        var combined = CameraModuleStreamAssembler()
        let first = Data(base64Encoded: vectors[0]["packetBase64"] as! String)!
        check("coalesced_packets", try combined.append(first + first).count == 2)
        for data in [Data([0x68, 0x80, 0]), Data([0x68, 0xff, 0xff, 0xff, 0x7f]), Data([0x67, 0])] {
            reject("bad_stream_\(data.map { String(format: "%02x", $0) }.joined())") { var assembler = CameraModuleStreamAssembler(); _ = try assembler.append(data) }
        }
        for data in [Data(), Data([0x68, 2, 0x81]), Data([0x68, 3, 0x81, 3, 0]), Data([0x68, 6, 0x81, 3, 0, 1, 1, 16])] {
            reject("bad_video_\(data.map { String(format: "%02x", $0) }.joined())") { _ = try CameraModuleVideoProtocol.decode(data, sessionKey: secret) }
        }
        guard let sample, let format = CMSampleBufferGetFormatDescription(sample) else { throw NSError(domain: "VideoCheck", code: 1) }
        let decoded = ModuleDecodedFrame()
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { reference, _, status, _, image, _, _ in
            guard status == noErr, let reference, let image else { return }
            let frame = Unmanaged<ModuleDecodedFrame>.fromOpaque(reference).takeUnretainedValue()
            frame.width = CVPixelBufferGetWidth(image)
            frame.height = CVPixelBufferGetHeight(image)
        }, decompressionOutputRefCon: Unmanaged.passUnretained(decoded).toOpaque())
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: &callback, decompressionSessionOut: &session)
        if let session, created == noErr {
            let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            check("system_h264_decode", result == noErr && decoded.width == document["width"] as! Int && decoded.height == document["height"] as! Int)
        } else { check("system_h264_decode", false) }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "realModuleVerified": false, "scope": "official_video_play_request_static_avpacket_vectors_and_synthetic_h264_mjpeg_decode", "checks": checks]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        print("Module video checks: \(checks.count), passed: \(passed)")
        if !passed { exit(1) }
    }
}
