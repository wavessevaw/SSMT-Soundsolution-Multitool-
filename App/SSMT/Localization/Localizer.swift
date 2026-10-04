import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru
    var id: String { rawValue }
}

/// In-app language switch over the compiled String Catalog (Localizable.xcstrings).
@MainActor
final class Localizer: ObservableObject {
    @AppStorage("ssmt.language") private var stored: String = AppLanguage.system.rawValue
    @Published private(set) var bundle: Bundle = .main

    var language: AppLanguage {
        get { AppLanguage(rawValue: stored) ?? .system }
        set {
            stored = newValue.rawValue
            bundle = Self.bundle(for: newValue)
            objectWillChange.send()
            ProfileCenter.shared.record("ui.language")
        }
    }

    init() {
        bundle = Self.bundle(for: AppLanguage(rawValue: stored) ?? .system)
    }

    /// Locale matching the selected interface language (for dates and numbers).
    var locale: Locale {
        switch language {
        case .system: return .current
        case .en: return Locale(identifier: "en_US")
        case .ru: return Locale(identifier: "ru_RU")
        }
    }

    func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: args)
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard language != .system,
              let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let b = Bundle(path: path) else { return .main }
        return b
    }
}
