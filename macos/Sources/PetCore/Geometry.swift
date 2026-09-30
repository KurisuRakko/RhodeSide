import CoreGraphics

/// 坐标约定：一律用 AppKit 全局坐标——主屏（`NSScreen.screens[0]`）左下角是原点，y 向上，单位 pt。
public enum Coords {
    /// CoreGraphics 的窗口矩形（`kCGWindowBounds`：主屏左上角为原点，y 向下）→ AppKit 全局坐标。
    /// `primaryHeight` 是主屏的高度。
    public static func appKitRect(fromCG cg: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cg.minX, y: primaryHeight - cg.minY - cg.height, width: cg.width, height: cg.height)
    }
}

/// 桌宠窗口的布局，由网页（pet.html）按模型测出来，单位 pt。
/// 小人的脚底锚点固定在窗口里的 (footX, footY)；移动窗口 = 移动小人。
public struct PetLayout: Codable, Equatable, Sendable {
    public var w: Double
    public var h: Double
    public var footX: Double
    public var footY: Double

    public init(w: Double, h: Double, footX: Double, footY: Double) {
        self.w = w
        self.h = h
        self.footX = footX
        self.footY = footY
    }

    /// 脚底落在 `foot`（全局坐标）时窗口的 frame。
    public func windowFrame(foot: CGPoint) -> CGRect {
        CGRect(x: foot.x - footX, y: foot.y - footY, width: w, height: h)
    }
}

/// 一条能站的水平线段（地面或窗口顶边没被挡住的部分）。
public struct Segment: Codable, Equatable, Sendable {
    public var y: Double
    public var minX: Double
    public var maxX: Double

    public init(y: Double, minX: Double, maxX: Double) {
        self.y = y
        self.minX = minX
        self.maxX = maxX
    }

    /// 屏幕的地面：程序坞上沿（`visibleFrame.minY`），横跨 visibleFrame 的宽度。
    public static func ground(visibleFrame vf: CGRect) -> Segment {
        Segment(y: vf.minY, minX: vf.minX, maxX: vf.maxX)
    }

    public func contains(x: Double, tolerance: Double = 0.5) -> Bool {
        x >= minX - tolerance && x <= maxX + tolerance
    }

    /// 把脚的横坐标夹在线段内，身体（半宽 `half`）不出线段；线段比身体还窄就站中间。
    public func clamp(x: Double, half: Double) -> Double {
        let lo = minX + half
        let hi = maxX - half
        return lo > hi ? (minX + maxX) / 2 : min(max(x, lo), hi)
    }
}

/// 一块屏幕（`id` 是 CGDirectDisplayID，插拔、改分辨率都不变）。
public struct ScreenInfo: Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// 一个别的程序的普通窗口（第 0 层，已经换成 AppKit 坐标）。
public struct WindowInfo: Equatable, Sendable {
    public var id: UInt32
    public var pid: Int32
    public var owner: String
    public var frame: CGRect

    public init(id: UInt32, pid: Int32, owner: String, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.owner = owner
        self.frame = frame
    }
}
