import CoreGraphics

/// 窗口撞到小人：拖动 / 缩放别的程序的窗口、压到小人身上时，小人弹到这个窗口的顶边上（设置里的 `hopOnWindows`）。
/// 只认「已有窗口挪了、从没压着变成压着」：新开的窗口、切桌面空间、小人自己走到窗口前面都不算。
public enum WindowHop {
    /// 窗口和身体至少重叠这么多（宽、高都要）才算撞上，只擦到边不算
    public static let minOverlap = 6.0

    /// 判定用的身体框：脚底中心 ± 0.6 × 半宽，脚上方几 pt 到头顶 `top`（叠着一摞时是最上面那只的头顶）
    public static func body(foot: CGPoint, halfWidth: Double, top: Double) -> CGRect {
        let half = halfWidth * 0.6
        let y0 = Double(foot.y) + 4
        return CGRect(x: Double(foot.x) - half, y: y0, width: 2 * half, height: max(top - y0, 1))
    }

    /// 这次扫描里撞到身体的窗口（从前到后取第一个）：上次扫描就有、frame 变了、现在压着而上次没压着。
    /// `exclude` 是脚下那个窗口：它的位置由 WindowTracker 高频跟，比扫描新，往下拖着走时脚会比扫描到的顶边低一截，不排除会误判成撞上
    public static func hit(body: CGRect, old: [UInt32: CGRect], new: [WindowInfo], exclude: UInt32? = nil) -> WindowInfo? {
        new.first { w in
            guard w.id != exclude, let then = old[w.id], then != w.frame else { return false }
            return overlaps(w.frame, body) && !overlaps(then, body)
        }
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && Double(i.width) >= minOverlap && Double(i.height) >= minOverlap
    }

    /// 跳到这个窗口顶边上哪：离 x 最近的那段可站的顶边，按半身宽夹进去；没有可站的（最大化、贴着菜单栏、顶边被挡住）就 nil，不跳
    public static func target(window id: UInt32, platforms: [Platform], x: Double, half: Double) -> CGPoint? {
        let dist = { (s: Segment) in max(s.minX - x, 0, x - s.maxX) }
        guard let p = platforms.filter({ $0.kind == .window(id: id) }).min(by: { dist($0.segment) < dist($1.segment) }) else { return nil }
        return CGPoint(x: p.segment.clamp(x: x, half: half), y: p.segment.y)
    }
}
