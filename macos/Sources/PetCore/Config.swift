import Foundation

/// `~/Library/Application Support/Rhodeside/config.json`。
/// 所有字段读的时候都有默认值：缺字段、以后加字段、旧版本的文件都能读；文件坏了就备份一份再用默认值。
public struct AppConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var pets: [PetConfig]
    public var hideInFullscreen: Bool
    public var walkOnWindows: Bool
    /// 按程序名忽略的窗口（截图工具、悬浮条这类「空气窗口」）
    public var ignoredApps: [String]
    /// 公网热更新通道
    public var updates: UpdateConfig
    /// Priestess 登录（更新和下载模型都要登录）
    public var auth: AuthConfig
    /// 走完了首次启动的引导（登录 / 跳过）
    public var onboarded: Bool
    /// 基建语音（模型带 voice/ 才有）
    public var voice: VoiceConfig
    /// 套组：存起来的一组桌宠（比如一对 CP），一键召出替换桌面上的全部桌宠
    public var teams: [Team]
    /// 界面语言："system"（跟随系统）/ "zh-Hans" / "zh-Hant" / "en"，见 `UILanguage`
    public var language: String
    /// 鼠标靠近时转过来看（`Attention`）
    public var watchMouse: Bool
    /// 跟着电脑作息：键鼠闲置久了坐下、睡觉，一动就醒（`Attention`）
    public var restWhenIdle: Bool
    /// 拖动 / 缩放窗口压到小人时，小人弹到窗口顶上（`WindowHop`）
    public var hopOnWindows: Bool

    /// 默认模型（不再打进 App：登录后从服务器下载）
    public static let builtinModel = "荒芜拉普兰德"
    /// 每只桌宠一个网页进程，太多了吃内存
    public static let maxPets = 8
    /// 内置的「空气窗口」程序名：截图、贴图、菜单栏整理、录屏这类工具的透明悬浮窗
    public static let defaultIgnoredApps = [
        "Snipaste", "PixPin", "iShot", "iShot Pro", "CleanShot X", "Shottr", "Xnip", "screencaptureui",
        "Bartender 4", "Bartender 5", "Ice", "Hidden Bar", "Loom", "OBS", "Rectangle", "Magnet",
    ]

    public init(
        version: Int = 1,
        pets: [PetConfig] = [PetConfig()],
        hideInFullscreen: Bool = true,
        walkOnWindows: Bool = true,
        ignoredApps: [String] = AppConfig.defaultIgnoredApps,
        updates: UpdateConfig = UpdateConfig(),
        auth: AuthConfig = AuthConfig(),
        onboarded: Bool = false,
        voice: VoiceConfig = VoiceConfig(),
        teams: [Team] = [],
        language: String = UILanguage.system,
        watchMouse: Bool = true,
        restWhenIdle: Bool = true,
        hopOnWindows: Bool = false
    ) {
        self.version = version
        self.pets = pets
        self.hideInFullscreen = hideInFullscreen
        self.walkOnWindows = walkOnWindows
        self.ignoredApps = ignoredApps
        self.updates = updates
        self.auth = auth
        self.onboarded = onboarded
        self.voice = voice
        self.teams = teams
        self.language = language
        self.watchMouse = watchMouse
        self.restWhenIdle = restWhenIdle
        self.hopOnWindows = hopOnWindows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        pets = try c.decodeIfPresent([PetConfig].self, forKey: .pets) ?? d.pets
        hideInFullscreen = try c.decodeIfPresent(Bool.self, forKey: .hideInFullscreen) ?? d.hideInFullscreen
        walkOnWindows = try c.decodeIfPresent(Bool.self, forKey: .walkOnWindows) ?? d.walkOnWindows
        ignoredApps = try c.decodeIfPresent([String].self, forKey: .ignoredApps) ?? d.ignoredApps
        updates = try c.decodeIfPresent(UpdateConfig.self, forKey: .updates) ?? d.updates
        auth = try c.decodeIfPresent(AuthConfig.self, forKey: .auth) ?? d.auth
        // 旧版本写的配置没有这个键：那是已经在用的人，不再弹引导
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? true
        voice = try c.decodeIfPresent(VoiceConfig.self, forKey: .voice) ?? d.voice
        // 手改坏了套组不连累整份配置（桌宠还在），套组先当没有
        teams = (try? c.decodeIfPresent([Team].self, forKey: .teams)) ?? d.teams
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? d.language
        watchMouse = (try? c.decodeIfPresent(Bool.self, forKey: .watchMouse)) ?? d.watchMouse
        restWhenIdle = (try? c.decodeIfPresent(Bool.self, forKey: .restWhenIdle)) ?? d.restWhenIdle
        hopOnWindows = (try? c.decodeIfPresent(Bool.self, forKey: .hopOnWindows)) ?? d.hopOnWindows
    }

    public enum LoadResult: Equatable, Sendable {
        case missing
        case loaded
        /// 文件坏了，已挪到这个路径
        case broken(backup: String)
    }

    /// 读配置；文件不存在给默认值，读不懂就把原文件改名备份（不覆盖用户的东西）再给默认值。
    public static func load(from url: URL, fileManager fm: FileManager = .default) -> (AppConfig, LoadResult) {
        guard let data = try? Data(contentsOf: url) else { return (AppConfig(), .missing) }
        do {
            return (try JSONDecoder().decode(AppConfig.self, from: data), .loaded)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingPathExtension().appendingPathExtension("broken-\(stamp).json")
            try? fm.moveItem(at: url, to: backup)
            return (AppConfig(), .broken(backup: backup.path))
        }
    }

    /// 写盘用的格式（缩进、键排序：手改、diff 都方便）
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    public func save(to url: URL, fileManager fm: FileManager = .default) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}

