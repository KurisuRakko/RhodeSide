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

/// 网页在两次位置消息之间怎么外推小人的位置（`web/src/pet/motion.ts` 的 `extrapolate` 是同一个公式）：
/// 地上匀速；空中（g > 0）水平速度按 e^(-k·t) 衰减、竖直按重力走抛物线。
/// 外推有上限：原生层卡住时网页还在推，原生恢复后每帧最多只走 0.05 秒，推太远会冲过头再弹回来。
/// 地上 0.3 秒（略长于 250ms 的校正周期，平时用不满），空中 0.1 秒（空中本来每 ~60ms 就会补发一次）
public struct Motion: Equatable, Sendable {
    public var x: Double
    public var vx: Double
    public var y: Double
    public var vy: Double
    public var g: Double
    public var k: Double
    public static let maxAhead = 0.3
    public static let maxAheadInAir = 0.1

    public init(x: Double, vx: Double, y: Double, vy: Double = 0, g: Double = 0, k: Double = 0) {
        self.x = x
        self.vx = vx
        self.y = y
        self.vy = vy
        self.g = g
        self.k = k
    }

    public func at(_ rawT: Double) -> (x: Double, y: Double) {
        let t = min(max(rawT, 0), g > 0 ? Self.maxAheadInAir : Self.maxAhead)
        let dx = k > 0 ? vx * (1 - exp(-k * t)) / k : vx * t
        return (x + dx, y + vy * t - g * t * t / 2)
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
