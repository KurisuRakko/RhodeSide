import AppKit
import IOKit.pwr_mgt

/// 给 `Attention` 的两个平台读数。Windows / Linux 壳只需要照着重写这一个文件（见根目录 README 的移植清单）：
/// 拿不到就返回 nil，`Attention` 只关掉对应的功能。
enum UserActivity {
    /// 键鼠多少秒没动了（不需要辅助功能权限）
    static func idleSeconds() -> Double? {
        guard let any = CGEventType(rawValue: ~0) else { return nil }
        let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        return s.isFinite && s >= 0 ? s : nil
    }

    /// 鼠标全局坐标（AppKit 全局坐标，和 `Brain.foot` 同一套）
    static func mouse() -> CGPoint? { NSEvent.mouseLocation }

    /// 有程序不让显示器自动熄灭（放视频、开视频会议时播放器 / 浏览器会这么做）：人多半在看，不算走开了。
    /// 读的是系统电源断言 PreventUserIdleDisplaySleep（`pmset -g assertions` 里那一行），要走一次进程间调用，缓存 2 秒
    static func screenKeptAwake() -> Bool? {
        let now = CACurrentMediaTime()
        if let c = cached, now - c.at < 2 { return c.value }
        var status: Unmanaged<CFDictionary>?
        var value: Bool?
        if IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess, let d = status?.takeRetainedValue() as? [String: Any] {
            value = ((d[kIOPMAssertionTypePreventUserIdleDisplaySleep] as? NSNumber)?.intValue ?? 0) > 0
        }
        cached = (now, value)
        return value
    }

    private static var cached: (at: CFTimeInterval, value: Bool?)?
}
