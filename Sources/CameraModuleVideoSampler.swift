import CommonCrypto
import CoreGraphics
import CoreMedia
import CryptoKit
import Foundation
import ImageIO
import VideoToolbox

private func moduleVideoFailure(_ message: String) -> NSError {
    NSError(domain: "WireCamera.ModuleVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct CameraModuleVideoFrame {
    let format: UInt8
    let channel: UInt64
    let sequence: UInt64
    let timestamp: UInt64
    let isKeyframe: Bool
    let source: UInt8
    let offset: UInt8
    let payload: Data
}

struct CameraModuleVideoFrameAssembler {
    private struct Partial {
        let first: CameraModuleVideoFrame
        var payload: Data
        var nextOffset: UInt8
    }

    private var pending: [UInt64: Partial] = [:]

    mutating func append(_ frame: CameraModuleVideoFrame) throws -> CameraModuleVideoFrame? {
        let key = (frame.channel << 8) | UInt64(frame.format)
        guard !frame.payload.isEmpty, frame.payload.count <= CameraModuleNetworkProtocol.maximumFrameSize else {
            pending.removeValue(forKey: key)
            throw moduleVideoFailure("摄像头视频分片的大小不正确。")
        }
        if frame.offset == 0 {
            pending.removeValue(forKey: key)
            return frame
        }
        if frame.offset == 1 {
            pending[key] = Partial(first: frame, payload: frame.payload, nextOffset: 2)
            return nil
        }
        guard var partial = pending[key] else { return nil }
        guard frame.sequence == partial.first.sequence, frame.source == partial.first.source else {
            pending.removeValue(forKey: key)
            return nil
        }
        if frame.offset != 255 {
            if frame.offset < partial.nextOffset { return nil }
            guard frame.offset == partial.nextOffset else {
                pending.removeValue(forKey: key)
                return nil
            }
        }
        guard partial.payload.count <= CameraModuleNetworkProtocol.maximumFrameSize - frame.payload.count else {
            pending.removeValue(forKey: key)
            throw moduleVideoFailure("摄像头完整视频帧超过大小限制。")
        }
        partial.payload.append(frame.payload)
        if frame.offset == 255 {
            pending.removeValue(forKey: key)
            let first = partial.first
            return CameraModuleVideoFrame(format: first.format, channel: first.channel, sequence: first.sequence, timestamp: first.timestamp, isKeyframe: first.isKeyframe, source: first.source, offset: 0, payload: partial.payload)
        }
        partial.nextOffset += 1
        pending[key] = partial
        return nil
    }
}

private struct ModuleVideoReader {
    let bytes: [UInt8]
    var offset = 0

    var remaining: Int { bytes.count - offset }

    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw moduleVideoFailure("摄像头视频报文不完整。") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func data(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw moduleVideoFailure("摄像头视频报文的长度不正确。") }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let next = try byte()
            guard shift < 63 || next <= 1 else { throw moduleVideoFailure("视频报文中的整数超出范围。") }
            value |= UInt64(next & 0x7f) << shift
            if next & 0x80 == 0 {
                guard shift == 0 || next != 0 else { throw moduleVideoFailure("视频报文中的整数编码不正确。") }
                return value
            }
        }
        throw moduleVideoFailure("视频报文中的整数编码不正确。")
    }
}

struct CameraModuleStreamAssembler {
    private var pending = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        guard data.count <= CameraModuleNetworkProtocol.maximumFrameSize + 16,
              pending.count <= CameraModuleNetworkProtocol.maximumFrameSize + 16 - data.count else {
            throw moduleVideoFailure("摄像头网络接收缓冲区超过限制。")
        }
        pending.append(data)
        var packets: [Data] = []
        while !pending.isEmpty {
            let bytes = Array(pending)
            guard [0x48, 0x68, 0x69, 0x6a, 0x2a].contains(bytes[0]) else { throw moduleVideoFailure("摄像头返回了不支持的网络数据。") }
            guard bytes.count >= 2 else { break }
            var length: UInt64 = 0
            var headerLength = 0
            for index in 1..<min(bytes.count, 6) {
                let byte = bytes[index]
                length |= UInt64(byte & 0x7f) << ((index - 1) * 7)
                if byte & 0x80 == 0 {
                    guard index == 1 || byte != 0 else { throw moduleVideoFailure("摄像头帧长度不是规范的整数编码。") }
                    headerLength = index + 1
                    break
                }
            }
            if headerLength == 0 {
                guard bytes.count < 6 else { throw moduleVideoFailure("摄像头帧长度超出范围。") }
                break
            }
            guard length > 0, length <= CameraModuleNetworkProtocol.maximumFrameSize else { throw moduleVideoFailure("摄像头网络帧长度超出范围。") }
            let total = headerLength + Int(length)
            guard bytes.count >= total else { break }
            packets.append(Data(bytes.prefix(total)))
            pending = Data(bytes.dropFirst(total))
        }
        return packets
    }
}

