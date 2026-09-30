import CoreGraphics
import Foundation

/// 小人的行为状态机 + 物理，从原 SpineStage 网页版 `engine.ts` 的漫步逻辑移植过来，改成在「平台」上走：
/// 平台是屏幕地面和窗口顶边（见 `Platforms`）。纯逻辑，不碰 AppKit，方便单元测试。
///
/// 坐标：AppKit 全局坐标（pt，y 向上）。`foot` 是脚底锚点。

public enum Behavior: String, Codable, Sendable, CaseIterable {
    case idle, walk, sit, sleep, interact, held, fall
}

/// 动画角色 → 动画名（网页按命名规则认出来的；没有就是 nil）
public struct Roles: Equatable, Sendable {
    public var idle: String?
    public var move: String?
    public var interact: String?
    public var sit: String?
    public var sleep: String?

    public init(idle: String? = nil, move: String? = nil, interact: String? = nil, sit: String? = nil, sleep: String? = nil) {
        self.idle = idle
        self.move = move
        self.interact = interact
        self.sit = sit
        self.sleep = sleep
    }
}

public struct PetParams: Equatable, Sendable {
    /// 待机姿势的高度（pt）
    public var height: Double
    /// 身体半宽（pt），用来让身子不伸出平台
    public var halfWidth: Double
    /// 步速倍率
    public var stride: Double
    public var roles: Roles
    /// 互动动画时长（秒），网页的 animDone 没来时的兜底
    public var interactDuration: Double

    public init(height: Double = 120, halfWidth: Double = 30, stride: Double = 1, roles: Roles = Roles(), interactDuration: Double = 1) {
        self.height = height
        self.halfWidth = halfWidth
        self.stride = stride
        self.roles = roles
        self.interactDuration = interactDuration
    }

    /// 走路速度（pt/s）：和 engine.ts 一样的经验公式（静止高度 × 0.42 × 步速倍率）
    public var walkSpeed: Double { height * 0.42 * stride }
}

public enum Support: Equatable, Sendable {
    case none
    /// 站在某个平台上；`dx` = 脚的横坐标 − 平台的 anchorX（窗口移动时小人跟着平移）
    case on(PlatformKind, dx: Double)

    public var kind: PlatformKind? {
        if case .on(let k, _) = self { return k }
        return nil
    }
}

/// 想让网页播的动画；`token` 变了就要重发（同名动画重播也算）
public struct AnimRequest: Equatable, Sendable {
    public var name: String
    public var loop: Bool
    public var token: Int
}

/// 给套组联动（`Companions`）看的事件：由协调器定期取走
public enum BrainEvent: Equatable, Sendable {
    /// 被点了一下
    case clicked
    /// 被拎起来、扔下去以后落了地
    case dropped
    /// 自己开始走一段路（目标横坐标）
    case startedWalk(target: Double)
}

/// 套组里的跟随者拴在集合点附近：待机结束做决定时，离得远就走回去，否则随机走的目标不超出半径
public struct Leash: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var radius: Double
    /// 走回去时站在集合点旁边多远（排队的位置，免得几只叠在集合点身上）
    public var gap: Double

    public init(x: Double, y: Double, radius: Double, gap: Double = 0) {
        self.x = x
        self.y = y
        self.radius = radius
        self.gap = gap
    }
}

public struct World: Sendable {
    public var platforms: [Platform]
    public var screens: [ScreenInfo]

    public init(platforms: [Platform] = [], screens: [ScreenInfo] = []) {
        self.platforms = platforms
        self.screens = screens
    }

    public func screen(containing p: CGPoint) -> ScreenInfo? {
        screens.first { $0.frame.contains(p) }
    }

    public func screen(spanningX x: Double) -> ScreenInfo? {
        screens.first { x >= Double($0.frame.minX) && x < Double($0.frame.maxX) }
    }

    public func ground(of s: ScreenInfo) -> Platform? {
        platforms.first { $0.kind == .ground(screen: s.id) }
    }
}

