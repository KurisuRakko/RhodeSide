import Foundation
import PetCore

/// 壳这边的界面语言（菜单、窗口标题、toast、报错）。网页那边自己按 config.language 翻（web/src/i18n/）。
/// PetManager 载入配置和改语言时 set；系统面板（打开文件、右键菜单）跟系统语言，不归这里管。
enum L10n {
    static var current: UILanguage = UILanguage.fromSystem(Locale.preferredLanguages)

    static func set(_ pref: String) {
        current = UILanguage.resolve(pref, preferred: Locale.preferredLanguages)
    }
}

/// 三语文案就地写：`tr("显示桌宠", "顯示桌寵", "Show Pets")`。繁体按香港用词。
func tr(_ hans: String, _ hant: String, _ en: String) -> String {
    switch L10n.current {
    case .zhHans: hans
    case .zhHant: hant
    case .en: en
    }
}