enum CameraModuleVideoProtocol {
    static let playCommand: UInt64 = 2610

    static func playBody(channel: UInt64 = 0, qos: UInt64 = 0, speed: UInt64 = 0) -> Data {
        integerField(1, channel) + integerField(2, qos) + integerField(3, speed)
    }

    static func decode(_ packet: Data, sessionKey: Data) throws -> CameraModuleVideoFrame {
        guard packet.count <= CameraModuleNetworkProtocol.maximumFrameSize + 16 else { throw moduleVideoFailure("摄像头视频帧超过大小限制。") }
        var reader = ModuleVideoReader(bytes: Array(packet))
        let kind = try reader.byte()
        guard [0x68, 0x69, 0x6a].contains(kind) else { throw moduleVideoFailure("摄像头返回的报文不是受支持的视频帧。") }
        let length = try reader.varint()
        guard length == UInt64(reader.remaining) else { throw moduleVideoFailure("摄像头视频帧长度不匹配。") }
        let format = try reader.byte()
        let encryption = try reader.byte()
        let channel = try reader.varint()
        let sequence = try reader.varint()
        let timestamp = try reader.varint()
        let encryptedLength = try reader.varint()
        guard timestamp <= Int64.max, channel <= 0x0fff_ffff, sequence <= 0x0fff_ffff else { throw moduleVideoFailure("摄像头视频帧的标识超出范围。") }
        var source: UInt8 = 1
        if kind != 0x68 {
            source = try reader.byte()
            guard source <= 2 else { throw moduleVideoFailure("摄像头视频帧的来源不受支持。") }
            if source == 2 { _ = try reader.varint() }
        }
        let offset: UInt8 = kind == 0x6a ? try reader.byte() : 0
        let extensionLength: UInt64 = kind == 0x68 ? 0 : try reader.varint()
        guard extensionLength <= UInt64(reader.remaining) else { throw moduleVideoFailure("摄像头视频帧的扩展区不完整。") }
        let extensionData = try reader.data(Int(extensionLength))
        var payload = try reader.data(reader.remaining)
        guard !payload.isEmpty, encryptedLength <= UInt64(payload.count) else { throw moduleVideoFailure("摄像头视频帧的密文长度不正确。") }
        if encryptedLength > 0 || (encryption != 0 && !extensionData.isEmpty) {
            guard encryption == 3, !sessionKey.isEmpty else { throw moduleVideoFailure("摄像头使用了尚未支持的视频加密方式。") }
            var material = sessionKey
            material.append(Data(",AVSeq:\(sequence)-TT:\(timestamp)-AVChannel:\(channel)".utf8))
            let key = Data(Insecure.MD5.hash(data: material).map { String(format: "%02x", $0) }.joined().utf8)
            if encryptedLength > 0 {
                guard encryptedLength % 16 == 0 else { throw moduleVideoFailure("摄像头视频密文没有按 AES 块对齐。") }
                let prefix = try decrypt(payload.prefix(Int(encryptedLength)), key: key, padded: false)
                payload = prefix + payload.dropFirst(Int(encryptedLength))
            }
            if !extensionData.isEmpty { _ = try decrypt(extensionData, key: key, padded: true) }
        }
        return CameraModuleVideoFrame(format: format & 0x7f, channel: channel, sequence: sequence, timestamp: timestamp, isKeyframe: format & 0x80 != 0, source: source, offset: offset, payload: payload)
    }

    private static func integerField(_ field: UInt64, _ value: UInt64) -> Data {
        value == 0 ? Data() : Data(CameraModuleNetworkProtocol.varint(field * 8)) + Data(CameraModuleNetworkProtocol.varint(value))
    }