public final class Brain {
    public static let gravity = 2800.0
    public static let maxSpeed = 3000.0
    /// 相邻平台高度差在这以内可以直接走过去（两块屏幕的地面、并排的两个窗口）
    public static let stepTolerance = 6.0
    public var params: PetParams
    public var tuning = Tuning()
    public private(set) var activity: Activity = .auto
    public var random: () -> Double
    /// 转身已经发给网页、还没画出来：这期间不走（原生层收到 faced 回执或超时后清掉），免得倒着滑一两帧
    public var facePending = false
    /// 战斗形态（正面 / 背面模型）：不走动、不坐不睡，待机时循环 pose；点一下播 attack
    public private(set) var battle = false
    /// 战斗形态待机时循环的动画（控制面板的「动作」下拉框）；nil = 模型的待机动画
    public var pose: String? {
        didSet { if battle, pose != oldValue, [.idle, .held, .fall].contains(behavior) { playCurrent() } }
    }
    /// 战斗形态点一下播的连招（没有就转身）
    public var attack: [ComboStep] = []
    /// 正在播的连招和播到第几步（behavior == .interact 时有效）
    private var steps: [ComboStep] = []
    private var stepIndex = 0

    public private(set) var foot: CGPoint
    public private(set) var velocity: CGVector = .zero
    public private(set) var behavior: Behavior = .fall
    public private(set) var dir = 1
    public private(set) var support: Support = .none
    public private(set) var anim: AnimRequest?
    private var timer = 0.0
    private var targetX = 0.0
    private var token = 0
    /// 上一帧脚下平台的 anchorX：平台移动时，走路的目标点跟着平移
    private var anchor: Double?
    /// 套组联动用
    public private(set) var events: [BrainEvent] = []
    public var leash: Leash?
    /// 这段路走到了以后面朝哪（套组里走到同伴旁边时面朝它）
    private var arriveFace: Double?
    /// 这次下落是被人扔的（落地时发 `.dropped`）
    private var thrown = false

    public init(params: PetParams, foot: CGPoint, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.params = params
        self.foot = foot
        self.random = random
        enter(.fall)
    }

    public var isMoving: Bool { behavior == .walk || behavior == .fall || behavior == .held }

    /// 站在平台上（能做动作、能走）
    public var isStanding: Bool { support != .none && behavior != .held && behavior != .fall }

    /// 当前的水平速度（pt/s），给渲染端在两次位置更新之间外推用
    public var visualVX: Double {
        switch behavior {
        case .walk: return facePending ? 0 : Double(dir) * params.walkSpeed
        case .fall: return velocity.dx
        default: return 0
        }
    }

    public var isOnWindow: Bool {
        if case .some(.window) = support.kind { return true }
        return false
    }

    /* ---------------------------------------------------------------- 外部事件 */

    /// 按住拖动：拎起来
    public func grab() {
        thrown = false
        support = .none
        anchor = nil
        velocity = .zero
        enter(.held)
    }

    /// 拎着移动；不许拖到程序坞 / 屏幕底边下面
    public func drag(to p: CGPoint, world: World) {
        guard behavior == .held else { return }
        var q = p
        if let s = world.screen(containing: q) { q.y = max(q.y, s.visibleFrame.minY) }
        foot = q
    }

    /// 松手：按鼠标最后的速度扔出去
    public func release(velocity v: CGVector) {
        guard behavior == .held else { return }
        let m = Self.maxSpeed
        velocity = CGVector(dx: min(max(v.dx, -m), m), dy: min(max(v.dy, -m), m))
        thrown = true
        behavior = .fall
        playCurrent()
    }

    /// 单击：播互动动画（战斗形态播攻击连招）；都没有就转个身
    public func click() {
        guard support != .none, behavior != .held, behavior != .fall else { return }
        emit(.clicked)
        if battle {
            if !play(attack) { dir = -dir }
        } else if params.roles.interact != nil {
            enter(.interact)
        } else {
            dir = -dir
        }
    }

    /// 控制面板的「转身」：站稳了就掉个头；走着路就先停下（不然会倒着走），
    /// 并且至少站一个普通待机的时长，免得「一直行走」下马上起步又转回去
    @discardableResult
    public func turn() -> Bool {
        guard support != .none, behavior != .held, behavior != .fall else { return false }
        if behavior == .walk || behavior == .idle {
            enter(.idle)
            timer = max(timer, rand(tuning.idle[0], tuning.idle[1]))
        }
        dir = -dir
        return true
    }

    /* ---------------------------------------------------------------- 套组联动 */

    /// 取走积攒的事件
    public func takeEvents() -> [BrainEvent] {
        defer { events = [] }
        return events
    }

