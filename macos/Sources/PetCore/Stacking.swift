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

        public init(id: String, foot: CGPoint, height: Double, halfWidth: Double, below: String?, usable: Bool = true) {
            self.id = id
            self.foot = foot
            self.height = height
            self.halfWidth = halfWidth
            self.below = below
            self.usable = usable
        }
    }

    /// 给 `selfID` 那只小人看的头顶平台：不含自己的头，也不含叠在自己上面（沿「站在谁头上」往下能走到自己）的那些，免得成环
    public static func heads(for selfID: String, pets: [Head]) -> [Platform] {
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
            return Platform(kind: .pet(id: h.id), segment: Segment(y: Double(h.foot.y) + h.height, minX: x - half, maxX: x + half), anchorX: x)
        }
    }
}
