import Foundation

/// Resource and lookup checks only: no app windows, permissions, or user preferences are touched.
@main
enum LocalizationCheck {
    static func main() {
        do {
            try runChecks()
        } catch {
            FileHandle.standardError.write(Data("LocalizationCheck failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func runChecks() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resourceRoot = root.appendingPathComponent("Resources/Localization")
        let english = try strings(resourceRoot.appendingPathComponent("en.lproj/Localizable.strings"))
        let chinese = try strings(resourceRoot.appendingPathComponent("zh-Hans.lproj/Localizable.strings"))
        precondition(Set(english.keys) == Set(chinese.keys), "English and Chinese resource keys must agree")
        for (key, value) in english {
            let translated = chinese[key]!
            precondition(!translated.isEmpty, "Empty translation: \(key)")
            let sourcePlaceholders = try placeholders(value)
            let translatedPlaceholders = try placeholders(translated)
            precondition(sourcePlaceholders == translatedPlaceholders, "Format placeholders differ: \(key)")
        }
        let enInfo = try strings(resourceRoot.appendingPathComponent("en.lproj/InfoPlist.strings"))
        let zhInfo = try strings(resourceRoot.appendingPathComponent("zh-Hans.lproj/InfoPlist.strings"))
        precondition(Set(enInfo.keys) == Set(zhInfo.keys), "Permission descriptions must cover both languages")

        let englishBundle = Bundle(path: resourceRoot.appendingPathComponent("en.lproj").path)!
        let chineseBundle = Bundle(path: resourceRoot.appendingPathComponent("zh-Hans.lproj").path)!
        precondition(L10n.string("Copy", bundle: englishBundle) == "Copy")
        precondition(L10n.string("Copy", bundle: chineseBundle) == "复制")
        precondition(L10n.string("Never", bundle: chineseBundle) == "永不", "Named inspector values must be translated")
        let title = "My custom preset title"
        precondition(L10n.string(title, bundle: chineseBundle) == title, "Unknown/user-provided text must be preserved")
        let progress = L10n.format("Downloading… %d%%", bundle: chineseBundle, locale: Locale(identifier: "zh_CN"), 42)
        precondition(progress.contains("42%") && !progress.contains("Downloading"), "Localized format must keep numbers and literal percent signs")

        let sources = root.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        let explicitCalls = try NSRegularExpression(pattern: #"\b(?:L10n\.(?:string|format)|NSLocalizedString)\s*\(\s*("(?:\\.|[^"\\])*")"#)
        let helperCalls = try NSRegularExpression(pattern: #"\b(?:InspectorSlider|InspectorSection|InspectorDisclosureSection|InspectorRow|InspectorGroupLabel|StudioEffectSection|StudioAmountEffect)\s*\(\s*("(?:\\.|[^"\\])*")"#)
        var referenced = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for expression in [explicitCalls, helperCalls] {
                for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let literal = (text as NSString).substring(with: match.range(at: 1))
                    // Variable phrases use explicit format keys; do not treat Swift interpolation as a resource key.
                    guard !literal.contains("\\(") else {
                        preconditionFailure("Interpolated localization key in \(url.lastPathComponent); use a format key")
                    }
                    let key = try decodeLiteral(literal)
                    if !key.isEmpty { referenced.insert(key) }
                }
            }
        }
        let missing = referenced.subtracting(english.keys)
        guard missing.isEmpty else {
            throw NSError(domain: "LocalizationCheck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing explicit/helper resource keys: \(missing.sorted())"
            ])
        }

        if let metadataPath = ProcessInfo.processInfo.environment["BETTERSHOT_LOCALIZATION_METADATA"] {
            let metadataRoot = URL(fileURLWithPath: metadataPath)
            let metadata = FileManager.default.enumerator(at: metadataRoot, includingPropertiesForKeys: nil)!
            var compilerKeys = Set<String>()
            for case let url as URL in metadata where url.pathExtension == "stringsdata" {
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                guard let source = json?["source"] as? String, source.contains("/Sources/"),
                      let tables = json?["tables"] as? [String: Any],
                      let entries = tables["Localizable"] as? [[String: Any]] else { continue }
                entries.compactMap { $0["key"] as? String }.filter { !$0.isEmpty }
                    .forEach { compilerKeys.insert($0) }
            }
            let missingCompiler = compilerKeys.subtracting(english.keys)
            guard missingCompiler.isEmpty else {
                throw NSError(domain: "LocalizationCheck", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Missing compiler-extracted UI keys: \(missingCompiler.sorted())"
                ])
            }
            print("PASS \(compilerKeys.count) Apple compiler-extracted UI keys")
        }
        print("LocalizationCheck: \(english.count) matching English/Chinese entries, \(referenced.count) explicit/helper references, permission descriptions, placeholders, lookup, formatting, and fallback passed")
    }

    private static func strings(_ url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let keyPattern = try NSRegularExpression(pattern: #"(?m)^\s*("(?:\\.|[^"\\])*")\s*="#)
        var seen = Set<String>()
        for match in keyPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let literal = (text as NSString).substring(with: match.range(at: 1))
            let key = try decodeLiteral(literal)
            precondition(seen.insert(key).inserted, "Duplicate resource key in \(url.path): \(key)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-convert", "xml1", "-o", "-", url.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Invalid strings resource: \(url.path)")
        return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
    }

    private static func decodeLiteral(_ literal: String) throws -> String {
        var literal = literal
        let unicode = try NSRegularExpression(pattern: #"\\u\{([0-9a-fA-F]+)\}"#)
        for match in unicode.matches(in: literal, range: NSRange(literal.startIndex..., in: literal)).reversed() {
            let hex = (literal as NSString).substring(with: match.range(at: 1))
            let scalar = UnicodeScalar(UInt32(hex, radix: 16)!)!
            literal = (literal as NSString).replacingCharacters(in: match.range, with: String(scalar))
        }
        return try JSONDecoder().decode(String.self, from: Data(literal.utf8))
    }

    private static func placeholders(_ text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(?:ll|l|hh|h|z|t|j)?[@diuoxXfFeEgGcsp%]"#)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            (text as NSString).substring(with: $0.range)
        }
    }
}
