import AppKit

/// `rhodeside://…` 链接（ssh 上用 `open 'rhodeside://debug/snapshot'` 调）
enum Debug {
    static func handle(_ url: URL, manager: PetManager) {
        guard url.scheme == "rhodeside" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func arg(_ k: String) -> String? { items.first { $0.name == k }?.value }
        if url.host == "auth", url.path == "/callback" {
            Log.info("收到登录回调")
            manager.auth.handleCallback(url)
            return
        }
        Log.info("收到链接：\(url.absoluteString)")
        switch (url.host ?? "", url.path) {
        case ("settings", _): manager.openSettings(tab: "settings")
        case ("control", _), ("pets", _): manager.openSettings(tab: "pets")
        case ("library", _), ("models", _): manager.openSettings(tab: "models")
        case ("welcome", _): manager.openWelcome()
        case ("debug", "/snapshot"): manager.snapshotAll()
        case ("debug", "/state"): manager.writeState()
        case ("debug", "/reload"): manager.reloadWeb(reason: "rhodeside://debug/reload")
        case ("debug", "/summon"): manager.summon(nil)
        case ("debug", "/hide"): manager.setUserHidden(arg("on") != "0")
        // 跑任意 JS 的链接任何网页都能触发：默认关，要用先 `defaults write com.rakko.rhodeside debugEval -bool YES`
        case ("debug", "/eval") where UserDefaults.standard.bool(forKey: "debugEval"):
            for pet in manager.pets { pet.debugEval(arg("js") ?? "document.readyState") }
        case ("debug", "/eval-page") where UserDefaults.standard.bool(forKey: "debugEval"):
            manager.debugEvalPage(arg("page") ?? "settings", js: arg("js") ?? "document.readyState")
        case ("debug", "/login-item"): Log.info(LoginItem.debug(arg("do") ?? "status"))
        default: Log.warn("不认识的链接：\(url.absoluteString)")
        }
    }
}
