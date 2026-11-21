import AVFoundation
import CoreImage
import Foundation

final class CameraRemoteMedia {
    private let queue = DispatchQueue(label: "camera.remote-media", qos: .userInitiated)
    private let lock = NSLock()
    private var viewers: Set<String> = []
    private var pending: Set<String> = []
    private var lastFrame: [String: TimeInterval] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var converters: [String: AVAudioConverter] = [:]
    var onPacket: ((Data, UInt8, String) -> Void)?

    func setViewers(_ sources: Set<String>) {
        lock.lock(); viewers = sources; lock.unlock()
        queue.async { self.converters = self.converters.filter { sources.contains($0.key) } }
    }

    func video(_ sample: CMSampleBuffer, sourceID: String, mirrored: Bool) {
        lock.lock()
        let wanted = viewers.contains(sourceID) && !pending.contains(sourceID)
        if wanted { pending.insert(sourceID) }
        lock.unlock()
        guard wanted else { return }
        queue.async {
            defer { self.lock.lock(); self.pending.remove(sourceID); self.lock.unlock() }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastFrame[sourceID, default: 0] >= 0.1, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
            self.lastFrame[sourceID] = now
            var image = CIImage(cvPixelBuffer: pixels)
            let factor = min(1, 1280 / max(image.extent.width, image.extent.height))
            image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            if mirrored { image = image.transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0).scaledBy(x: -1, y: 1)) }
            if let data = self.context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) { self.onPacket?(data, 1, sourceID) }
        }
    }

    func audio(_ sample: CMSampleBuffer, sourceID: String) {
        lock.lock(); let wanted = viewers.contains(sourceID); lock.unlock()
        guard wanted else { return }
        queue.async {
            guard let description = CMSampleBufferGetFormatDescription(sample) else { return }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else { return }
            input.frameLength = input.frameCapacity
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(input.frameLength), into: input.mutableAudioBufferList) == noErr,
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true) else { return }
            if self.converters[sourceID]?.inputFormat != format { self.converters[sourceID] = AVAudioConverter(from: format, to: outputFormat) }
            guard let converter = self.converters[sourceID], let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 8000 / format.sampleRate) + 64) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            guard error == nil, output.frameLength > 0, let bytes = output.int16ChannelData?.pointee else { return }
            self.onPacket?(Data(bytes: bytes, count: Int(output.frameLength) * 2), 2, sourceID)
        }
    }
}
