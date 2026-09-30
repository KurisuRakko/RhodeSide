import AppKit
import ObjectiveC
import WebKit

/// 桌宠用的透明浮动面板：不抢焦点、不在程序失去焦点时隐藏、没有阴影、所有桌面空间都在。
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

protocol MouseCatcherDelegate: AnyObject {
    func catcherMouseDown(_ e: NSEvent)
    func catcherMouseDragged(_ e: NSEvent)
    func catcherMouseUp(_ e: NSEvent)
    func catcherRightMouseDown(_ e: NSEvent)
}

/// 盖在 WKWebView 上面的一层透明视图，吃掉所有鼠标事件（网页不管鼠标，原生层管）。
/// 窗口整体是否穿透由 Pet 每帧按鼠标位置切 `ignoresMouseEvents`，只有鼠标在小人身上时这里才收得到事件。
final class MouseCatcher: NSView {
    weak var delegate: MouseCatcherDelegate?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with e: NSEvent) { delegate?.catcherMouseDown(e) }
    override func mouseDragged(with e: NSEvent) { delegate?.catcherMouseDragged(e) }
    override func mouseUp(with e: NSEvent) { delegate?.catcherMouseUp(e) }
    override func rightMouseDown(with e: NSEvent) { delegate?.catcherRightMouseDown(e) }
}

final class PetWindow {
    let panel: PetPanel
    let webView: WKWebView
    let catcher: MouseCatcher

    init(configuration: WKWebViewConfiguration) {
        let rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        // .nonactivatingPanel 必须在 init 里就给，事后改 styleMask 不一定生效
        panel = PetPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false // NSPanel 默认 true：不改的话别的程序一激活小人就没了
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // 系统阴影会按内容描一圈边，动画变了还会残留
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true

        let root = NSView(frame: rect)
        root.autoresizesSubviews = true
        webView = WKWebView(frame: root.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.isInspectable = true // Safari → 开发 菜单里能调试这一页
        Self.disableOcclusionThrottling(webView)
        catcher = MouseCatcher(frame: root.bounds)
        catcher.autoresizingMask = [.width, .height]
        root.addSubview(webView)
        root.addSubview(catcher)
        panel.contentView = root
    }

    /// 透明窗口在什么都没画时会被系统判成「被遮挡」，WebKit 随即把页面置为 hidden、停掉 rAF，
    /// 页面就永远画不出第一帧（死锁）。桌宠窗口本来就是透明的，关掉 WebKit 按窗口遮挡节流的逻辑。
    /// 私有接口（WKWebView _setWindowOcclusionDetectionEnabled:），不存在就跳过。
    static func disableOcclusionThrottling(_ webView: WKWebView) {
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: sel), let method = class_getInstanceMethod(type(of: webView), sel) else {
            Log.warn("WKWebView 没有 _setWindowOcclusionDetectionEnabled:，透明窗口可能被节流")
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(webView, sel, false)
    }

    /// 「全屏时隐藏」关掉时加上 .fullScreenAuxiliary，小人才能跟进别的程序的全屏空间
    func setFullscreenAuxiliary(_ on: Bool) {
        if on { panel.collectionBehavior.insert(.fullScreenAuxiliary) } else { panel.collectionBehavior.remove(.fullScreenAuxiliary) }
    }
}
