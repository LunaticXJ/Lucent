import Foundation

/// Presentation preferences only. Wire dates and media identities stay unchanged.
struct LocalizationPreferences: Sendable {
    var interface = "system"
    var content = "auto"
    var subtitles = "auto"
    var audio = "original"
    var region = "system"
    var dateOrder = "system"
    var clock = "system"
    var zone = "system"
    var systemLanguages = Locale.preferredLanguages
    var systemLocale = Locale.autoupdatingCurrent.identifier
    var systemZone = TimeZone.autoupdatingCurrent.identifier

    static var current: Self {
        let defaults = UserDefaults.standard
        var value = Self()
        value.interface = defaults.string(forKey: "lucent.locale.interface") ?? "system"
        value.content = defaults.string(forKey: "lucent.locale.content") ?? "auto"
        value.subtitles = defaults.string(forKey: "lucent.locale.subtitles") ?? "auto"
        value.audio = defaults.string(forKey: "lucent.locale.audio") ?? "original"
        // Region, date order, clock and time zone follow the system by design;
        // there is no UI to override them anymore.
        return value
    }
    var interfaceLanguage: String {
        let language = interface == "system" ? (systemLanguages.first ?? "en") : interface
        if language.lowercased().hasPrefix("zh") {
            return language.contains("Hant") || language.contains("TW") || language.contains("HK") ? "zh-Hant" : "zh-Hans"
        }
        return "en"
    }
    var regionCode: String {
        region == "system" ? (Locale(identifier: systemLocale).region?.identifier ?? "US") : region
    }
    static func serviceLanguage(_ identifier: String, region: String) -> String {
        let locale = Locale(identifier: identifier)
        let code = locale.language.languageCode?.identifier ?? "en"
        if code == "zh" {
            let explicitRegion = locale.region?.identifier
            if let explicitRegion { return "zh-\(explicitRegion)" }
            if locale.language.script?.identifier == "Hant" { return ["TW", "HK", "MO"].contains(region) ? "zh-\(region)" : "zh-TW" }
            return ["CN", "SG"].contains(region) ? "zh-\(region)" : "zh-CN"
        }
        return locale.region.map { "\(code)-\($0.identifier)" } ?? "\(code)-\(region)"
    }
    var contentLanguage: String {
        let language = content == "auto" ? (interface == "system" ? systemLanguages.first ?? "en" : interfaceLanguage) : content
        return Self.serviceLanguage(language, region: regionCode)
    }
    var contentID: String { "\(contentLanguage)|\(regionCode)" }
    var displayLocale: Locale { Locale(identifier: "\(interfaceLanguage)_\(regionCode)") }
    var timeZone: TimeZone { TimeZone(identifier: zone == "system" ? systemZone : zone) ?? .autoupdatingCurrent }
    var subtitleLanguage: String {
        let value = subtitles == "auto" ? (interface == "system" ? systemLanguages.first ?? "en" : interfaceLanguage) : subtitles
        return Self.serviceLanguage(value, region: regionCode)
    }
    var subtitleSearchLanguage: String {
        if subtitleLanguage.hasPrefix("zh-") {
            return subtitleLanguage.hasSuffix("TW") || subtitleLanguage.hasSuffix("HK") || subtitleLanguage.hasSuffix("MO") ? "zh-tw" : "zh-cn"
        }
        return Locale(identifier: subtitleLanguage).language.languageCode?.identifier ?? "en"
    }
    static func trackLanguages(_ identifier: String) -> [String] {
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? "en"
        let aliases: [String: [String]] = ["zh": ["chi", "zho"], "en": ["eng"], "ja": ["jpn"], "ko": ["kor"],
            "fr": ["fra", "fre"], "de": ["deu", "ger"], "es": ["spa"], "pt": ["por"], "ru": ["rus"], "it": ["ita"]]
        return [identifier, code] + (aliases[code] ?? [])
    }
    var subtitleTrackLanguages: [String] { Self.trackLanguages(subtitleLanguage) }
    var audioTrackLanguages: [String] {
        audio == "original" ? [] : Self.trackLanguages(audio == "auto" ? contentLanguage : audio)
    }

    func formatted(_ date: Date, includeTime: Bool = true) -> String {
        let key = "\(date.timeIntervalSinceReferenceDate)|\(includeTime)|\(interfaceLanguage)|\(regionCode)|\(dateOrder)|\(clock)|\(timeZone.identifier)|\(systemLocale)" as NSString
        if let value = LocalizedDateCache.shared.values.object(forKey: key) { return value as String }
        let value = uncachedFormatted(date, includeTime: includeTime)
        LocalizedDateCache.shared.values.setObject(value as NSString, forKey: key)
        return value
    }
    private func uncachedFormatted(_ date: Date, includeTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.timeZone = timeZone
        if dateOrder == "system" {
            formatter.dateStyle = .medium
            if includeTime { formatter.timeStyle = .short }
        } else {
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = ["ymd": "yyyy/MM/dd", "dmy": "dd/MM/yyyy", "mdy": "MM/dd/yyyy"][dateOrder] ?? "yyyy/MM/dd"
        }
        if includeTime, clock != "system" || dateOrder != "system" {
            let datePart: String
            if dateOrder == "system" {
                formatter.timeStyle = .none
                datePart = formatter.string(from: date)
            } else { datePart = formatter.string(from: date) }
            let template = clock == "12" ? "h:mm a" : clock == "24" ? "HH:mm" : DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: displayLocale) ?? "HH:mm"
            formatter.dateFormat = template
            return datePart + " " + formatter.string(from: date)
        }
        return formatter.string(from: date)
    }
    /// A release date is a calendar day, never a UTC instant converted to local time.
    func releaseDate(_ raw: String) -> String? {
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == parts[0], verified.month == parts[1], verified.day == parts[2] else { return nil }
        return formatted(date, includeTime: false)
    }
}

