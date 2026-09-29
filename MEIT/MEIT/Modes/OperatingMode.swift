enum OperatingMode: String, CaseIterable, Codable {
    case hardware
    case fallback

    var displayName: String {
        switch self {
        case .hardware: return "Hardware"
        case .fallback: return "iPhone Fallback"
        }
    }
}
