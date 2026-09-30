import AppKit
import PetCore
import ServiceManagement
import WebKit

/// 设置页的 WKWebView：拖进来的文件夹由原生层接住（网页拿不到路径），当作导入
final class DropWebView: WKWebView {
    var onDropURLs: (([URL]) -> Void)?

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return super.draggingEntered(sender) }
        send(["type": "dropHover", "on": true])
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        send(["type": "dropHover", "on": false])
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        send(["type": "dropHover", "on": false])
        onDropURLs?(urls)
        return true
    }
}

/// 网页窗口：主窗口（settings.html：侧栏分桌宠 / 模型库 / 设置三页）和首次启动的引导（welcome.html），
/// 都是 React + Rakko Design，随前端热更新；共用一套桥：同样的状态推送、同样的消息。
final class SettingsController: NSObject, NSWindowDelegate {
    enum Page: String {
        case settings, welcome

        var file: String { "\(rawValue).html" }
        var title: String {
            switch self {
            case .settings: "Rhodeside"
            case .welcome: "欢迎使用 Rhodeside"
            }
        }
        var size: NSSize {
            switch self {
            case .settings: NSSize(width: 900, height: 660)
            case .welcome: NSSize(width: 760, height: 540)
            }
        }
        var minSize: NSSize {
            switch self {
            case .settings: NSSize(width: 680, height: 480)
            case .welcome: NSSize(width: 600, height: 440)
            }
        }
    }

    let page: Page
    /// 资源监控里的名字
    var monitorName: String { "网页 \(page == .settings ? "主窗口" : "引导页")" }
    let window: NSWindow
    let webView: DropWebView
    private unowned let manager: PetManager

    /// 主窗口第一次打开时停在哪一页（pets / models / settings）
    private var tab: String?

    init(manager: PetManager, page: Page, tab: String? = nil) {
        self.manager = manager
        self.page = page
        self.tab = tab
        let proxy = WeakScriptHandler()
        let frame = NSRect(origin: .zero, size: page.size)
        webView = DropWebView(frame: frame, configuration: WebBridge.configuration(handler: proxy, scheme: manager.scheme))
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        proxy.target = self
        window.title = page.title
        window.isReleasedWhenClosed = false
        window.minSize = page.minSize
        window.contentView = webView
        window.delegate = self
        window.center()
        if page == .settings { window.setFrameAutosaveName("RhodesideMain") }
        webView.isInspectable = true
        webView.navigationDelegate = self
        if page == .settings { webView.onDropURLs = { [weak self] urls in self?.importURLs(urls) } }
        loadPage()
    }

    func show() {
        // 菜单栏程序不激活的话，输入框收不到键盘
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func loadPage() {
        webView.load(URLRequest(url: SchemeHandler.url(page.file + (tab.map { "#\($0)" } ?? ""))))
    }

    /// 已经开着的主窗口切到某一页
    func navigate(_ tab: String) {
        self.tab = tab
        webView.send(["type": "navigate", "tab": tab])
    }

    func pushState() {
        webView.send(manager.settingsState())
    }

    func toast(_ text: String) {
        webView.send(["type": "toast", "text": text])
    }

    func windowWillClose(_ notification: Notification) {
        window.delegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        manager.pageClosed(self)
    }

    /* ---------------------------------------------------------------- 导入 */

    private func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "选择模型文件夹（每个文件夹为一个模型）"
        panel.prompt = "导入"
        panel.beginSheetModal(for: window) { [weak self] resp in
            if resp == .OK { self?.importURLs(panel.urls) }
        }
    }

    private func importURLs(_ urls: [URL]) {
        let (jobs, errors) = manager.importer.stage(urls)
        for e in errors { toast("导入失败：\(e)") }
        for j in jobs {
            webView.send(["type": "importStaged", "token": j.token, "name": j.name, "base": "./import/\(j.token)/", "files": j.files])
        }
    }

    private func finishImport(_ b: Body) {
        guard let token = b.string("token") else { return }
        if b.bool("ok") == true {
            do {
                let name = try manager.importer.commit(token)
                toast("已导入「\(name)」")
                pushState()
            } catch {
                toast("导入失败：\(error.localizedDescription)")
            }
        } else {
            manager.importer.abort(token)
            toast("导入失败：\(b.string("reason") ?? "未通过检查")")
        }
    }
}

