import SwiftUI

// Native .strings tables, selected explicitly so in-app language changes also apply
// to computed Strings. No global AppleLanguages mutation or view identity reset.
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case korean = "ko"

    var locale: Locale { Locale(identifier: rawValue) }
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .korean: return "한국어"
        }
    }

    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        allCases.map { language in
            let bundle = Bundle.main.path(forResource: language.rawValue, ofType: "lproj")
                .flatMap { Bundle(path: $0) } ?? .main
            return (language, bundle)
        }
    )

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        let fallback = Self.bundles[.english]?.localizedString(forKey: key, value: nil, table: "Localizable") ?? key
        let format = Self.bundles[self]?.localizedString(forKey: key, value: fallback, table: "Localizable") ?? fallback
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    func connectionStatus(_ raw: String) -> String {
        switch raw {
        case "Connected": return text("status.connected")
        case "Not Tested": return text("status.notTested")
        case "Failed": return text("status.failed")
        default: return raw
        }
    }

    // Presentation mappings only; protocol class and position raw values never change.
    func soundLabel(_ raw: String) -> String {
        switch raw {
        case "horn": return text("sound.horn")
        case "siren": return text("sound.siren")
        case "crash": return text("sound.crash")
        case "normal": return text("sound.normal")
        default: return raw
        }
    }

    func position(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "front": return text("position.front")
        case "right": return text("position.right")
        case "back": return text("position.back")
        case "left": return text("position.left")
        default: return text("main.directionUnavailable")
        }
    }
}

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .english
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}