    private func emit(_ e: BrainEvent) {
        events.append(e)
        if events.count > 16 { events.removeFirst(events.count - 16) } // 没人取（不在套组里）时别越攒越多
    }

    /// 走到某个点附近：目标在同一片能走的范围里就走过去（夹在范围内）；目标在脚下更低的地方而自己站在窗口上，
    /// 就从离目标近的那一边走出窗口跳下去；目标在高处就走到它正下方。
    /// 走到了面朝 `face`。坐着也会站起来；睡觉、做动作、战斗形态、原地停留、没有走路动画都不走。
    @discardableResult
    public func go(to p: CGPoint, face: Double? = nil, world: World) -> Bool {
        guard isStanding, [.idle, .walk, .sit].contains(behavior), !battle, activity != .stay, params.roles.move != nil,
              let here = platform(world) else { return false }
        return approach(p, face: face, here, world)
    }

    /// 转向某个横坐标；走着路就先停下
    public func face(towardX x: Double) {
        guard isStanding, abs(x - foot.x) > 1 else { return }
        let d = x >= foot.x ? 1 : -1
        guard d != dir else { return }
        if behavior == .walk { enter(.idle) }
        dir = d
    }

    /// 同伴被点了：转过去看它，有互动动画就播（睡着的不理，正在做动作的只转身，战斗形态只转身）
    @discardableResult
    public func react(towardX x: Double) -> Bool {
        guard isStanding, behavior != .sleep else { return false }
        face(towardX: x)
        // 原地停留时手动让它坐着的（计时无限）只转身，不打断
        guard !battle, behavior != .interact, timer.isFinite, params.roles.interact != nil else { return true }
        enter(.interact)
        return true
    }

    /// 脚下的平台（找不到就 nil）
    private func platform(_ world: World) -> Platform? {
        guard case .on(let kind, let dx) = support else { return nil }
        let same = world.platforms.filter { $0.kind == kind }
        if case .ground = kind { return same.first }
        return same.first { $0.segment.contains(x: $0.anchorX + dx, tolerance: 1) }
    }

    private func approach(_ p: CGPoint, face: Double?, _ here: Platform, _ world: World) -> Bool {
        let (lo, hi) = span(of: here, world)
        let half = params.halfWidth
        var target: Double
        if case .window = here.kind, Double(p.y) < foot.y - Self.stepTolerance,
           let edge = jumpEdge(lo, hi, toward: Double(p.x), world) {
            target = edge
        } else {
            target = hi - lo > 2 * half ? min(max(Double(p.x), lo + half), hi - half) : foot.x
        }
        guard abs(target - foot.x) > 2 else {
            if let f = face { self.face(towardX: f) }
            if behavior == .walk || behavior == .sit { enter(.idle) }
            return false
        }
        targetX = target
        dir = target >= foot.x ? 1 : -1
        arriveFace = face
        enter(.walk)
        return true
    }

    /// 从窗口哪边跳下去离 x 近：那一边下面得有屏幕（贴着最外侧屏幕边的窗口，走出去会掉出所有屏幕）
    private func jumpEdge(_ lo: Double, _ hi: Double, toward x: Double, _ world: World) -> Double? {
        let edges = [lo - 2, hi + 2].filter { world.screen(spanningX: $0) != nil }
        return edges.min { abs($0 - x) < abs($1 - x) }
    }

    /// 按顺序播一串动画（控制面板的连招按钮、战斗形态的点击）；播完回到待机
    @discardableResult
    public func play(_ sequence: [ComboStep]) -> Bool {
        guard !sequence.isEmpty, support != .none, behavior != .held, behavior != .fall else { return false }
        behavior = .interact
        steps = sequence
        stepIndex = 0
        startStep()
        return true
    }

    private func startStep() {
        let s = steps[stepIndex]
        timer = s.loop ? s.seconds : max(0.2, s.seconds) + 0.5
        token += 1
        anim = AnimRequest(name: s.name, loop: s.loop, token: token)
    }

    private func nextStep() {
        stepIndex += 1
        if stepIndex < steps.count { startStep() } else { enter(.idle) }
    }

    /// 切换基建 / 战斗形态（换了模型组时由原生层调）
    public func setBattle(_ on: Bool) {
        guard on != battle else { return }
        battle = on
        guard support != .none, behavior != .held, behavior != .fall else { return }
        enter(.idle)
    }