extension Date {
    func lucentFormatted(includeTime: Bool = true) -> String { LocalizationPreferences.current.formatted(self, includeTime: includeTime) }
}

extension String {
    /// Use only for app-owned labels/status, never server metadata or filenames.
    var lucentLocalized: String {
        let language = LocalizationPreferences.current.interfaceLanguage
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return self }
        return bundle.localizedString(forKey: self, value: self, table: nil)
    }
}

extension ViewerProfile {
    /// The stock profile persists its creation-time name; render it localized
    /// while custom names stay verbatim.
    var displayName: String { name == "默认" ? "默认".lucentLocalized : name }
}

private final class LocalizedDateCache: @unchecked Sendable {
    static let shared = LocalizedDateCache()
    let values: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 512
        return cache
    }()
}

extension String {
    static func lucentFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: key.lucentLocalized, locale: LocalizationPreferences.current.displayLocale, arguments: arguments)
    }
}

/// Presentation only: track ids and selection order are never changed.
/// Like IINA, use the container language and Foundation's localized language names.
/// Filename inference is a fallback for poorly tagged subtitle tracks.
enum SubtitleLanguageDisplay {
    private nonisolated(unsafe) static let cache = NSCache<NSString, NSString>()
    private static let aliases: [String: String] = {
        var result: [String: String] = [:]
        let english = Locale(identifier: "en")
        for code in Locale.LanguageCode.isoLanguageCodes {
            let identifier = code.identifier
            result[identifier.lowercased()] = identifier
            if let name = english.localizedString(forLanguageCode: identifier) {
                result[name.lowercased()] = identifier
            }
        }
        // Bibliographic aliases and common subtitle filename conventions.
        for (code, values) in [
            ("zh", ["chi", "zho", "chinese", "zhongwen"]),
            ("en", ["eng", "english"]), ("ja", ["jpn", "japanese"]),
            ("ko", ["kor", "korean"]), ("fr", ["fre", "fra", "french"]),
            ("de", ["ger", "deu", "german"]), ("es", ["spa", "spanish"]),
            ("pt", ["por", "portuguese"]), ("ru", ["rus", "russian"]),
            ("zh-Hans", ["chs", "sc", "zh-cn", "zh-hans"]),
            ("zh-Hant", ["cht", "tc", "zh-tw", "zh-hk", "zh-hant"])
        ] { for value in values { result[value] = code } }
        return result
    }()

    static func languages(in name: String, declared: String? = nil) -> [String] {
        let text = name.lowercased().replacingOccurrences(of: "_", with: "-")
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
        var inferred: [String] = []
        let simplified = ["简中", "简体", "簡中", "簡體", "简英", "簡英", "简日", "簡日", "简繁", "簡繁", "simplified"]
        let traditional = ["繁中", "繁体", "繁體", "繁英", "繁日", "简繁", "簡繁", "traditional"]
        if simplified.contains(where: text.contains) { inferred.append("zh-Hans") }
        if traditional.contains(where: text.contains) { inferred.append("zh-Hant") }
        if ["中英", "简英", "簡英", "繁英"].contains(where: text.contains) { inferred.append("en") }
        if ["中日", "简日", "簡日", "繁日"].contains(where: text.contains) { inferred.append("ja") }
        if inferred.isEmpty && ["中文", "国语", "國語", "普通话", "普通話"].contains(where: text.contains) { inferred.append("zh") }
        let formatTokens: Set<String> = ["ass", "ssa", "srt", "sub", "sup", "smi", "vtt", "ttml", "pgs", "sdh", "cc"]
        for token in tokens where !formatTokens.contains(token) {
            if let code = aliases[token] { inferred.append(code) }
        }
        var resolved: [String] = []
        if let declared = declared?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !["", "und", "unk", "unknown", "mul", "zxx"].contains(declared) {
            let tag = declared.replacingOccurrences(of: "_", with: "-")
            let primary = String(tag.split(separator: "-").first ?? "")
            if let canonical = aliases[tag] ?? aliases[primary] {
                // A generic Chinese tag can be refined by an explicit script in its title.
                if canonical == "zh", inferred.contains(where: { $0.hasPrefix("zh-") }) {
                    resolved = inferred.filter { $0.hasPrefix("zh-") }
                } else { resolved = [tag.contains("-") ? (aliases[tag] ?? tag) : canonical] }
            }
        }
        if resolved.isEmpty { resolved = inferred }
        // Explicit bilingual titles retain both languages even when the container has one tag.
        if ["中英", "简英", "簡英", "繁英", "中日", "简日", "簡日", "繁日"].contains(where: text.contains) {
            resolved += inferred
        }
        var seen = Set<String>()
        let hasScript = resolved.contains { $0.hasPrefix("zh-") }
        return resolved.filter { !(hasScript && $0 == "zh") && seen.insert($0).inserted }
    }

    static func title(_ original: String, language: String? = nil,
                      locale: Locale = LocalizationPreferences.current.displayLocale) -> String {
        let key = "\(locale.identifier)|\(language ?? "")|\(original)" as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let codes = languages(in: original, declared: language)
        let names = codes.compactMap { locale.localizedString(forIdentifier: $0) }
        guard !names.isEmpty else { return original }
        let label = names.joined(separator: " / ")
        // Formatting can be called again by a view after the engine already localized it.
        let result: String
        if original.hasPrefix(label) { result = original }
        else if aliases[original.lowercased()] != nil { result = label }
        else { result = label + " · " + original }
        cache.countLimit = 256
        cache.setObject(result as NSString, forKey: key)
        return result
    }
}
