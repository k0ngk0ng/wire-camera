import AudioToolbox
import CoreMedia
import Foundation

private func moduleAudioFailure(_ message: String) -> NSError {
    NSError(domain: "WireCamera.ModuleAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct CameraModuleAudioFormat {
    let codec: UInt64
    let sampleRate: UInt64
    let bits: UInt64
    let channels: UInt64

    init(response: Data) throws {
        guard try CameraModuleNetworkProtocol.protobufInteger(response, field: 1) ?? 0 == 0 else {
            throw moduleAudioFailure("摄像头模块未能开启声音。请重新连接后重试。")
        }
        codec = try CameraModuleNetworkProtocol.protobufInteger(response, field: 5) ?? 0
        sampleRate = try CameraModuleNetworkProtocol.protobufInteger(response, field: 6) ?? 0
        bits = try CameraModuleNetworkProtocol.protobufInteger(response, field: 7) ?? 0
        channels = try CameraModuleNetworkProtocol.protobufInteger(response, field: 8) ?? 0
        guard codec == 21 else { throw moduleAudioFailure("摄像头使用了尚未支持的声音编码（\(codec)）。") }
        guard (8000...96000).contains(sampleRate), bits == 16, (1...2).contains(channels) else {
            throw moduleAudioFailure("摄像头返回的声音采样参数不受支持。")
        }
    }
}

final class CameraModuleAudioSampler {
    static let playCommand: UInt64 = 2614
    private let format: CameraModuleAudioFormat
    private var description: CMAudioFormatDescription?

    static func playBody(channel: UInt64 = 0) -> Data {
        channel == 0 ? Data() : Data([8]) + Data(CameraModuleNetworkProtocol.varint(channel))
    }

    init(format: CameraModuleAudioFormat) { self.format = format }

    func sample(_ frame: CameraModuleVideoFrame) throws -> CMSampleBuffer? {
        guard frame.format > 20, frame.source != 2 else { return nil }
        guard frame.format == format.codec else { throw moduleAudioFailure("摄像头声音编码发生变化，请重新连接。") }
        guard frame.offset == 0, !frame.payload.isEmpty,
              frame.payload.count <= CameraModuleNetworkProtocol.maximumFrameSize,
              frame.payload.count % Int(format.channels) == 0,
              frame.timestamp <= Int64.max else {
            throw moduleAudioFailure("摄像头声音帧不完整。")
        }
        let pcm = frame.payload.map { byte -> Int16 in
            let value = Int(byte ^ 0x55)
            let segment = (value & 0x70) >> 4
            var magnitude = (value & 15) << 4
            if segment == 0 { magnitude += 8 }
            else {
                magnitude += 0x108
                if segment > 1 { magnitude <<= segment - 1 }
            }
            return Int16(value & 0x80 == 0 ? -magnitude : magnitude).littleEndian
        }
        if description == nil {
            var basic = AudioStreamBasicDescription(mSampleRate: Double(format.sampleRate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(format.channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(format.channels * 2), mChannelsPerFrame: UInt32(format.channels), mBitsPerChannel: 16, mReserved: 0)
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &basic, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr else {
                throw moduleAudioFailure("无法建立摄像头声音格式。")
            }
        }
        var block: CMBlockBuffer?
        let byteCount = pcm.count * 2
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw moduleAudioFailure("无法建立摄像头声音缓冲区。")
        }
        let copied = pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
        guard copied == noErr, let description else { throw moduleAudioFailure("无法写入摄像头声音缓冲区。") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(format.sampleRate)), presentationTimeStamp: CMTime(value: Int64(frame.timestamp), timescale: 1000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: pcm.count / Int(format.channels), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else {
            throw moduleAudioFailure("无法建立摄像头声音帧。")
        }
        return sample
    }
}