extension SettingsController: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let b = Body(message.body) else { return }
        switch b.type {
        case "ready":
            pushState()
        case "updatePet":
            if let id = b.string("id"), let patch = b.raw["patch"] as? [String: Any] { manager.updatePet(id, patch: patch) }
        case "addPet":
            if !manager.addPet(model: b.string("model")) { toast("最多 \(AppConfig.maxPets) 个桌宠") }
        case "removePet":
            if let id = b.string("id") { manager.removePet(id) }
        case "summonPet":
            manager.summon(b.string("id"))
        case "updateGlobal":
            if let patch = b.raw["patch"] as? [String: Any] { manager.updateGlobal(patch: patch) }
        case "setHidden":
            manager.setUserHidden(b.bool("hidden") ?? false)
        case "setLoginItem":
            if let err = LoginItem.set(b.bool("enabled") ?? false) { toast(err) }
            pushState()
        case "openLoginItemSettings":
            SMAppService.openSystemSettingsLoginItems()
        case "importPick":
            pickFolders()
        case "importResult":
            finishImport(b)
        case "deleteModel":
            guard let name = b.string("name") else { break }
            do {
                ModelStore.modelDeleted(name)
                try ModelLibrary.delete(name)
                toast("已将「\(name)」移到废纸篓")
                // 用它的桌宠换成还在的第一个模型；一个都没有就不动配置（桌宠收起来，提示去模型库下载）
                var cfg = manager.config
                if let other = ModelLibrary.all().first(where: { $0.name != name }) {
                    for i in cfg.pets.indices where cfg.pets[i].model == name {
                        cfg.pets[i].model = other.name
                        cfg.pets[i].outfit = nil
                        cfg.pets[i].group = nil
                        cfg.pets[i].pose = nil
                    }
                }
                manager.apply(cfg, reason: "删除模型「\(name)」")
            } catch {
                toast("删除失败：\(error.localizedDescription)")
            }
        case "reveal":
            switch b.string("what") {
            case "models": NSWorkspace.shared.open(Paths.userModels)
            case "logs": NSWorkspace.shared.open(Paths.logs)
            case "config": NSWorkspace.shared.activateFileViewerSelecting([Paths.config])
            default: break
            }
        case "snapshot":
            manager.snapshotAll()
            toast("诊断快照已保存到日志文件夹")
        case "checkUpdates":
            manager.updater.check(force: true)
        case "uploadLogs":
            guard !manager.logUploader.busy else { break }
            manager.logUploader.run("manual") { [weak self] error in
                self?.toast(error.map { "日志上传失败：\($0)" } ?? "日志已上传")
            }
        case "perform":
            guard let raw = b.string("behavior"), let behavior = Behavior(rawValue: raw) else { break }
            for pet in manager.pets where b.string("id") == nil || pet.config.id == b.string("id") { pet.perform(behavior) }
        case "saveTeam":
            if !manager.saveTeam(name: b.string("name")) { toast("桌面上还没有桌宠") }
        case "overwriteTeam":
            if let id = b.string("id") { manager.overwriteTeam(id) }
        case "summonTeam":
            if let id = b.string("id") { manager.summonTeam(id) }
        case "renameTeam":
            if let id = b.string("id") { manager.renameTeam(id, name: b.string("name")) }
        case "deleteTeam":
            if let id = b.string("id") { manager.deleteTeam(id) }
        case "turn":
            for pet in manager.pets where pet.config.id == b.string("id") { pet.turn() }
        case "playCombo":
            guard let combo = b.string("combo") else { break }
            for pet in manager.pets where pet.config.id == b.string("id") { pet.playCombo(combo) }
        case "openPage":
            manager.openSettings(tab: b.string("page"))
        case "downloadModels":
            manager.updater.requestModels(b.strings("ids"))
        case "previewModel":
            guard let id = b.string("id") else { break }
            Task { @MainActor [weak self] in
                guard let manager = self?.manager else { return }
                do {
                    let files = try await manager.updater.preview(id)
                    self?.webView.send(["type": "preview", "id": id, "base": "./previews/", "files": files])
                } catch {
                    self?.webView.send(["type": "preview", "id": id, "error": error.localizedDescription])
                }
            }
        case "finishOnboarding":
            manager.finishOnboarding(download: b.strings("ids"))
        case "authLogin":
            manager.auth.login()
        case "authLogout":
            manager.auth.logout()
        case "reloadWeb":
            manager.reloadWeb(reason: "设置页点了重新载入")
        case "log":
            Log.info("[设置页] \(b.string("text") ?? "")")
        case "error":
            Log.error("[设置页] \(b.string("text") ?? "")")
        default:
            break
        }
    }
}

extension SettingsController: WKNavigationDelegate {
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        webContentTerminated(WebTermination.describe(reason))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webContentTerminated(nil)
    }

    private func webContentTerminated(_ reason: String?) {
        let mb = manager.monitor?.lastMB(monitorName).map { "，最近一次采样 \(Int($0)) MB" } ?? ""
        Log.error("\(page.file) 网页进程退出了：\(reason ?? "原因未知")\(mb)，重新载入")
        loadPage()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.error("\(page.file) 打不开：\(error.logDescription)")
    }
}
