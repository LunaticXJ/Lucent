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
        value.region = defaults.string(forKey: "lucent.locale.region") ?? "system"
        value.dateOrder = defaults.string(forKey: "lucent.locale.dateOrder") ?? "system"
        value.clock = defaults.string(forKey: "lucent.locale.clock") ?? "system"
        value.zone = defaults.string(forKey: "lucent.locale.zone") ?? "system"
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
