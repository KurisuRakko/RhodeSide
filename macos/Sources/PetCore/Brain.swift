import CoreGraphics
import Foundation

/// 小人的行为状态机 + 物理，从原 SpineStage 网页版 `engine.ts` 的漫步逻辑移植过来，改成在「平台」上走：
/// 平台是屏幕地面和窗口顶边（见 `Platforms`）。纯逻辑，不碰 AppKit，方便单元测试。
///
/// 坐标：AppKit 全局坐标（pt，y 向上）。`foot` 是脚底锚点。

public enum Behavior: String, Codable, Sendable, CaseIterable {
    case idle, walk, sit, sleep, interact, held, fall
}

/// 跟着电脑作息的档位（`Attention` 按键鼠闲置时长定）
public enum RestLevel: String, Codable, Sendable {
    /// 照常活动
    case awake
    /// 闲置了一会儿：坐着（或睡着）不走
    case resting
    /// 闲置很久：睡着
    case asleep
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
    /// 坐着 / 睡着时头顶的高度，按待机身高的比例（网页量的；叠叠乐的头顶跟着矮下去）
    public var sitHeight: Double
    public var sleepHeight: Double

    public init(height: Double = 120, halfWidth: Double = 30, stride: Double = 1, roles: Roles = Roles(), interactDuration: Double = 1,
                sitHeight: Double = 1, sleepHeight: Double = 1) {
        self.height = height
        self.halfWidth = halfWidth
        self.stride = stride
        self.roles = roles
        self.interactDuration = interactDuration
        self.sitHeight = sitHeight
        self.sleepHeight = sleepHeight
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

/// 现在哪个窗口在焦点（最前面那个应用最靠前的窗口）
public enum Focus: Equatable, Sendable {
    /// 不知道（单元测试、还没扫描）：当所有窗口都在焦点，行为照旧
    case unknown
    case window(UInt32)
    /// 最前面的应用一个窗口都没有（点了桌面）
    case none
}

public struct World: Sendable {
    public var platforms: [Platform]
    public var screens: [ScreenInfo]
    public var focus: Focus

    public init(platforms: [Platform] = [], screens: [ScreenInfo] = [], focus: Focus = .unknown) {
        self.platforms = platforms
        self.screens = screens
        self.focus = focus
    }

    public func isFocused(window id: UInt32) -> Bool {
        switch focus {
        case .unknown: return true
        case .window(let f): return f == id
        case .none: return false
        }
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
    /// 这段路是脚下被盖住了、往同一个窗口露出来的地方走（不在焦点的窗口上也照走）
    private var toVisible = false
    /// 这次下落是被人扔的（落地时发 `.dropped`）
    private var thrown = false
    /// 这次下落能落到别的小人头上：只有被人扔的、重启后放回别人头上的才行
    /// （从窗口边走下去、窗口关了掉下来的不行，免得套组成员意外叠上去就一直下不来）
    private var mayStack = false
    /// 叠在别人头上时，下面那只带着自己横着走的速度（给渲染端外推用）
    private var carryVX = 0.0
    /// 作息档位（`Attention` 每 0.1 秒设一次）
    public private(set) var restLevel: RestLevel = .awake
    /// 现在的坐 / 睡 / 待机是作息让的（醒来时只解除这种，不碰用户在「原地停留」里手动设的）
    private var restOwned = false
    /// 深夜：自由活动时更容易睡着
    public var night = false
    /// 头上叠着别的小人（原生层每帧设）：叠叠乐里谁都不躺下（睡觉），作息让睡就坐着
    public var carrying = false
    /// 在一摞里（站在别人头上，或者头上有人）
    public var inStack: Bool { isOnPet || carrying }
    /// 点一下、控制面板转身、转向同伴之后这么久不跟着鼠标转（不然马上被转回去）
    public static let faceHold = 3.0
    private var faceHeld = 0.0

    public init(params: PetParams, foot: CGPoint, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.params = params
        self.foot = foot
        self.random = random
        enter(.fall)
    }

    public var isMoving: Bool { behavior == .walk || behavior == .fall || behavior == .held }

    /// 现在头顶离脚多高（叠叠乐的头顶平台）：在播坐 / 睡动画时（连招里的那一步也算）按网页量的比例矮下去
    public var headHeight: Double {
        guard isStanding, let name = anim?.name else { return params.height }
        if name == params.roles.sleep { return params.height * params.sleepHeight }
        if name == params.roles.sit { return params.height * params.sitHeight }
        return params.height
    }

    /// 站在平台上（能做动作、能走）
    public var isStanding: Bool { support != .none && behavior != .held && behavior != .fall }

    /// 这次飞行的最高点（脚的高度）：原生层按它一次把窗口拉高到盖住整段弹道，飞行中不再每帧挪窗口
    public var apexY: Double {
        let vy = max(Double(velocity.dy), 0)
        return Double(foot.y) + vy * vy / (2 * Self.gravity)
    }

    /// 当前的竖直速度（pt/s）：只在下落时非 0
    public var visualVY: Double { behavior == .fall ? Double(velocity.dy) : 0 }

    /// 当前的水平速度（pt/s），给渲染端在两次位置更新之间外推用
    public var visualVX: Double {
        switch behavior {
        case .walk: return facePending ? 0 : Double(dir) * params.walkSpeed
        case .fall: return velocity.dx
        default: return isOnPet ? carryVX : 0
        }
    }

    public var isOnWindow: Bool {
        if case .some(.window) = support.kind { return true }
        return false
    }

    /// 叠在别的小人头上：自己不走，跟着下面那只动
    public var isOnPet: Bool { support.kind?.isPet ?? false }

    /// 站在谁头上
    public var below: String? {
        if case .some(.pet(let id)) = support.kind { return id }
        return nil
    }

    /* ---------------------------------------------------------------- 外部事件 */

    /// 按住拖动：拎起来
    public func grab() {
        thrown = false
        mayStack = false
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
        mayStack = true
        behavior = .fall
        playCurrent()
    }

    /// 单击：播互动动画（战斗形态播攻击连招）；都没有就转个身
    public func click() {
        guard support != .none, behavior != .held, behavior != .fall else { return }
        emit(.clicked)
        faceHeld = Self.faceHold
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
        faceHeld = Self.faceHold
        return true
    }

    /// 窗口撞上来了：弹一个抛物线跳到 `p`（窗口顶边上的落脚点），落地还是走 `fall` 的落平台逻辑。
    /// 顶点比 p 高一点（往下落时才认平台，上升途中不会被别的平台挡住）；被拎着、在空中、叠在别人头上的不跳
    @discardableResult
    public func hop(to p: CGPoint) -> Bool {
        guard isStanding, !isOnPet else { return false }
        let g = Self.gravity
        let margin = max(40, params.height * 0.3)
        let rise = max(Double(p.y - foot.y), 0) + margin
        // 逐帧积分（先减速度再走）比解析解矮半帧的位移：按 30fps 补上
        let vy = (2 * g * rise).squareRoot() + g / 60
        let t = vy / g + (2 * margin / g).squareRoot()
        // 下落时水平速度按 exp(-1.2t) 衰减：反推起跳的水平速度
        let k = 1.2
        let vx = Double(p.x - foot.x) * k / (1 - exp(-k * t))
        thrown = false
        mayStack = false
        support = .none
        anchor = nil
        velocity = CGVector(dx: min(max(vx, -Self.maxSpeed), Self.maxSpeed), dy: vy)
        if abs(vx) > 1 { dir = vx > 0 ? 1 : -1 }
        enter(.fall)
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
        guard isStanding, [.idle, .walk, .sit].contains(behavior), !battle, activity != .stay, !isOnPet, restLevel == .awake, params.roles.move != nil,
              let here = platform(world), !here.covered, !unfocused(here, world) else { return false }
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
        faceHeld = Self.faceHold
        // 原地停留时手动让它坐着的（计时无限）只转身，不打断
        guard !battle, behavior != .interact, timer.isFinite, params.roles.interact != nil else { return true }
        enter(.interact)
        return true
    }

    /* ---------------------------------------------------------------- 作息 / 看鼠标（Attention） */

    /// 设作息档位，可以每次都调（同一档重复调不会重播动画）。
    /// 闲置：停下来坐着（睡着也算），计时无限；很久：睡着；模型缺睡觉动画就坐着，缺坐下动画就睡，两样都没有就站着。
    /// 正在做动作、被拎着、在下落、战斗形态的不管（下一次调用再说）；「原地停留」里手动设的坐 / 睡不动。
    /// 醒来：只解除作息让的那次，回到待机。
    public func setRest(_ level: RestLevel) {
        restLevel = level
        guard isStanding, !battle else { return }
        var r = params.roles
        if inStack { r.sleep = nil } // 叠叠乐里不躺下
        guard level != .awake else {
            guard restOwned else { return }
            restOwned = false
            if [.idle, .sit, .sleep].contains(behavior) { enter(.idle) }
            return
        }
        let want: Behavior = level == .asleep && r.sleep != nil ? .sleep : r.sit != nil ? .sit : r.sleep != nil ? .sleep : .idle
        // 闲置一会儿时本来就在睡也行
        let fine: [Behavior] = level == .resting && r.sleep != nil && want == .sit ? [.sit, .sleep] : [want]
        if fine.contains(behavior) {
            if timer.isFinite {
                timer = .infinity
                restOwned = true
            }
            return
        }
        let manual = [.sit, .sleep].contains(behavior) && !timer.isFinite && !restOwned
        guard [.idle, .walk, .sit, .sleep].contains(behavior), !manual else { return }
        enter(want)
        timer = .infinity
        restOwned = true
    }

    /// 转过去看某个横坐标：只在待机、坐着时转，不打断走路、睡觉、做动作；刚被点过 / 转过身的不转（`faceHold`）
    @discardableResult
    public func glance(towardX x: Double) -> Bool {
        guard isStanding, behavior == .idle || behavior == .sit, !facePending, faceHeld <= 0 else { return false }
        let d = x >= foot.x ? 1 : -1
        guard d != dir else { return false }
        dir = d
        return true
    }

    /// 走 / 坐 / 睡的概率；深夜睡觉的那份乘 nightSleepBoost，多出来的从走路那份里扣（坐和继续待机不变）
    private func chances() -> (walk: Double, sit: Double, sleep: Double) {
        let t = tuning
        guard night else { return (t.walkChance, t.sitChance, t.sleepChance) }
        let z = min(t.sleepChance * t.nightSleepBoost, t.sleepChance + t.walkChance)
        return (t.walkChance - (z - t.sleepChance), t.sitChance, z)
    }

    /// 站在不在焦点的窗口上：只在脚下露出来的这段里溜达，不走出去、不跳窗边、套组不拉它
    private func unfocused(_ p: Platform, _ world: World) -> Bool {
        if case .window(let id) = p.kind { return !world.isFocused(window: id) }
        return false
    }

    /// 脚下被前面的窗口盖住了：往同一个窗口顶边上最近的露出来的地方走（身子整个露出来），中间被盖住的段照样走。
    /// 醒着、有走路动画、不是战斗形态、不是「原地停留」、不是手动 / 作息让它一直坐着睡着的才走；整个顶边都被盖住就待着
    private func seekVisible(_ p: Platform, _ world: World) -> Bool {
        guard p.covered, !toVisible, params.roles.move != nil, !battle, activity != .stay, restLevel == .awake,
              behavior == .walk || ([.idle, .sit, .sleep].contains(behavior) && timer.isFinite) else { return false }
        // 和 p 首尾相连的同一个窗口的顶边（露出来的、被盖住的都算）
        let same = world.platforms.filter { $0.kind == p.kind && abs($0.segment.y - p.segment.y) < 0.5 }.sorted { $0.segment.minX < $1.segment.minX }
        guard let i = same.firstIndex(of: p) else { return false }
        var lo = i, hi = i
        while lo > 0, same[lo - 1].segment.maxX >= same[lo].segment.minX - 2 { lo -= 1 }
        while hi < same.count - 1, same[hi + 1].segment.minX <= same[hi].segment.maxX + 2 { hi += 1 }
        let x = Double(foot.x)
        let spots = same[lo...hi].filter { !$0.covered }.map { $0.segment.clamp(x: x, half: params.halfWidth) }
        guard let t = spots.min(by: { abs($0 - x) < abs($1 - x) }), abs(t - x) > 1 else { return false }
        targetX = t
        dir = t >= x ? 1 : -1
        arriveFace = nil
        enter(.walk)
        toVisible = true
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
        case .sit where r.sit != nil, .sleep where r.sleep != nil && !inStack, .interact where r.interact != nil, .idle:
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

    /// 放到某个位置，从那里自由落下（恢复上次的位置、「叫回来」都用它）。
    /// `stack`：落下时能落到别的小人头上（重启后把叠着的放回去）
    public func teleport(to p: CGPoint, stack: Bool = false) {
        thrown = false
        mayStack = stack
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
        faceHeld = max(0, faceHeld - rawDt)
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
        } else if case .pet = kind {
            // 叠在头上：下面那只换了瘦一点的模型、头顶变窄了也不掉，夹回头顶范围
            p = first
            x = min(max(x, p.segment.minX), p.segment.maxX)
        } else {
            // 窗口关了、最小化了、被挪走了、脚下被别的窗口挡住了：都是找不到包含脚的那段
            guard let hit = same.first(where: { $0.segment.contains(x: x, tolerance: 1) }) else { return startFall() }
            p = hit
        }
        carryVX = kind.isPet ? anchor.map { (p.anchorX - $0) / dt } ?? 0 : 0
        if let a = anchor { targetX += p.anchorX - a }
        anchor = p.anchorX
        foot = CGPoint(x: x, y: p.segment.y)
        support = .on(kind, dx: x - p.anchorX)
        if seekVisible(p, world) { return }
        // 叠叠乐里不躺下：睡着的被人叠上来、或者叠上去时正睡着，改成坐着（没有坐下动画就站着）
        if behavior == .sleep, inStack {
            let keep = timer, owned = restOwned
            enter(params.roles.sit != nil ? .sit : .idle)
            if !keep.isFinite { timer = keep; restOwned = owned } // 作息 / 原地停留让它一直睡的，改成一直坐
        }

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
        var roles = params.roles
        if inStack { roles.sleep = nil } // 叠叠乐里不躺下
        let t = chances()
        if battle { return enter(.idle) }
        // 叠在别人头上、脚下被盖住了（又没露出来的地方可去）：不回集合点，也不走（按原地停留来坐、睡、待机）
        let stacked = isOnPet || p.covered
        if let l = leash, !stacked, !unfocused(p, world), activity != .stay, roles.move != nil {
            let below = isOnWindow && l.y < foot.y - Self.stepTolerance
            let side: Double = foot.x >= l.x ? 1 : -1
            if below || abs(foot.x - l.x) > l.radius, approach(CGPoint(x: l.x + side * l.gap, y: l.y), face: l.x, p, world) { return }
        }
        switch stacked ? Activity.stay : activity {
        case .walk:
            if roles.move != nil { startWalk(p, world) } else { enter(.idle) }
        case .stay:
            // 去掉走路那一份，坐、睡、待机按原来的比例
            let rest = max(1 - t.walk, 0.0001)
            if roles.sit != nil && r < t.sit / rest { enter(.sit) }
            else if roles.sleep != nil && r < (t.sit + t.sleep) / rest { enter(.sleep) }
            else { enter(.idle) }
        case .auto:
            if roles.move != nil && r < t.walk { startWalk(p, world) }
            else if roles.sit != nil && r < t.walk + t.sit { enter(.sit) }
            else if roles.sleep != nil && r < t.walk + t.sit + t.sleep { enter(.sleep) }
            else { enter(.idle) }
        }
    }

    private func startWalk(_ p: Platform, _ world: World) {
        // 不在焦点的窗口上只在脚下这段里走
        let away = unfocused(p, world)
        let (lo0, hi0) = away ? (p.segment.minX, p.segment.maxX) : span(of: p, world)
        let half = params.halfWidth
        let lo = lo0 + half
        let hi = hi0 - half
        var target: Double
        // 套组跟随者不随机跳窗（跳下去就爬不回集合点身边了）
        if case .window = p.kind, !away, leash == nil, random() < tuning.edgeJumpChance {
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
        // 不在焦点的窗口上（失焦前就在走的也算）：走到这段露出来的顶边的头（身子不伸出去）就停下，不掉下去、不走到别的窗口上
        if !toVisible, unfocused(p, world) {
            let lo = p.segment.minX + params.halfWidth, hi = p.segment.maxX - params.halfWidth
            let out = lo <= hi ? (d > 0 ? nx > hi : nx < lo) : !p.segment.contains(x: nx, tolerance: 0)
            if out { return enter(.idle) }
        }
        if p.segment.contains(x: nx, tolerance: 0) {
            foot.x = nx
            support = .on(p.kind, dx: nx - p.anchorX)
        } else if let q = neighbor(of: p, x: nx, world), !toVisible || q.kind == p.kind {
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
        // 往下落时穿过的最高那个平台。别人的头顶会随动作一下子升高（坐着的站起来），
        // 正好升到脚上方时也算落上去，不然会穿过它的身子掉下去
        if ny <= old.y {
            let rise = params.height * 0.6
            let hit = world.platforms
                .filter { (mayStack || !$0.kind.isPet) && !$0.covered }
                .filter { $0.segment.y <= old.y + ($0.kind.isPet ? rise : 0.5) && $0.segment.y >= ny && $0.segment.contains(x: nx, tolerance: 0) }
                .max { $0.segment.y < $1.segment.y }
            if let p = hit { return land(on: p, x: nx) }
        }
        let next = CGPoint(x: nx, y: ny)
        // 在程序坞 / 屏幕底边以下（比如程序坞刚弹出来盖住了脚）：放回地面
        if let s = world.screen(containing: next), ny < s.visibleFrame.minY, let g = world.ground(of: s) {
            return land(on: g, x: nx)
        }
        // 掉到横坐标所在的所有屏幕下面了（比如竖屏底边下面、旁边又没有屏幕）：放回主屏
        let column = world.screens.filter { nx >= Double($0.frame.minX) && nx < Double($0.frame.maxX) }
        let bottom = column.map { Double($0.frame.minY) }.min() ?? 0
        if column.isEmpty || ny < bottom - 50 { return rescue(world) }
        foot = next
    }

    private func land(on p: Platform, x: Double) {
        var x = x
        if case .ground = p.kind { x = p.segment.clamp(x: x, half: params.halfWidth) }
        foot = CGPoint(x: x, y: p.segment.y)
        velocity = .zero
        support = .on(p.kind, dx: x - p.anchorX)
        anchor = p.anchorX
        mayStack = false
        enter(.idle)
        if thrown {
            thrown = false
            // 丢到别人头上不算「被丢开」：套组其余成员不来找它（不然下面那只会驮着它走开）
            if !p.kind.isPet { emit(.dropped) }
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
        // 头顶不和别的平台相连：走不上去，也走不下来
        guard !p.kind.isPet else { return nil }
        return world.platforms
            .filter { $0 != p && !$0.kind.isPet && (!$0.covered || $0.kind == p.kind) && abs($0.segment.y - p.segment.y) <= Self.stepTolerance && $0.segment.contains(x: x, tolerance: 1) }
            .max { $0.segment.y < $1.segment.y }
    }

    /// 从 p 出发、能直接走过去的连续范围
    private func span(of p: Platform, _ world: World) -> (Double, Double) {
        var lo = p.segment.minX, loY = p.segment.y
        var hi = p.segment.maxX, hiY = p.segment.y
        guard !p.kind.isPet else { return (lo, hi) }
        let tol = Self.stepTolerance
        for _ in 0..<8 {
            guard let q = world.platforms.first(where: {
                !$0.kind.isPet && !$0.covered && abs($0.segment.y - hiY) <= tol && $0.segment.minX <= hi + 2 && $0.segment.maxX > hi + 1
            }) else { break }
            hi = q.segment.maxX
            hiY = q.segment.y
        }
        for _ in 0..<8 {
            guard let q = world.platforms.first(where: {
                !$0.kind.isPet && !$0.covered && abs($0.segment.y - loY) <= tol && $0.segment.maxX >= lo - 2 && $0.segment.minX < lo - 1
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
        toVisible = false
        restOwned = false // 作息让的那次由 setRest 在 enter 之后重新标上
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
