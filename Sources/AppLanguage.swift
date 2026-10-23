import Foundation

enum AppLanguage {
    private static let lock = NSLock()
    private static var activeCodes = Set(["ja"])
    static var available: [(String,String)] {
        lock.lock();let codes=activeCodes;lock.unlock()
        return ResourceLanguageProbe.options.filter{codes.contains($0.0)}.map{($0.0,$0.1)}
    }
    static func configure(available languages:[String]) {
        let supported=Set(ResourceLanguageProbe.options.map{$0.0})
        let codes=Set(languages.map(normalize)).intersection(supported)
        lock.lock();activeCodes=codes.union(["ja"]);lock.unlock()
    }
    static func normalize(_ value: String) -> String {
        let l = value.lowercased()
        if l.contains("hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l == "tw" { return "zh-Hant" }
        if l.hasPrefix("zh") || l == "cn" { return "zh-Hans" }
        if l.hasPrefix("ja") || l == "jp" { return "ja" }
        if l.hasPrefix("ko") || l == "kr" { return "ko" }
        return "en"
    }
    static func supportedLanguage(_ language: String) -> String {
        let code = normalize(language)
        return available.contains { $0.0 == code } ? code : "ja"
    }
    static var current: String {
        supportedLanguage(UserDefaults.standard.string(forKey: "interfaceLanguage")
            ?? ProcessInfo.processInfo.environment["PJDV_LANGUAGE"] ?? Locale.preferredLanguages.first ?? "en")
    }
    static func select(_ language: String) { UserDefaults.standard.set(supportedLanguage(language), forKey: "interfaceLanguage") }
    // Use the same supported selection for host UI and the Horizon query.
    static func gameLanguageCode(_ language: String) -> String {
        supportedLanguage(language)
    }
    static func prepareSession() { setenv("PJDV_LANGUAGE", gameLanguageCode(current), 1) }
    static func text(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: current, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
func L(_ key: String) -> String { AppLanguage.text(key) }
func LF(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), locale: Locale(identifier: AppLanguage.current), arguments: args) }
