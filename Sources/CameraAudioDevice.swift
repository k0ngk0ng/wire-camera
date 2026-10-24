import AVFoundation
import IOKit

func cameraAudioDevice(for camera: AVCaptureDevice) -> AVCaptureDevice? {
    let linked = camera.linkedDevices.filter { $0.hasMediaType(.audio) && $0.isConnected }
    if linked.count == 1 { return linked[0] }
    guard camera.uniqueID.hasPrefix("0x"),
          let packed = UInt64(camera.uniqueID.dropFirst(2), radix: 16) else { return nil }
    let location = UInt32(truncatingIfNeeded: packed >> 32)
    let vendor = UInt32((packed >> 16) & 0xffff)
    let product = UInt32(packed & 0xffff)
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var serial: String?
    while true {
        let entry = IOIteratorNext(iterator)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        func property(_ name: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        if (property("locationID") as? NSNumber)?.uint32Value == location,
           (property("idVendor") as? NSNumber)?.uint32Value == vendor,
           (property("idProduct") as? NSNumber)?.uint32Value == product {
            serial = property("USB Serial Number") as? String
        }
    }
    guard let serial, !serial.isEmpty else { return nil }
    let inputs = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    let matches = inputs.filter {
        $0.transportType == 0x75736220 && $0.uniqueID.split(separator: ":").contains(Substring(serial))
    }
    return matches.count == 1 ? matches[0] : nil
}
