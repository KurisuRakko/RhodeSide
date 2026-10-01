import CoreGraphics

/// 叠叠乐：每只小人的头顶也是一个能站的平台。被扔到别人头上的小人站在那里不自己走，
/// 下面那只走路 / 被拎走时它跟着平移（和站在移动的窗口上一样，靠 `anchorX` = 下面那只脚的横坐标）。
public enum Stacking {
    /// 头顶平台比身子窄一点：得大致扔在头上方才站得住
    public static let widthRatio = 0.7

    public struct Head: Equatable, Sendable {
        public var id: String
        public var foot: CGPoint
        public var height: Double
        public var halfWidth: Double
        /// 自己站在谁头上
        public var below: String?
        /// 载入完、没隐藏
        public var usable: Bool
        /// 自己站稳了（没被拎着、没在空中）
        public var standing: Bool

        public init(id: String, foot: CGPoint, height: Double, halfWidth: Double, below: String?, usable: Bool = true, standing: Bool = true) {
            self.id = id
            self.foot = foot
            self.height = height
            self.halfWidth = halfWidth
            self.below = below
            self.usable = usable
            self.standing = standing
        }
    }

    /// 给 `selfID` 那只小人看的头顶平台：不含自己的头，也不含叠在自己上面（沿「站在谁头上」往下能走到自己）的那些，免得成环。
    /// 给了 `screens`（非空）时，站稳了的那只头顶还得在某块屏幕的可站区域里（和窗口顶边一样留 `Platforms.headroom`）：
    /// 站在高处窗口上的那只头顶再叠一只，上面那只会整个伸到屏幕上沿外面，看不见也拖不回来；
    /// 叠上去时头顶已经出界的落不上去，叠好后下面那只被抬高、头顶出界了，上面那只就掉下来。
    /// 被拎着、在空中的不管（拎着一摞往上拖、往上扔时整摞带着走，落稳了再说）
    public static func heads(for selfID: String, pets: [Head], screens: [ScreenInfo]? = nil) -> [Platform] {
        let byID = Dictionary(pets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func above(_ h: Head) -> Bool {
            var seen: Set<String> = [h.id]
            var cur = h.below
            while let id = cur, !seen.contains(id) {
                if id == selfID { return true }
                seen.insert(id)
                cur = byID[id]?.below
            }
            return false
        }
        return pets.compactMap { h in
            guard h.id != selfID, h.usable, h.height > 0, !above(h) else { return nil }
            let half = h.halfWidth * widthRatio
            let x = Double(h.foot.x)
            let y = Double(h.foot.y) + h.height
            if h.standing, let screens, !screens.isEmpty, !screens.contains(where: { reachable(x: x, y: y, $0.visibleFrame) }) { return nil }
            return Platform(kind: .pet(id: h.id), segment: Segment(y: y, minX: x - half, maxX: x + half), anchorX: x)
        }
    }

    /// 头顶在这块屏幕的可站区域里：横向在屏幕里，高度在程序坞上沿和「菜单栏下面再留 headroom」之间
    static func reachable(x: Double, y: Double, _ vf: CGRect) -> Bool {
        x >= Double(vf.minX) && x < Double(vf.maxX) && y > Double(vf.minY) && y <= Double(vf.maxY) - Platforms.headroom
    }
}
