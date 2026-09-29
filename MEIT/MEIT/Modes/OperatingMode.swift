enum OperatingMode: String, CaseIterable, Codable {
    case hardware
    case fallback

    var displayName: String {
        switch self {
        case .hardware: return "hardware"
        case .fallback: return "iphone fallback"
        }
    }
}
