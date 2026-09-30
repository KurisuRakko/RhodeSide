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
    /// 战斗形态点一下播的套组（没有就转身）
    public var attack: [ComboStep] = []
    /// 正在播的套组和播到第几步（behavior == .interact 时有效）
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

    public init(params: PetParams, foot: CGPoint, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.params = params
        self.foot = foot
        self.random = random
        enter(.fall)
    }

    public var isMoving: Bool { behavior == .walk || behavior == .fall || behavior == .held }

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
        behavior = .fall
        playCurrent()
    }

    /// 单击：播互动动画（战斗形态播攻击套组）；都没有就转个身
    public func click() {
        guard support != .none, behavior != .held, behavior != .fall else { return }
        if battle {
            if !play(attack) { dir = -dir }
        } else if params.roles.interact != nil {
            enter(.interact)
        } else {
            dir = -dir
        }
    }

    /// 按顺序播一串动画（控制面板的套组按钮、战斗形态的点击）；播完回到待机
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
        if case .window = p.kind, random() < tuning.edgeJumpChance {
            target = random() < 0.5 ? lo0 - 2 : hi0 + 2 // 走出边缘，掉下去
        } else {
            guard hi - lo > 1 else { return enter(.idle) } // 平台比身子还窄，不走
            let minDist = min((hi - lo) / 2, 300)
            target = lo + random() * (hi - lo)
            for _ in 0..<6 where abs(target - foot.x) < minDist { target = lo + random() * (hi - lo) }
        }
        guard abs(target - foot.x) > 1 else { return enter(.idle) }
        targetX = target
        dir = target >= foot.x ? 1 : -1
        enter(.walk)
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
        if arrived { enter(.idle) }
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