/// 套组：成员存完整的桌宠参数（id 只在套组里有用，召出时换新的）
public struct Team: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var members: [PetConfig]

    public init(id: String = UUID().uuidString, name: String, members: [PetConfig]) {
        self.id = id
        self.name = name
        self.members = members
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "套组"
        members = try c.decodeIfPresent([PetConfig].self, forKey: .members) ?? []
    }

    /// 召出用的桌宠：新 id、link 指向本套组，超出上限的截掉
    public func summoned() -> [PetConfig] {
        members.prefix(AppConfig.maxPets).map { m in
            var p = m.sanitized()
            p.id = UUID().uuidString
            p.link = id
            return p
        }
    }
}

public struct UpdateConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var url: String
    /// 拉清单的间隔（秒）
    public var interval: Double

    public static let defaultURL = "https://rhodeside.rakko.cn"

    public init(enabled: Bool = true, url: String = UpdateConfig.defaultURL, interval: Double = 5) {
        self.enabled = enabled
        self.url = url
        self.interval = interval
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UpdateConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? d.interval
    }
}

public struct VoiceConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// 0…1
    public var volume: Double

    public init(enabled: Bool = true, volume: Double = 0.7) {
        self.enabled = enabled
        self.volume = min(max(volume, 0), 1)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VoiceConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        volume = min(max(try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume, 0), 1)
    }
}

public struct AuthConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Priestess 所在的 API 根地址
    public var api: String
    public var appID: String

    public static let defaultAPI = "https://api.rakko.cn"

    public init(enabled: Bool = false, api: String = AuthConfig.defaultAPI, appID: String = "rhodeside") {
        self.enabled = enabled
        self.api = api
        self.appID = appID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AuthConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        api = try c.decodeIfPresent(String.self, forKey: .api) ?? d.api
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? d.appID
    }
}

