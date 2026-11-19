enum CameraModuleDiscovery {
    static func bluetoothName(advertised: String?, cached: String?) -> String? {
        for name in [advertised, cached].compactMap({ $0 }) {
            if name.hasPrefix("LLM_") || name.hasPrefix("AXH_") { return name }
        }
        return nil
    }
}
