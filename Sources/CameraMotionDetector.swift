import CoreVideo
import Foundation

final class CameraMotionDetector {
    private var previous: [UInt8]?
    private var wasChanging = false
    private let columns = 96
    private let rows = 72

    func process(_ pixels: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferIsPlanar(pixels), let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return false }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0), stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var current: [UInt8] = []
        current.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y = min(height - 1, (2 * row + 1) * height / (2 * rows))
            for column in 0..<columns { current.append(bytes[y * stride + min(width - 1, (2 * column + 1) * width / (2 * columns))]) }
        }
        defer { previous = current }
        guard let previous else { return false }
        var histogram = [Int](repeating: 0, count: 511)
        var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0, sumXY = 0.0
        for index in current.indices {
            let x = Double(previous[index]), y = Double(current[index])
            histogram[Int(current[index]) - Int(previous[index]) + 255] += 1
            sumX += x; sumY += y; sumXX += x * x; sumYY += y * y; sumXY += x * y
        }
        let count = Double(current.count), meanX = sumX / count, meanY = sumY / count
        let varianceX = max(0, sumXX / count - meanX * meanX), varianceY = max(0, sumYY / count - meanY * meanY)
        let covariance = sumXY / count - meanX * meanY
        var cumulative = 0, median = 0
        for index in histogram.indices { cumulative += histogram[index]; if cumulative >= current.count / 2 { median = index - 255; break } }
        let gain = varianceX > 1 ? covariance / varianceX : 1
        let offset = meanY - gain * meanX
        var changed = 0, residual = 0.0, exposureResidual = 0.0
        for index in current.indices {
            let difference = abs(Int(current[index]) - Int(previous[index]) - median)
            if difference >= 18 { changed += 1 }
            residual += Double(difference)
            exposureResidual += abs(Double(current[index]) - (gain * Double(previous[index]) + offset))
        }
        let correlation = varianceX > 1 && varianceY > 1 ? covariance / sqrt(varianceX * varianceY) : 0
        if correlation > 0.985 && (0.5...2).contains(gain) && exposureResidual / count < 4 { wasChanging = false; return false }
        let ratio = Double(changed) / count, average = residual / count
        let changing = ratio >= 0.035 && average >= 2.5
        let detected = changing && (wasChanging || (ratio >= 0.18 && average >= 5))
        wasChanging = changing
        return detected
    }
}