public struct PetConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// 模型文件夹名（先找用户导入的，再找 App 内置的）
    public var model: String
    public var outfit: String?
    public var group: String?
    /// 待机姿势的高度（pt）
    public var height: Double
    /// 步速倍率（动画步子和位移对不上时调）
    public var stride: Double
    /// 贴图已经是预乘 alpha（边缘发黑 / 发白时切换）
    public var pma: Bool
    /// 活动方式：全自动 / 一直走 / 原地不动
    public var activity: Activity
    /// 悬停透明：鼠标移到小人身上时变淡并让点击穿透（按住 ⌥ 暂时恢复）
    public var hoverFade: Bool
    /// 整体不透明度
    public var opacity: Double
    /// 战斗形态（正面 / 背面）待机时循环的动画；nil = 模型自己的待机动画
    public var pose: String?
    /// 联动：同一个非空 link 的桌宠会结伴走、互相找、一起反应（召出套组时 = 套组 id）
    public var link: String?

    public static let heightRange = 40.0...400.0
    public static let strideRange = 0.3...3.0
    public static let opacityRange = 0.2...1.0

    public init(
        id: String = UUID().uuidString,
        model: String = AppConfig.builtinModel,
        outfit: String? = "char_1038_whitw2",
        group: String? = "基建",
        height: Double = 120,
        stride: Double = 1,
        pma: Bool = false,
        activity: Activity = .auto,
        hoverFade: Bool = false,
        opacity: Double = 1,
        pose: String? = nil,
        link: String? = nil
    ) {
        self.id = id
        self.model = model
        self.outfit = outfit
        self.group = group
        self.height = height
        self.stride = stride
        self.pma = pma
        self.activity = activity
        self.hoverFade = hoverFade
        self.opacity = opacity
        self.pose = pose
        self.link = link
    }

    /// 把数值夹回合理范围（配置文件可能被手改过）
    public func sanitized() -> PetConfig {
        var c = self
        c.height = min(max(height.isFinite ? height : 120, Self.heightRange.lowerBound), Self.heightRange.upperBound)
        c.stride = min(max(stride.isFinite ? stride : 1, Self.strideRange.lowerBound), Self.strideRange.upperBound)
        c.opacity = min(max(opacity.isFinite ? opacity : 1, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        return c
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PetConfig()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        outfit = try c.decodeIfPresent(String.self, forKey: .outfit)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? d.height
        stride = try c.decodeIfPresent(Double.self, forKey: .stride) ?? d.stride
        pma = try c.decodeIfPresent(Bool.self, forKey: .pma) ?? d.pma
        // 不认识的值（以后加的模式、手改错了）按全自动处理，不让整份配置作废
        activity = (try? c.decodeIfPresent(String.self, forKey: .activity)).flatMap { Activity(rawValue: $0) } ?? d.activity
        hoverFade = try c.decodeIfPresent(Bool.self, forKey: .hoverFade) ?? d.hoverFade
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        pose = try? c.decodeIfPresent(String.self, forKey: .pose)
        link = try? c.decodeIfPresent(String.self, forKey: .link)
    }
}

public enum Activity: String, Codable, CaseIterable, Sendable {
    /// 自己决定走、坐、睡
    case auto
    /// 一直在走，到了就换个方向接着走
    case walk
    /// 原地不动（会待机、坐、睡；手动让它坐下 / 睡觉会一直保持）
    case stay
}

/// 行为调参：随前端一起发布（web 根目录的 rhodeside-tuning.json），热更新就能改，缺的字段用默认值
public struct Tuning: Codable, Equatable, Sendable {
    /// 各状态持续时间（秒，[最短, 最长]）
    public var idle: [Double]
    public var sit: [Double]
    public var sleep: [Double]
    /// 「一直走」模式下每段路之间歇多久
    public var walkPause: [Double]
    /// 全自动模式里待机结束后选下一个动作的概率（其余是继续待机）
    public var walkChance: Double
    public var sitChance: Double
    public var sleepChance: Double
    /// 在窗口上走路时走出边缘跳下去的概率
    public var edgeJumpChance: Double
    /// 悬停透明时的不透明度（再乘以桌宠自己的不透明度）
    public var hoverAlpha: Double
    /// 键鼠闲置多少秒后坐下 / 睡着（`Attention`；睡着还要没在放视频）
    public var restSit: Double
    public var restSleep: Double
    /// 鼠标离身体中心多远以内会转过来看（身高的倍数）
    public var lookRadius: Double
    /// 深夜的小时范围 [起, 止)，本地时间，可以跨零点（[23, 6]）
    public var nightHours: [Double]
    /// 深夜里自由活动时睡觉概率乘几倍
    public var nightSleepBoost: Double

    public init() {
        idle = [2.5, 6]
        sit = [5, 10]
        sleep = [8, 16]
        walkPause = [0.4, 1.2]
        walkChance = 0.6
        sitChance = 0.15
        sleepChance = 0.1
        edgeJumpChance = 0.2
        hoverAlpha = 0.25
        restSit = 60
        restSleep = 180
        lookRadius = 2.5
        nightHours = [0, 6]
        nightSleepBoost = 3
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Tuning()
        func range(_ k: CodingKeys, _ def: [Double]) -> [Double] {
            guard let v = try? c.decodeIfPresent([Double].self, forKey: k), v.count == 2, v.allSatisfy({ $0.isFinite && $0 >= 0 }), v[0] <= v[1] else { return def }
            return v
        }
        func unit(_ k: CodingKeys, _ def: Double) -> Double {
            guard let v = try? c.decodeIfPresent(Double.self, forKey: k), v.isFinite else { return def }
            return min(max(v, 0), 1)
        }
        idle = range(.idle, d.idle)
        sit = range(.sit, d.sit)
        sleep = range(.sleep, d.sleep)
        walkPause = range(.walkPause, d.walkPause)
        walkChance = unit(.walkChance, d.walkChance)
        sitChance = unit(.sitChance, d.sitChance)
        sleepChance = unit(.sleepChance, d.sleepChance)
        edgeJumpChance = unit(.edgeJumpChance, d.edgeJumpChance)
        hoverAlpha = unit(.hoverAlpha, d.hoverAlpha)
        func positive(_ k: CodingKeys, _ def: Double) -> Double {
            guard let v = try? c.decodeIfPresent(Double.self, forKey: k), v.isFinite, v > 0 else { return def }
            return v
        }
        restSit = positive(.restSit, d.restSit)
        restSleep = max(positive(.restSleep, d.restSleep), restSit)
        lookRadius = positive(.lookRadius, d.lookRadius)
        nightSleepBoost = positive(.nightSleepBoost, d.nightSleepBoost)
        if let v = try? c.decodeIfPresent([Double].self, forKey: .nightHours), v.count == 2, v.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 24 }) {
            nightHours = v
        } else {
            nightHours = d.nightHours
        }
    }

    /// 本地小时（0…24 的小数）落在深夜范围里
    public func isNight(hour h: Double) -> Bool {
        let a = nightHours[0], b = nightHours[1]
        return a <= b ? (h >= a && h < b) : (h >= a || h < b)
    }

    public static func load(from url: URL) -> Tuning {
        guard let data = try? Data(contentsOf: url), let t = try? JSONDecoder().decode(Tuning.self, from: data) else { return Tuning() }
        return t
    }
}

/// `positions.json`：每只桌宠上次的脚底位置（和 config.json 分开，免得走一步就改一次配置文件）
public struct SavedPositions: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        /// 叠在哪只头上（叠叠乐）
        public var on: String?
        public init(x: Double, y: Double, on: String? = nil) {
            self.x = x
            self.y = y
            self.on = on
        }
    }

    public var pets: [String: Point]

    public init(pets: [String: Point] = [:]) {
        self.pets = pets
    }

    public static func load(from url: URL) -> SavedPositions {
        guard let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(SavedPositions.self, from: data) else {
            return SavedPositions()
        }
        return p
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