    /// 控制面板里的「互动 / 坐下 / 睡觉 / 站着」；模型没有这个动画、或者不在平台上就不理。
    /// 原地不动模式下坐下 / 睡觉会一直保持，直到换别的动作或换模式
    @discardableResult
    public func perform(_ b: Behavior) -> Bool {
        guard support != .none, behavior != .held, behavior != .fall else { return false }
        if battle {
            guard b == .idle else { return false }
            enter(.idle)
            return true
        }
        let r = params.roles
        switch b {
        case .sit where r.sit != nil, .sleep where r.sleep != nil, .interact where r.interact != nil, .idle:
            enter(b)
            if activity == .stay, b == .sit || b == .sleep { timer = .infinity }
            return true
        default:
            return false
        }
    }

    public func setActivity(_ a: Activity) {
        guard a != activity else { return }
        activity = a
        guard support != .none, behavior != .held, behavior != .fall else { return }
        switch a {
        case .stay where behavior == .walk: enter(.idle)
        case .walk where behavior != .walk && behavior != .interact: timer = min(timer, rand(tuning.walkPause[0], tuning.walkPause[1]))
        default: if !timer.isFinite { enter(.idle) }
        }
    }

    public func animationFinished(_ name: String) {
        guard behavior == .interact else { return }
        if !steps.isEmpty {
            if steps[stepIndex].name == name, !steps[stepIndex].loop { nextStep() }
        } else if name == params.roles.interact {
            enter(.idle)
        }
    }

    /// 放到某个位置，从那里自由落下（恢复上次的位置、「叫回来」都用它）
    public func teleport(to p: CGPoint) {
        thrown = false
        foot = p
        support = .none
        anchor = nil
        velocity = .zero
        enter(.fall)
    }

    /// 换了模型（动画名变了）：按当前行为重新要一次动画
    public func refreshAnimation() {
        if steps.isEmpty { playCurrent(force: true) } else { enter(.idle) }
    }

    /* ---------------------------------------------------------------- 每帧 */

    public func step(dt rawDt: Double, world: World) {
        guard rawDt > 0, !world.platforms.isEmpty else { return }
        let dt = min(rawDt, 0.05)
        switch behavior {
        case .held: return
        case .fall: fall(dt, world)
        default: stand(dt, world)
        }
    }

    private func stand(_ dt: Double, _ world: World) {
        guard case .on(let kind, let dx) = support else { return startFall() }
        let same = world.platforms.filter { $0.kind == kind }
        guard let first = same.first else { return startFall() }
        var x = first.anchorX + dx
        let p: Platform
        if case .ground = kind {
            // 地面不会让小人掉下去：程序坞挪了、屏幕变窄了就把脚夹回来（不按半身宽夹，走到隔壁屏幕时才不会跳一下）
            p = first
            x = min(max(x, p.segment.minX), p.segment.maxX)
        } else {
            // 窗口关了、最小化了、被挪走了、脚下被别的窗口挡住了：都是找不到包含脚的那段
            guard let hit = same.first(where: { $0.segment.contains(x: x, tolerance: 1) }) else { return startFall() }
            p = hit
        }
        if let a = anchor { targetX += p.anchorX - a }
        anchor = p.anchorX
        foot = CGPoint(x: x, y: p.segment.y)
        support = .on(kind, dx: x - p.anchorX)

        switch behavior {
        case .walk:
            walk(dt, p, world)
        case .idle, .sit, .sleep, .interact:
            timer -= dt
            if timer <= 0 {
                if behavior == .idle { decide(p, world) } else if behavior == .interact, !steps.isEmpty { nextStep() } else { enter(.idle) }
            }
        case .held, .fall:
            break
        }
    }

