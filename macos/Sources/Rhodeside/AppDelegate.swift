import AppKit
import PetCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private(set) var manager: PetManager?
    private var pendingURLs: [URL] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var hideItem: NSMenuItem?
    /// 持续播动画的界面：不让系统 App Nap 节流定时器和 displayLink（否则会周期性卡几百毫秒）
    private var activity: NSObjectProtocol?
    private let launched = Date()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 单实例：已经有一个在跑就退出（LaunchServices 平时会把第二次打开转给已有的那个，这里防 open -n / 直接跑二进制）。
        // 在 Log.setup 之前查：setup 会轮转日志，不能动正在跑的那个的文件（这时 Log 还没打开文件，写到 stderr）
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleID).first(where: { $0.processIdentifier != me }) {
            Log.warn("已经有一个 Rhodeside 在跑（pid \(other.processIdentifier)），这个退出")
            Log.flush()
            exit(0)
        }
        Log.setup()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RunMarker.begin()
        Log.info("启动 Rhodeside \(Paths.version)，pid \(getpid())，\(ProcessInfo.processInfo.operatingSystemVersionString)，\(Machine.summary)，程序在 \(Bundle.main.bundlePath)")
        if RunMarker.previousRunCrashed {
            Log.warn(RunMarker.previous?.uncleanExitSummary(now: Date()) ?? "上次没有正常退出（崩溃、被强制结束、断电或内存不够被系统杀掉）")
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            Log.info("系统要关机 / 重启 / 注销")
        }
        setupSignals()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "桌宠动画")
        LoginItem.refreshIfEnabled()
        // 先读配置（界面语言在里面），再建菜单
        let m = PetManager()
        manager = m
        setupMainMenu()
        setupStatusItem()
        m.onLanguageChange = { [weak self] in
            self?.setupMainMenu()
            self?.buildStatusMenu()
        }
        m.start()
        if !m.config.onboarded { m.openWelcome() }
        // 自更新的交接脚本在等这个信号：活过 8 秒算启动成功
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { AppInstaller.markHealthy() }
        for url in pendingURLs { Debug.handle(url, manager: m) }
        pendingURLs = []
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let m = manager else {
            pendingURLs += urls
            return
        }
        for url in urls { Debug.handle(url, manager: m) }
    }

    /// 在访达里再双击一次 App：打开设置
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        manager?.openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrashTrap.terminating = true
        manager?.shutdown()
        Log.info("退出（运行了 \(RunRecord.duration(Date().timeIntervalSince(launched)))）")
        Log.flush()
        RunMarker.end()
    }

    /* ---------------------------------------------------------------- 菜单 */

    /// 菜单栏程序也要有主菜单，否则设置窗口里 ⌘C / ⌘V / ⌘W 不好使。界面语言变了会重建
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("编辑", "編輯", "Edit"))
        edit.addItem(withTitle: tr("撤销", "還原", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: tr("重做", "重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("剪切", "剪下", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("拷贝", "拷貝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("粘贴", "貼上", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("全选", "全選", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let win = NSMenu(title: tr("窗口", "視窗", "Window"))
        win.addItem(withTitle: tr("关闭", "關閉", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = win
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Rhodeside")
        image?.isTemplate = true
        item.button?.image = image
        statusItem = item
        buildStatusMenu()
    }

    /// 状态栏菜单只留常用的：其余都在主窗口里（侧栏：桌宠 / 模型库 / 设置；故障排查在设置页）。界面语言变了会重建
    private func buildStatusMenu() {
        guard let item = statusItem else { return }
        item.button?.toolTip = tr("Rhodeside 桌宠", "Rhodeside 桌寵", "Rhodeside desktop pets")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(action(tr("打开 Rhodeside…", "開啟 Rhodeside…", "Open Rhodeside…"), #selector(openSettings), key: ","))
        menu.addItem(.separator())
        let hide = action(hideTitle, #selector(toggleHidden))
        hideItem = hide
        menu.addItem(hide)
        menu.addItem(action(tr("召回全部", "召回全部", "Recall All"), #selector(summonAll)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
    }

    private var quitTitle: String { tr("退出 Rhodeside", "結束 Rhodeside", "Quit Rhodeside") }
    private var hideTitle: String {
        manager?.userHidden == true ? tr("显示桌宠", "顯示桌寵", "Show Pets") : tr("隐藏桌宠", "隱藏桌寵", "Hide Pets")
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        hideItem?.title = hideTitle
    }

    @objc private func openSettings() { manager?.openSettings() }
    @objc private func summonAll() { manager?.summon(nil) }
    @objc private func toggleHidden() { manager.map { $0.setUserHidden(!$0.userHidden) } }

    /* ---------------------------------------------------------------- 信号 */

    /// deploy.sh 用 SIGTERM 让旧进程退：走正常退出流程（存位置）
    private func setupSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Log.info("收到 \(Signals.describe(sig))，退出")
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
