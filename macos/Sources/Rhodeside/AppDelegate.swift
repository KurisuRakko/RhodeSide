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
        LogUploader.markRunning()
        Log.info("启动 Rhodeside \(Paths.version)，pid \(getpid())，\(ProcessInfo.processInfo.operatingSystemVersionString)，程序在 \(Bundle.main.bundlePath)")
        setupMainMenu()
        setupStatusItem()
        setupSignals()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "桌宠动画")
        LoginItem.refreshIfEnabled()
        let m = PetManager()
        manager = m
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
        manager?.shutdown()
        Log.info("退出")
        Log.flush()
        LogUploader.markStopped()
    }

    /* ---------------------------------------------------------------- 菜单 */

    /// 菜单栏程序也要有主菜单，否则设置窗口里 ⌘C / ⌘V / ⌘W 不好使
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Rhodeside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = win
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Rhodeside")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Rhodeside 桌宠"

        // 菜单只留常用的：其余都在主窗口里（侧栏：桌宠 / 模型库 / 设置；故障排查在设置页）
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(action("打开 Rhodeside…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        let hide = action("隐藏桌宠", #selector(toggleHidden))
        hideItem = hide
        menu.addItem(hide)
        menu.addItem(action("召回全部", #selector(summonAll)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Rhodeside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        hideItem?.title = manager?.userHidden == true ? "显示桌宠" : "隐藏桌宠"
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
                Log.info("收到信号 \(sig)，退出")
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
