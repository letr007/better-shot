import Foundation

nonisolated enum L10n {
    static func string(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: .current, arguments: arguments)
    }

    static func format(_ key: String, bundle: Bundle, locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: string(key, bundle: bundle), locale: locale, arguments: arguments)
    }
}
