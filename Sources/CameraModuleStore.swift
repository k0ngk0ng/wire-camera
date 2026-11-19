import Foundation

final class CameraModuleStore {
    private struct Record: Codable {
        let deviceID: String
        let address: String
    }

    private let fileURL: URL
    private(set) var devices: [CameraModuleNetworkDevice] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL), data.count <= 131072,
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        for record in records.prefix(128) {
            guard let address = try? CameraModuleNetworkProtocol.manualAddress(record.address),
                  (try? CameraModuleNetworkProtocol.discovery(deviceID: record.deviceID)) != nil,
                  !devices.contains(where: { $0.deviceID == record.deviceID }) else { continue }
            devices.append(CameraModuleNetworkDevice(deviceID: record.deviceID, address: address, port: 20190))
        }
    }

    func save(_ device: CameraModuleNetworkDevice) throws {
        let address = try CameraModuleNetworkProtocol.manualAddress(device.address)
        _ = try CameraModuleNetworkProtocol.discovery(deviceID: device.deviceID)
        guard device.port == 20190 else { throw NSError(domain: "WireCamera.ModuleStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "摄像头模块的端口不正确。"] ) }
        let normalized = CameraModuleNetworkDevice(deviceID: device.deviceID, address: address, port: 20190)
        var updated = devices
        if let index = updated.firstIndex(where: { $0.deviceID == device.deviceID }) { updated[index] = normalized }
        else { updated.append(normalized) }
        let records = updated.map { Record(deviceID: $0.deviceID, address: $0.address) }
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        devices = updated
    }
}