    private func decide(_ p: Platform, _ world: World) {
        let r = random()
        let roles = params.roles
        let t = tuning
        if battle { return enter(.idle) }
        if let l = leash, activity != .stay, roles.move != nil {
            let below = isOnWindow && l.y < foot.y - Self.stepTolerance
            let side: Double = foot.x >= l.x ? 1 : -1
            if below || abs(foot.x - l.x) > l.radius, approach(CGPoint(x: l.x + side * l.gap, y: l.y), face: l.x, p, world) { return }
        }
        switch activity {
        case .walk:
            if roles.move != nil { startWalk(p, world) } else { enter(.idle) }
        case .stay:
            // 去掉走路那一份，坐、睡、待机按原来的比例
            let rest = max(1 - t.walkChance, 0.0001)
            if roles.sit != nil && r < t.sitChance / rest { enter(.sit) }
            else if roles.sleep != nil && r < (t.sitChance + t.sleepChance) / rest { enter(.sleep) }
            else { enter(.idle) }
        case .auto:
            if roles.move != nil && r < t.walkChance { startWalk(p, world) }
            else if roles.sit != nil && r < t.walkChance + t.sitChance { enter(.sit) }
            else if roles.sleep != nil && r < t.walkChance + t.sitChance + t.sleepChance { enter(.sleep) }
            else { enter(.idle) }
        }
    }

    private func startWalk(_ p: Platform, _ world: World) {
        let (lo0, hi0) = span(of: p, world)
        let half = params.halfWidth
        let lo = lo0 + half
        let hi = hi0 - half
        var target: Double
        // 套组跟随者不随机跳窗（跳下去就爬不回集合点身边了）
        if case .window = p.kind, leash == nil, random() < tuning.edgeJumpChance {
            target = random() < 0.5 ? lo0 - 2 : hi0 + 2 // 走出边缘，掉下去
        } else {
            // 套组跟随者：只在集合点附近溜达
            // （集合点够不着、半径和这片范围不相交时就照常在整片范围里走）
            let near = leash.map { (max(lo, $0.x - $0.radius), min(hi, $0.x + $0.radius)) }
            let (a, b) = near.flatMap { $0.1 - $0.0 > 1 ? $0 : nil } ?? (lo, hi)
            guard b - a > 1 else { return enter(.idle) } // 平台比身子还窄，不走
            let minDist = min((b - a) / 2, 300)
            target = a + random() * (b - a)
            for _ in 0..<6 where abs(target - foot.x) < minDist { target = a + random() * (b - a) }
        }
        guard abs(target - foot.x) > 1 else { return enter(.idle) }
        targetX = target
        dir = target >= foot.x ? 1 : -1
        arriveFace = nil
        enter(.walk)
        emit(.startedWalk(target: target))
    }

    private func walk(_ dt: Double, _ p: Platform, _ world: World) {
        guard !facePending else { return }
        let d = targetX - foot.x
        let stepLen = params.walkSpeed * dt
        let arrived = abs(d) <= stepLen
        let nx = arrived ? targetX : foot.x + (d > 0 ? stepLen : -stepLen)
        if p.segment.contains(x: nx, tolerance: 0) {
            foot.x = nx
            support = .on(p.kind, dx: nx - p.anchorX)
        } else if let q = neighbor(of: p, x: nx, world) {
            // 走到相邻、差不多高的平台上（另一块屏幕的地面、并排的窗口）
            foot = CGPoint(x: nx, y: q.segment.y)
            support = .on(q.kind, dx: nx - q.anchorX)
            anchor = q.anchorX
        } else if case .ground = p.kind {
            return enter(.idle) // 地面走到头（目标本来都在地面范围里，屏幕变了才会这样）
        } else {
            // 走出窗口边缘：带着走路的速度掉下去
            foot.x = nx
            support = .none
            anchor = nil
            velocity = CGVector(dx: Double(dir) * params.walkSpeed, dy: 0)
            behavior = .fall
            playCurrent()
            return
        }
        if arrived {
            if let f = arriveFace, abs(f - foot.x) > 1 { dir = f >= foot.x ? 1 : -1 }
            arriveFace = nil
            enter(.idle)
        }
    }

    private func fall(_ dt: Double, _ world: World) {
        velocity.dy = max(velocity.dy - Self.gravity * dt, -Self.maxSpeed)
        velocity.dx *= exp(-1.2 * dt)
        let old = foot
        var nx = old.x + velocity.dx * dt
        let ny = old.y + velocity.dy * dt
        let half = params.halfWidth
        // 横着撞到屏幕边（那边没有别的屏幕）就弹回来
        if world.screen(spanningX: nx) == nil, let s = world.screen(spanningX: old.x) {
            nx = min(max(nx, s.frame.minX + half), s.frame.maxX - half)
            velocity.dx = -velocity.dx * 0.4
        }
        // 往下落时穿过的最高那个平台
        if ny <= old.y {
            let hit = world.platforms
                .filter { $0.segment.y <= old.y + 0.5 && $0.segment.y >= ny && $0.segment.contains(x: nx, tolerance: 0) }
                .max { $0.segment.y < $1.segment.y }
            if let p = hit { return land(on: p, x: nx) }
        }
        let next = CGPoint(x: nx, y: ny)
        // 在程序坞 / 屏幕底边以下（比如程序坞刚弹出来盖住了脚）：放回地面
        if let s = world.screen(containing: next), ny < s.visibleFrame.minY, let g = world.ground(of: s) {
            return land(on: g, x: nx)
        }
        let bottom = world.screens.map { Double($0.frame.minY) }.min() ?? 0
        if ny < bottom - 50 || world.screen(spanningX: nx) == nil { return rescue(world) }
        foot = next
    }

