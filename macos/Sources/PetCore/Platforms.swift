import CoreGraphics

public enum PlatformKind: Hashable, Sendable {
    case ground(screen: UInt32)
    case window(id: UInt32)
    /// 另一只桌宠的头顶（叠叠乐，见 `Stacking`）
    case pet(id: String)

    public var isPet: Bool {
        if case .pet = self { return true }
        return false
    }
}

/// 能站的地方：每块屏幕的地面，加上每个窗口顶边没被挡住的线段（还有别的小人的头顶，由原生层按 `Stacking` 加进世界）。
public struct Platform: Equatable, Sendable {
    public var kind: PlatformKind
    public var segment: Segment
    /// 小人跟着平台走时的参照点：窗口的左边缘（地面恒为 0）。站在窗口上的小人记的是「脚 − anchorX」。
    public var anchorX: Double
    /// 窗口顶边被前面的窗口挡住的那段：只有本来就站在这个窗口上的小人能站、能走（小人和窗口同层，被盖在下面），
    /// 别的小人落不上来、也不会从别处走进来
    public var covered: Bool

    public init(kind: PlatformKind, segment: Segment, anchorX: Double, covered: Bool = false) {
        self.kind = kind
        self.segment = segment
        self.anchorX = anchorX
        self.covered = covered
    }
}

public enum Platforms {
    /// 比这短的线段不要（站不下一只小人）
    public static let minWidth = 40.0
    /// 顶边离屏幕可用区域的上沿不到这么多就不要（小人会钻进菜单栏后面）
    public static let headroom = 40.0

    /// `windows` 必须是从前到后的顺序（CGWindowListCopyWindowInfo 给的就是），并且已经过滤过
    /// （只要第 0 层、别人的、够大的、不在忽略名单里的）。
    public static func compute(screens: [ScreenInfo], windows: [WindowInfo], walkOnWindows: Bool) -> [Platform] {
        var out = screens.map {
            Platform(kind: .ground(screen: $0.id), segment: .ground(visibleFrame: $0.visibleFrame), anchorX: 0)
        }
        guard walkOnWindows else { return out }
        for (i, w) in windows.enumerated() {
            let y = Double(w.frame.maxY)
            // 1. 顶边落在哪些屏幕的可站区域里（跨两块屏幕的窗口会分成两段）
            var pieces: [(Double, Double)] = []
            for s in screens {
                let vf = s.visibleFrame
                guard y > Double(vf.minY) + 1, y <= Double(vf.maxY) - headroom else { continue }
                let lo = max(Double(w.frame.minX), Double(vf.minX))
                let hi = min(Double(w.frame.maxX), Double(vf.maxX))
                if hi - lo >= minWidth { pieces.append((lo, hi)) }
            }
            // 2. 减掉前面那些「竖直方向真把这条顶边盖住」的窗口；前面的窗口整个在顶边下面就不算挡
            var open = pieces
            for f in windows[..<i] where Double(f.frame.minY) <= y && Double(f.frame.maxY) > y + 2 {
                open = subtract(open, Double(f.frame.minX), Double(f.frame.maxX))
                if open.isEmpty { break }
            }
            // 3. 挡住的那几段也留着，标成 covered（太窄的露出来的段并进挡住的里，免得脚下出现站不住的缝）
            let visible = open.filter { $0.1 - $0.0 >= minWidth }
            var hidden = pieces
            for (lo, hi) in visible { hidden = subtract(hidden, lo, hi) }
            let anchor = Double(w.frame.minX)
            for (lo, hi) in visible {
                out.append(Platform(kind: .window(id: w.id), segment: Segment(y: y, minX: lo, maxX: hi), anchorX: anchor))
            }
            for (lo, hi) in hidden where hi - lo > 0.5 {
                out.append(Platform(kind: .window(id: w.id), segment: Segment(y: y, minX: lo, maxX: hi), anchorX: anchor, covered: true))
            }
        }
        return out
    }

    /// 区间集合减去 [lo, hi]
    static func subtract(_ ranges: [(Double, Double)], _ lo: Double, _ hi: Double) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for (a, b) in ranges {
            if hi <= a || lo >= b {
                out.append((a, b))
                continue
            }
            if lo > a { out.append((a, lo)) }
            if hi < b { out.append((hi, b)) }
        }
        return out
    }

    /// 被别的程序的窗口整个铺满的屏幕（原生全屏，或 IINA/游戏这类非原生全屏）。
    public static func fullscreenScreens(screens: [ScreenInfo], windows: [WindowInfo]) -> Set<UInt32> {
        var out = Set<UInt32>()
        for s in screens {
            let f = s.frame
            let covered = windows.contains { w in
                abs(w.frame.minX - f.minX) <= 1 && abs(w.frame.minY - f.minY) <= 1
                    && abs(w.frame.maxX - f.maxX) <= 1 && abs(w.frame.maxY - f.maxY) <= 1
            }
            if covered { out.insert(s.id) }
        }
        return out
    }
}
