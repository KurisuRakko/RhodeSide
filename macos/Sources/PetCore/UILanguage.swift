import Foundation

/// 界面语言：简体中文 / 繁體中文（香港用词）/ English。和前端 web/src/i18n/index.ts 的规则一致。
public enum UILanguage: String, CaseIterable, Sendable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en

    /// 配置里「跟随系统」的写法
    public static let system = "system"

    /// 配置值 + 系统首选语言（`Locale.preferredLanguages`）→ 界面语言。
    /// 配置不认识（手改坏了、以后的新语言）当跟随系统。
    public static func resolve(_ pref: String, preferred: [String]) -> UILanguage {
        if let l = UILanguage(rawValue: pref) { return l }
        return fromSystem(preferred)
    }

    /// 只看第一首选：写明 Hans / Hant 的按文字（zh-Hans-HK 是简体），没写的按地区（台港澳繁体）；
    /// 粤语按繁体；其他一律英文；没有首选当简体
    public static func fromSystem(_ preferred: [String]) -> UILanguage {
        guard let p = preferred.first?.lowercased().replacingOccurrences(of: "_", with: "-") else { return .zhHans }
        let parts = p.split(separator: "-").map(String.init)
        if parts.first == "yue" { return .zhHant }
        guard parts.first == "zh" else { return .en }
        if parts.contains("hans") { return .zhHans }
        if parts.contains("hant") { return .zhHant }
        return parts.contains { ["tw", "hk", "mo"].contains($0) } ? .zhHant : .zhHans
    }
}
