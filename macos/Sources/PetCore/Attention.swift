import CoreGraphics
import Foundation

/// 对人的反应：看鼠标、跟着电脑作息。纯逻辑，原生层大约每 0.1 秒调一次 `step`。
///
/// 平台相关的只有两个读数，都可以拿不到（nil）——拿不到哪个就只关掉对应的功能：
/// - `idle`：键鼠闲置秒数（macOS `CGEventSource`、Windows `GetLastInputInfo`、X11 XScreenSaver、Wayland `ext-idle-notify`）；
/// - `mouse`：鼠标全局坐标，和 `Brain.foot` 同一套坐标（Wayland 读不到全局指针时给 nil）；
/// - `screenKeptAwake`：有程序不让显示器自动熄灭（放视频、视频会议），读不到给 nil 当作没有
///   （macOS 电源断言 PreventUserIdleDisplaySleep、Windows `CallNtPowerInformation(SystemExecutionState)` 的 ES_DISPLAY_REQUIRED、
///   Linux D-Bus `org.gnome.SessionManager.IsInhibited(8)` / `org.freedesktop.PowerManagement.Inhibit.HasInhibit`）。
///
/// - 作息：闲置 ≥ `restSit` 秒全部坐下，≥ `restSleep` 秒、并且没在放视频才睡着（`Brain.setRest`）；放视频时最多坐着陪你看；从睡着醒来时离鼠标最近的那只
///   转过来做个互动动作，`step` 返回它的 id，由原生层让它说一句话（只一只出声）。
/// - 看鼠标：鼠标在身体中心 `lookRadius` 倍身高以内、越过身体中线一点，就转过去（`Brain.glance`），每只转一次后冷却一会儿。
/// - 深夜（`nightHours`）：`Brain.night`，自由活动时更容易睡着。
public final class Attention {
    public struct Input {
        public var idle: Double?
        public var mouse: CGPoint?
        /// 有程序不让显示器熄灭（放视频）：人在看，不睡
        public var screenKeptAwake: Bool?
        /// 本地时间的小时（0…24 的小数）
        public var hour: Double
        public var watchMouse: Bool
        public var restWhenIdle: Bool

        public init(idle: Double?, mouse: CGPoint?, screenKeptAwake: Bool? = nil, hour: Double, watchMouse: Bool = true, restWhenIdle: Bool = true) {
            self.idle = idle
            self.mouse = mouse
            self.screenKeptAwake = screenKeptAwake
            self.hour = hour
            self.watchMouse = watchMouse
            self.restWhenIdle = restWhenIdle
        }
    }

    public struct Member {
        public var id: String
        public var brain: Brain

        public init(id: String, brain: Brain) {
            self.id = id
            self.brain = brain
        }
    }

    /// 转一次身后多久内不再因为鼠标转身（秒）
    public static let lookCooldown = 1.2
    /// 鼠标要越过身体中线多少（半宽的倍数）才转，免得鼠标在身上晃时来回抽
    public static let lookDeadZone = 0.3

    public private(set) var level: RestLevel = .awake
    /// 这次走开以后睡着过（中途有程序开始放视频、降回坐着，小人照样在睡，回来时也要打招呼）
    private var slept = false
    private var cooldown: [String: Double] = [:]

    public init() {}

    /// 返回从睡着里醒来、该说一句话的那只（没有就 nil）
    @discardableResult
    public func step(dt: Double, input: Input, members: [Member], tuning: Tuning) -> String? {
        let next: RestLevel = {
            guard input.restWhenIdle, let idle = input.idle else { return .awake }
            if idle >= tuning.restSleep, input.screenKeptAwake != true { return .asleep }
            if idle >= tuning.restSit { return .resting }
            return .awake
        }()
        // 只有真的是人回来了才算醒（关掉开关、读不到闲置时长不算）
        if next == .asleep { slept = true }
        let woke = slept && next == .awake && input.restWhenIdle && input.idle != nil
        if next == .awake { slept = false }
        level = next
        let night = input.restWhenIdle && tuning.isNight(hour: input.hour)
        for m in members {
            m.brain.night = night
            m.brain.setRest(next)
        }

        var greeter: String?
        if woke {
            // 离鼠标最近、真的醒过来的那只（没有鼠标就按顺序）转过来做个动作；
            // 「原地停留」里手动睡着的 react 不理，轮到下一只
            var awake = members.filter { $0.brain.isStanding && !$0.brain.battle }
            if let m = input.mouse { awake.sort { Self.distance($0.brain, m) < Self.distance($1.brain, m) } }
            for p in awake where p.brain.react(towardX: input.mouse.map { Double($0.x) } ?? p.brain.foot.x) {
                greeter = p.id
                cooldown[p.id] = Self.lookCooldown
                break
            }
        }

        let ids = Set(members.map(\.id))
        cooldown = cooldown.filter { ids.contains($0.key) }.mapValues { $0 - max(dt, 0) }.filter { $0.value > 0 }
        guard input.watchMouse, let m = input.mouse else { return greeter }
        for mem in members where cooldown[mem.id] == nil {
            let b = mem.brain
            let mx = Double(m.x)
            guard Self.distance(b, m) <= tuning.lookRadius * b.params.height,
                  abs(mx - b.foot.x) > Self.lookDeadZone * b.params.halfWidth else { continue }
            if b.glance(towardX: mx) { cooldown[mem.id] = Self.lookCooldown }
        }
        return greeter
    }

    /// 鼠标到身体中心（脚底往上半个身高）的距离
    static func distance(_ b: Brain, _ m: CGPoint) -> Double {
        hypot(Double(m.x) - b.foot.x, Double(m.y) - (b.foot.y + b.params.height / 2))
    }
}