    private static func decrypt(_ data: Data, key: Data, padded: Bool) throws -> Data {
        guard !data.isEmpty, data.count % 16 == 0 else { throw moduleVideoFailure("摄像头视频密文长度不正确。") }
        let iv = key.suffix(16)
        var result = Data(count: data.count)
        var length = 0
        let capacity = result.count
        let status = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, data.count, output.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess, length == data.count else { throw moduleVideoFailure("无法解密摄像头视频数据。") }
        result.count = length
        if padded {
            guard let count = result.last, count > 0, count <= 16, Int(count) <= result.count,
                  result.suffix(Int(count)).allSatisfy({ $0 == count }) else { throw moduleVideoFailure("摄像头视频扩展区的加密填充不正确。") }
            result.removeLast(Int(count))
        }
        return result
    }
}

final class CameraModuleVideoSampler {
    private var sequenceParameterSet: Data?
    private var pictureParameterSet: Data?
    private var format: CMVideoFormatDescription?
    private var awaitingKeyframe = true
    private var decoder: VTDecompressionSession?
    private var decoderFormat: CMFormatDescription?
    private let imageLock = NSLock()
    private var decodedImage: CVImageBuffer?
    private var decodedTime = CMTime.invalid

    deinit {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }

    func imageSample(_ frame: CameraModuleVideoFrame) throws -> CMSampleBuffer? {
        guard frame.format <= 20, frame.source != 2 else { return nil }
        guard frame.offset == 0 else { throw moduleVideoFailure("摄像头返回了尚未支持的视频片段偏移。") }
        if frame.format == 4 {
            return try jpegSample(frame)
        }
        guard let compressed = try sample(frame), let description = CMSampleBufferGetFormatDescription(compressed) else { return nil }
        if decoder == nil || decoderFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: description) }) == true {
            if let decoder { VTDecompressionSessionInvalidate(decoder) }
            decoder = nil
            var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { reference, _, status, _, image, timestamp, _ in
                guard status == noErr, let reference, let image else { return }
                let sampler = Unmanaged<CameraModuleVideoSampler>.fromOpaque(reference).takeUnretainedValue()
                sampler.imageLock.lock()
                sampler.decodedImage = image
                sampler.decodedTime = timestamp
                sampler.imageLock.unlock()
            }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
            let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
            let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: &callback, decompressionSessionOut: &decoder)
            guard status == noErr, decoder != nil else { throw moduleVideoFailure("无法创建摄像头 H.264 解码器。") }
            decoderFormat = description
        }
        guard let decoder else { return nil }
        imageLock.lock()
        decodedImage = nil
        imageLock.unlock()
        guard VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: compressed, flags: [], frameRefcon: nil, infoFlagsOut: nil) == noErr else {
            throw moduleVideoFailure("摄像头视频帧无法解码。")
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        imageLock.lock()
        let image = decodedImage
        let timestamp = decodedTime
        imageLock.unlock()
        guard let image else { return nil }
        return try imageSample(image, timestamp: timestamp)
    }

    private func jpegSample(_ frame: CameraModuleVideoFrame) throws -> CMSampleBuffer {
        guard frame.payload.starts(with: [0xff, 0xd8, 0xff]),
              let end = frame.payload.range(of: Data([0xff, 0xd9]), options: .backwards),
              frame.payload.distance(from: end.upperBound, to: frame.payload.endIndex) <= 64 else {
            throw moduleVideoFailure("摄像头返回的 JPEG 画面不完整。")
        }
        let jpeg = frame.payload[..<end.upperBound]
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil), CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw moduleVideoFailure("摄像头返回的 JPEG 画面不完整或尺寸不受支持。")
        }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, let buffer else {
            throw moduleVideoFailure("无法创建摄像头 JPEG 画面缓冲区。")
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw moduleVideoFailure("无法访问摄像头 JPEG 画面缓冲区。") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else {
            throw moduleVideoFailure("无法解码摄像头 JPEG 画面。")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try imageSample(buffer, timestamp: CMTime(value: Int64(frame.timestamp), timescale: 1000))
    }

    private func imageSample(_ image: CVImageBuffer, timestamp: CMTime) throws -> CMSampleBuffer {
        var imageFormat: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &imageFormat) == noErr, let imageFormat else {
            throw moduleVideoFailure("无法读取摄像头解码后的画面格式。")
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: imageFormat, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else {
            throw moduleVideoFailure("无法建立摄像头解码后的画面缓冲区。")
        }
        return sample
    }

    func sample(_ frame: CameraModuleVideoFrame) throws -> CMSampleBuffer? {
        guard frame.format <= 20, frame.source != 2 else { return nil }
        guard frame.offset == 0 else { throw moduleVideoFailure("摄像头返回了尚未支持的视频片段偏移。") }
        let units = try nalUnits(frame.payload)
        var changed = false
        var isKeyframe = false
        var hasSlice = false
        for unit in units {
            let type = unit[0] & 0x1f
            guard unit[0] & 0x80 == 0, (1...23).contains(type) else { throw moduleVideoFailure("摄像头返回了无效或尚未支持的视频编码。") }
            if type == 7 {
                guard unit.count >= 4 else { throw moduleVideoFailure("摄像头 H.264 参数集不完整。") }
                if unit != sequenceParameterSet { sequenceParameterSet = unit; changed = true }
            } else if type == 8 {
                guard unit.count >= 2 else { throw moduleVideoFailure("摄像头 H.264 参数集不完整。") }
                if unit != pictureParameterSet { pictureParameterSet = unit; changed = true }
            }
            if (1...5).contains(type) { hasSlice = true }
            if type == 5 { isKeyframe = true }
        }
        if changed { format = nil; awaitingKeyframe = true }
        if format == nil, let sequenceParameterSet, let pictureParameterSet {
            var candidate: CMFormatDescription?
            let status = sequenceParameterSet.withUnsafeBytes { sequenceBytes in
                pictureParameterSet.withUnsafeBytes { pictureBytes in
                    let pointers = [sequenceBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), pictureBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                    let sizes = [sequenceParameterSet.count, pictureParameterSet.count]
                    return pointers.withUnsafeBufferPointer { pointerBuffer in
                        sizes.withUnsafeBufferPointer { sizeBuffer in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointerBuffer.baseAddress!, parameterSetSizes: sizeBuffer.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &candidate)
                        }
                    }
                }
            }
            guard status == noErr, let candidate else { throw moduleVideoFailure("无法读取摄像头 H.264 画面参数。") }
            format = candidate
        }
        guard let format, hasSlice else { return nil }
        if isKeyframe { awaitingKeyframe = false }
        guard !awaitingKeyframe else { return nil }
        var data = Data()
        for unit in units {
            var count = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(unit)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else {
            throw moduleVideoFailure("无法创建摄像头视频缓冲区。")
        }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == kCMBlockBufferNoErr else { throw moduleVideoFailure("无法写入摄像头视频缓冲区。") }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(frame.timestamp), timescale: 1000), decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else {
            throw moduleVideoFailure("无法创建摄像头视频帧。")
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
            attachments.first?[kCMSampleAttachmentKey_NotSync] = !isKeyframe
        }
        return sample
    }

    private func nalUnits(_ data: Data) throws -> [Data] {
        let bytes = Array(data)
        guard !bytes.isEmpty else { throw moduleVideoFailure("摄像头视频帧为空。") }
        var starts: [(Int, Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { starts.append((index, 3)); index += 3; continue }
                if index + 3 < bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 { starts.append((index, 4)); index += 4; continue }
            }
            index += 1
        }
        if let first = starts.first {
            guard bytes[..<first.0].allSatisfy({ $0 == 0 }) else { throw moduleVideoFailure("摄像头 H.264 帧头不正确。") }
            return try starts.enumerated().map { offset, value in
                let start = value.0 + value.1
                var end = offset + 1 < starts.count ? starts[offset + 1].0 : bytes.count
                while end > start && bytes[end - 1] == 0 { end -= 1 }
                guard start < end else { throw moduleVideoFailure("摄像头包含空的 H.264 NAL 单元。") }
                return Data(bytes[start..<end])
            }
        }
        var units: [Data] = []
        index = 0
        while index + 4 <= bytes.count {
            let count = bytes[index..<(index + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            index += 4
            guard count > 0, count <= bytes.count - index else { throw moduleVideoFailure("摄像头返回了尚未支持的 H.264 封装。") }
            units.append(Data(bytes[index..<(index + Int(count))]))
            index += Int(count)
        }
        guard index == bytes.count, !units.isEmpty else { throw moduleVideoFailure("摄像头 H.264 帧封装不完整。") }
        return units
    }
}