    private func land(on p: Platform, x: Double) {
        var x = x
        if case .ground = p.kind { x = p.segment.clamp(x: x, half: params.halfWidth) }
        foot = CGPoint(x: x, y: p.segment.y)
        velocity = .zero
        support = .on(p.kind, dx: x - p.anchorX)
        anchor = p.anchorX
        enter(.idle)
        if thrown {
            thrown = false
            emit(.dropped)
        }
    }

    /// 掉出了所有屏幕（拔了显示器、屏幕之间的缝）：放回主屏地面中间
    private func rescue(_ world: World) {
        guard let s = world.screens.first, let g = world.ground(of: s) else { return }
        land(on: g, x: s.visibleFrame.midX)
    }

    private func startFall() {
        support = .none
        anchor = nil
        velocity = .zero
        enter(.fall)
    }

    /// 相邻、差不多高、包含 x 的平台（优先最高的）
    private func neighbor(of p: Platform, x: Double, _ world: World) -> Platform? {
        world.platforms
            .filter { $0 != p && abs($0.segment.y - p.segment.y) <= Self.stepTolerance && $0.segment.contains(x: x, tolerance: 1) }
            .max { $0.segment.y < $1.segment.y }
    }

    /// 从 p 出发、能直接走过去的连续范围
    private func span(of p: Platform, _ world: World) -> (Double, Double) {
        var lo = p.segment.minX, loY = p.segment.y
        var hi = p.segment.maxX, hiY = p.segment.y
        let tol = Self.stepTolerance
        for _ in 0..<8 {
            guard let q = world.platforms.first(where: {
                abs($0.segment.y - hiY) <= tol && $0.segment.minX <= hi + 2 && $0.segment.maxX > hi + 1
            }) else { break }
            hi = q.segment.maxX
            hiY = q.segment.y
        }
        for _ in 0..<8 {
            guard let q = world.platforms.first(where: {
                abs($0.segment.y - loY) <= tol && $0.segment.maxX >= lo - 2 && $0.segment.minX < lo - 1
            }) else { break }
            lo = q.segment.minX
            loY = q.segment.y
        }
        return (lo, hi)
    }

    /* ---------------------------------------------------------------- 状态切换 */

    private func enter(_ b: Behavior) {
        behavior = b
        steps = []
        switch b {
        case .idle: timer = activity == .walk ? rand(tuning.walkPause[0], tuning.walkPause[1]) : rand(tuning.idle[0], tuning.idle[1])
        case .sit: timer = rand(tuning.sit[0], tuning.sit[1])
        case .sleep: timer = rand(tuning.sleep[0], tuning.sleep[1])
        case .interact: timer = max(0.3, params.interactDuration) + 0.5
        case .walk, .held, .fall: break
        }
        playCurrent(force: b == .interact)
    }

    private func playCurrent(force: Bool = false) {
        let r = params.roles
        let (name, loop): (String?, Bool) = {
            switch behavior {
            case .idle, .held, .fall: return (battle ? (pose ?? r.idle) : r.idle, true)
            case .walk: return (r.move ?? r.idle, true)
            case .sit: return (r.sit ?? r.idle, true)
            case .sleep: return (r.sleep ?? r.idle, true)
            case .interact: return (r.interact ?? r.idle, r.interact == nil)
            }
        }()
        guard let name else { return }
        if !force, let a = anim, a.name == name, a.loop == loop { return }
        token += 1
        anim = AnimRequest(name: name, loop: loop, token: token)
    }

    private func rand(_ a: Double, _ b: Double) -> Double { a + random() * (b - a) }
}
