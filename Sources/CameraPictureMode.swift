import AVFoundation
import CoreMedia

struct CameraPictureMode {
    let identifier: String
    let title: String
    let format: AVCaptureDevice.Format?

    var dimensions: CMVideoDimensions? {
        format.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
    }

    static func available(for device: AVCaptureDevice) -> [CameraPictureMode] {
        var modes: [CameraPictureMode] = []
        for (identifier, numerator, denominator) in [("4:3", 4, 3), ("16:9", 16, 9)] {
            let formats = device.formats.filter { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return size.width > 0 && size.height > 0 && Int(size.width) * denominator == Int(size.height) * numerator
            }.sorted { first, second in
                let firstSize = CMVideoFormatDescriptionGetDimensions(first.formatDescription)
                let secondSize = CMVideoFormatDescriptionGetDimensions(second.formatDescription)
                let firstArea = Int64(firstSize.width) * Int64(firstSize.height)
                let secondArea = Int64(secondSize.width) * Int64(secondSize.height)
                if firstArea != secondArea { return firstArea > secondArea }
                let firstRate = first.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                let secondRate = second.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return firstRate > secondRate
            }
            if let format = formats.first {
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                modes.append(CameraPictureMode(identifier: identifier, title: "\(identifier) · \(size.width) × \(size.height)", format: format))
            }
        }
        if modes.isEmpty { modes.append(CameraPictureMode(identifier: "auto", title: "自动画面比例", format: nil)) }
        return modes
    }
}
