import CoreGraphics
import Foundation

/// 套组联动：`link` 相同的桌宠结伴走、被丢开了互相找、一只被点另一只跟着反应。
/// 纯逻辑，原生层大约每 0.1 秒调一次 `step`（不用每帧：这里只做决定，走路还是各自的 Brain 在走）。
///
/// - 集合点：组里第一只；哪只被拎起来丢下，集合点就换成它（直到下一次有别的被丢下）。
/// - 结伴走：集合点自己开始走一段路 → 其余成员错开一点起步，走到目标后面按顺序排开，到了面朝它。
///   平时跟随者拴在集合点附近（`Brain.leash`），走远了会自己走回来。
/// - 被丢下：落地后其余成员走过去（坐着的会站起来，睡着的不叫醒）；在不同平台上就走到它正下方 / 从窗口边跳下去。
/// - 被点：其余成员稍后转向它，有互动动画就播（只有被点的那只出声，页面那边管）。
public final class Companions {
    public struct Member {
        public var id: String
        public var link: String?
        public var brain: Brain
        public var world: World

        public init(id: String, link: String?, brain: Brain, world: World) {
            self.id = id
            self.link = link
            self.brain = brain
            self.world = world
        }
    }

    enum Action: Equatable {
        /// 跟着集合点走到 target 后面第 rank 个位置
        case follow(leader: String, target: Double, rank: Int)
        /// 走到被丢下的那只旁边
        case seek(String, rank: Int)
        /// 转向被点的那只
        case react(String)
    }

    struct Pending: Equatable {
        var due: Double
        var id: String
        var action: Action
    }

    /// 两只之间留的空（pt）
    public static let gap = 12.0
    public var random: () -> Double
    private(set) var pending: [Pending] = []
    /// link → 集合点（被丢下的那只）
    private(set) var anchors: [String: String] = [:]
    private var now = 0.0

    public init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
    }

    /// 跟随者离集合点多远以内算在一起
    public static func radius(_ b: Brain) -> Double { max(b.params.height * 2.5, 200) }

    public func step(dt: Double, members: [Member]) {
        now += max(dt, 0)
        // 每只的事件都取走（不在套组里的也取，免得攒着）
        var events: [String: [BrainEvent]] = [:]
        for m in members { events[m.id] = m.brain.takeEvents() }

        var groups: [String: [Member]] = [:]
        var order: [String] = []
        for m in members {
            guard let l = m.link else {
                m.brain.leash = nil
                continue
            }
            if groups[l] == nil { order.append(l) }
            groups[l, default: []].append(m)
        }
        let byID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        anchors = anchors.filter { link, id in groups[link]?.contains { $0.id == id } ?? false }
        pending.removeAll { byID[$0.id]?.link == nil }

        for l in order {
            let group = groups[l]!
            guard group.count > 1 else {
                group[0].brain.leash = nil
                continue
            }
            for m in group {
                for e in events[m.id] ?? [] where e == .dropped {
                    anchors[l] = m.id
                    // 它自己原来要去追谁的事作废（现在别人来找它）
                    pending.removeAll { $0.id == m.id && Self.sameKind($0.action, .seek(m.id, rank: 0)) }
                }
            }
            let anchorID = anchors[l] ?? group[0].id
            guard let anchor = group.first(where: { $0.id == anchorID }) else { continue }
            let others = group.filter { $0.id != anchorID }

            for m in group {
                for e in events[m.id] ?? [] {
                    switch e {
                    case .dropped:
                        // 被丢下的那只现在是集合点：其余的一个个过去找它
                        for (i, o) in others.enumerated() {
                            schedule(o.id, .seek(m.id, rank: i + 1), after: 0.3 + 0.25 * Double(i) + 0.3 * random())
                        }
                    case .startedWalk(let target) where m.id == anchorID:
                        for (i, o) in others.enumerated() where o.brain.behavior == .idle || o.brain.behavior == .walk {
                            schedule(o.id, .follow(leader: m.id, target: target, rank: i + 1), after: 0.2 + 0.4 * random())
                        }
                    case .clicked:
                        for o in group where o.id != m.id {
                            schedule(o.id, .react(m.id), after: 0.3 + 0.3 * random())
                        }
                    default:
                        break
                    }
                }
            }

            anchor.brain.leash = nil
            for (i, o) in others.enumerated() {
                o.brain.leash = Leash(x: Double(anchor.brain.foot.x), y: Double(anchor.brain.foot.y), radius: Self.radius(o.brain),
                                      gap: Self.offset(rank: i + 1, in: group, anchorID: anchorID))
            }
        }

        let due = pending.filter { $0.due <= now }
        pending.removeAll { $0.due <= now }
        for p in due {
            guard let m = byID[p.id], let l = m.link, let group = groups[l] else { continue }
            run(p.action, m, group)
        }
    }

    private func schedule(_ id: String, _ a: Action, after: Double) {
        // 同一只同一种事只留最新的一件（连点几下不会排一长串）
        pending.removeAll { $0.id == id && Self.sameKind($0.action, a) }
        pending.append(Pending(due: now + after, id: id, action: a))
    }

    private static func sameKind(_ a: Action, _ b: Action) -> Bool {
        switch (a, b) {
        case (.follow, .follow), (.seek, .seek), (.react, .react): return true
        case (.follow, .seek), (.seek, .follow): return true // 都是「往哪走」：新的顶掉旧的
        default: return false
        }
    }

    /// 排在 target 旁边第 rank 个位置时离 target 多远：前面每只的半身宽 + 空隙累加
    static func offset(rank: Int, in group: [Member], anchorID: String) -> Double {
        let line = [group.first { $0.id == anchorID }].compactMap { $0 } + group.filter { $0.id != anchorID }
        var d = 0.0
        for i in 0..<min(rank, line.count - 1) {
            d += line[i].brain.params.halfWidth + line[i + 1].brain.params.halfWidth + gap
        }
        return d
    }

    private func run(_ a: Action, _ m: Member, _ group: [Member]) {
        let b = m.brain
        switch a {
        case .follow(let leaderID, let target, let rank):
            guard let leader = group.first(where: { $0.id == leaderID }), b.behavior == .idle || b.behavior == .walk else { return }
            // 领队半路停下了（被点、被拎走）：排到它现在的位置后面，不去原来的终点
            let end = leader.brain.behavior == .walk ? target : Double(leader.brain.foot.x)
            let d = Double(leader.brain.dir)
            let x = end - d * Self.offset(rank: rank, in: group, anchorID: leaderID)
            b.go(to: CGPoint(x: x, y: leader.brain.foot.y), face: end, world: m.world)
        case .seek(let targetID, let rank):
            guard let t = group.first(where: { $0.id == targetID }), t.brain.isStanding else { return }
            let tx = Double(t.brain.foot.x)
            let side: Double = Double(b.foot.x) >= tx ? 1 : -1
            let x = tx + side * Self.offset(rank: rank, in: group, anchorID: targetID)
            b.go(to: CGPoint(x: x, y: t.brain.foot.y), face: tx, world: m.world)
        case .react(let targetID):
            guard let t = group.first(where: { $0.id == targetID }) else { return }
            b.react(towardX: Double(t.brain.foot.x))
        }
    }
}
