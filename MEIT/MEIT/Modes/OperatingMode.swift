enum OperatingMode: String, CaseIterable, Codable {
    case hardware
    case fallback

    var localizationKey: String {
        switch self {
        case .hardware: return "mode.hardware"
        case .fallback: return "mode.fallback"
        }
    }
}
