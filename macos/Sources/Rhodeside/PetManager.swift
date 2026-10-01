import AppKit
import PetCore

/// 管所有桌宠：配置、窗口扫描（每秒 10 次）、平台、全屏隐藏、位置存档、热更新（监听 Application Support）。
final class PetManager {
    let scheme = SchemeHandler()
    let importer = Importer()
    private(set) var config: AppConfig
    private(set) var pets: [Pet] = []
    private var positions: SavedPositions
    /// 重启前叠在别人头上、但下面那只还没载入的：上面那只 id → 下面那只 id，等下面那只放好了再把它放回去
    /// （只等 `restackWindow` 秒：下面那只的模型要下载很久的话，上面那只早就在地上待着了，不再突然瞬移）
    private var restack: [String: (on: String, at: CFTimeInterval)] = [:]
    private static let restackWindow: CFTimeInterval = 20
    private(set) var screens: [ScreenInfo] = []
    private(set) var windows: [WindowInfo] = []
    private(set) var platforms: [Platform] = []
    private(set) var fullscreen: Set<UInt32> = []
    private var scanFrames: [UInt32: CGRect] = [:]
    private var primaryHeight: CGFloat = 0
    private let scanner = BackgroundScanner()
    private let tracker = WindowTracker()
    private(set) var updater: RemoteUpdater!
    private(set) var auth: Auth!
    private(set) var logUploader: LogUploader!
    /// 每分钟采一次内存 / CPU，占用过大时写警告
    private(set) var monitor: ResourceMonitor!
    private var frozenUntil: CFTimeInterval = 0
    private var timers: [Timer] = []
    private var observers: [NSObjectProtocol] = []
    private var watcher: FileWatcher?
    private let webDebounce = Debouncer(0.4)
    private var lastScreenDesc = ""
    private let modelsDebounce = Debouncer(0.6)
    private let configDebounce = Debouncer(0.3)
    private var lastConfigData: Data?
    /// 远程更新自己换 web-dev 时会产生一串文件事件：这段时间里不再重复重载
    private var ignoreWebEventsUntil: CFTimeInterval = 0
    private(set) var userHidden = false
    /// 主窗口（侧栏：桌宠 / 模型库 / 设置）和首次启动的引导
    private(set) var settings: SettingsController?
    private(set) var welcome: SettingsController?
    private var pages: [SettingsController] { [settings, welcome].compactMap { $0 } }
    private(set) var tuning = Tuning()
    /// 套组联动（同一 link 的桌宠结伴走、互相找、一起反应）
    private let companions = Companions()
    private var companionsAt: CFTimeInterval = 0
    private let attention = Attention()
    private var attentionAt: CFTimeInterval = 0
    private var lastIdle: Double?
    /// 召出套组时还没下载、模型目录又还没拿到的模型名：目录到了再排队下载
    private var wantedModels: Set<String> = []
    /// 界面语言变了（AppDelegate 重建菜单）
    var onLanguageChange: (() -> Void)?

    init() {
        Paths.ensureDirectories()
        Importer.cleanupStale()
        let (cfg, result) = AppConfig.load(from: Paths.config)
        switch result {
        case .missing: Log.info("没有 config.json，用默认配置（一只内置的荒芜拉普兰德）")
        case .loaded: break
        case .broken(let backup): Log.warn("config.json 读不懂，原文件备份到 \(backup)，改用默认配置")
        }
        config = cfg
        config.pets = Array(Self.uniqueIDs(cfg.pets.map { $0.sanitized() }).prefix(AppConfig.maxPets))
        L10n.set(config.language)
        positions = SavedPositions.load(from: Paths.positions)
        tuning = Tuning.load(from: Paths.webRoot.appendingPathComponent("rhodeside-tuning.json"))
        saveConfig()
        auth = Auth(config: config.auth)
        auth.onChange = { [weak self] in
            self?.pushState()
            // 登录状态变了：丢掉旧票据（换账号、退出后不再用），马上检查一次
            self?.updater.resetTicket()
            self?.updater.check()
        }
        updater = RemoteUpdater(config: config.updates, auth: auth)
        updater.canRestart = { [weak self] in !(self?.pets.contains { $0.isPressed } ?? false) }
        updater.onModelsChanged = { [weak self] name in
            for pet in self?.pets ?? [] { pet.modelUpdated(name) }
            self?.modelsDidChange()
        }
        updater.onApplied = { [weak self] build in
            self?.ignoreWebEventsUntil = CACurrentMediaTime() + 1.5
            self?.reloadWeb(reason: "远程热更新 build \(build)")
        }
        updater.onChange = { [weak self] in
            self?.requestWantedModels()
            self?.pushState()
        }
        logUploader = LogUploader(updater: updater, auth: auth)
        logUploader.onChange = { [weak self] in self?.pushState() }
        logUploader.start()
        monitor = ResourceMonitor { [weak self] in self?.monitoredProcesses() ?? [] }
    }

    func start() {
        rescan()
        // 100ms 一跳，平时每 3 跳扫一次（约 4Hz）；有小人在下落或被拖着时每跳都扫，落点才准
        var tick = 0
        let scan = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            tick += 1
            let urgent = self.pets.contains { $0.brain.behavior == .fall || $0.brain.behavior == .held }
            if urgent || tick % 3 == 0 { self.rescan() }
            self.stepCompanions()
            self.stepAttention()
        }
        let save = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.savePositions() }
        for t in [scan, save] { RunLoop.main.add(t, forMode: .common) }
        timers = [scan, save]

        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // 程序坞、菜单栏变化也会发这个通知：只在屏幕排布真的变了时记日志
            let desc = NSScreen.screens.map { "\($0.localizedName) \(NSStringFromRect($0.frame))" }.joined(separator: "，")
            if desc != self?.lastScreenDesc { self?.lastScreenDesc = desc; Log.info("屏幕变了：\(desc)") }
            self?.rescan()
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // 切桌面空间的一瞬间窗口列表是乱的：暂停物理半秒，免得小人误以为脚下的窗口没了
            self?.frozenUntil = CACurrentMediaTime() + 0.5
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rescan()
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            for p in self?.pets ?? [] { p.setSuspended(true) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            for p in self?.pets ?? [] { p.setSuspended(false) }
        })
        watcher = FileWatcher(path: Paths.support.path) { [weak self] paths in self?.filesChanged(paths) }

        for pc in config.pets { pets.append(Pet(config: pc, manager: self)) }
        updater.apply(config.updates)
        Log.info("网页：\(Paths.usingDevWeb ? "开发版 web-dev（热更新）" : "App 内置")；\(pets.count) 只桌宠；\(NSScreen.screens.count) 块屏幕")
        monitor.start()
    }

    func shutdown() {
        monitor.stop()
        savePositions()
        for t in timers { t.invalidate() }
        for p in pets { p.close() }
    }

    var frozen: Bool { CACurrentMediaTime() < frozenUntil }

    /* ---------------------------------------------------------------- 世界 */

    /// 屏幕信息在主线程读（NSScreen 不保证线程安全），窗口列表和平台在后台算，算完回主线程换上
    func rescan() {
        primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        scanner.scan(screens: NSScreen.screens.map(\.info), primaryHeight: primaryHeight, config: config) { [weak self] r in
            self?.applyScan(r)
        }
    }

    private func applyScan(_ r: BackgroundScanner.Result) {
        screens = r.screens
        windows = r.windows
        scanFrames = r.frames
        platforms = r.platforms
        fullscreen = r.fullscreen
        for pet in pets { pet.setHidden(shouldHide(pet)) }
    }

    /// 给某只桌宠的世界（含别的小人的头顶）：脚下那个窗口由 WindowTracker 在后台高频查位置，平台跟着平移（全量扫描每秒只有 10 次，跟随会一顿一顿）
    func world(for pet: Pet) -> World {
        var ps = platforms
        if case .some(.window(let id)) = pet.brain.support.kind {
            switch tracker.state(of: id, primaryHeight: primaryHeight) {
            case .at(let cur):
                if let then = scanFrames[id], cur != then {
                    let dx = Double(cur.minX - then.minX)
                    let dy = Double(cur.maxY - then.maxY)
                    for i in ps.indices where ps[i].kind == .window(id: id) {
                        ps[i].segment.y += dy
                        ps[i].segment.minX += dx
                        ps[i].segment.maxX += dx
                        ps[i].anchorX = Double(cur.minX)
                    }
                }
            case .gone:
                if !frozen { ps.removeAll { $0.kind == .window(id: id) } } // 关了 / 最小化 / 去了别的桌面空间
            case .unknown:
                break // 刚站上去，后台还没查到：先按全量扫描的数据
            }
        }
        ps += Stacking.heads(for: pet.config.id, pets: pets.map(\.head), screens: screens) // 叠叠乐：别的小人的头顶
        return World(platforms: ps, screens: screens)
    }

    /// 点所在的屏幕；不在任何屏幕里就取横向最近的，再不行用主屏
    func screenFrame(near p: CGPoint) -> CGRect {
        let list = screens.isEmpty ? NSScreen.screens.map(\.info) : screens
        if let s = list.first(where: { $0.frame.contains(p) }) { return s.frame }
        let dist = { (r: CGRect) -> CGFloat in max(r.minX - p.x, 0, p.x - r.maxX) + max(r.minY - p.y, 0, p.y - r.maxY) }
        return list.min { dist($0.frame) < dist($1.frame) }?.frame ?? NSScreen.screens.first?.frame ?? .zero
    }

    private func shouldHide(_ pet: Pet) -> Bool {
        if userHidden { return true }
        guard !fullscreen.isEmpty, let s = screens.first(where: { $0.frame.contains(baseFoot(of: pet)) }) else { return false }
        return fullscreen.contains(s.id)
    }

    /// 叠着的一摞按最下面那只的脚算在哪块屏幕（一起藏、一起出来；塔顶伸出屏幕也不会漏掉）
    private func baseFoot(of pet: Pet) -> CGPoint {
        var cur = pet
        for _ in 0..<16 {
            guard let id = cur.brain.below, let lower = pets.first(where: { $0.config.id == id }) else { break }
            cur = lower
        }
        return cur.brain.foot
    }

    func petVisibilityMayChange(_ pet: Pet) {
        pet.setHidden(shouldHide(pet))
    }

    func setUserHidden(_ h: Bool) {
        userHidden = h
        for pet in pets { pet.setHidden(shouldHide(pet)) }
        pushState()
    }

    /* ---------------------------------------------------------------- 位置 */

    func initialFoot(for pet: Pet, drop: Bool) -> CGPoint {
        if !drop, let p = positions.pets[pet.config.id] { return CGPoint(x: p.x, y: p.y) }
        return spawnPoint(index: pets.firstIndex { $0 === pet } ?? pets.count, drop: drop)
    }

    /// 主屏中间一带；drop = 从上面掉下来
    func spawnPoint(index: Int, drop: Bool) -> CGPoint {
        guard let s = NSScreen.screens.first else { return .zero }
        let vf = s.visibleFrame
        let x = vf.midX + CGFloat((index % 5) - 2) * 140
        return CGPoint(x: x, y: drop ? vf.maxY - 80 : vf.minY)
    }

    /* ---------------------------------------------------------------- 叠叠乐 */

    /// 刚放到屏幕上（第一次载入完）：重启前叠着的放回去
    func petPlaced(_ pet: Pet) {
        let id = pet.config.id
        let now = CACurrentMediaTime()
        if !pet.dropOnPlace, let on = positions.pets[id]?.on {
            if let lower = pets.first(where: { $0.config.id == on && $0.placed }) { stack(pet, on: lower) } else { restack[id] = (on, now) }
        }
        for (top, r) in restack where r.on == id {
            restack[top] = nil
            guard now - r.at < Self.restackWindow, let t = pets.first(where: { $0.config.id == top }), t.brain.behavior != .held else { continue }
            stack(t, on: pet)
        }
    }

    /// 被拎起来了：不再等着放回去；叠在它上面的一起提到前面
    func petGrabbed(_ pet: Pet) {
        restack[pet.config.id] = nil
        raiseStack(on: pet)
    }

    /// 从下面那只头顶上方一点落下去（横向按上次存的相对位置，夹在头顶范围里；同一个头上的几只不会叠成一只）
    private func stack(_ top: Pet, on lower: Pet) {
        let b = lower.brain
        var dx = 0.0
        if let t = positions.pets[top.config.id], let l = positions.pets[lower.config.id] { dx = t.x - l.x }
        let half = b.params.halfWidth * Stacking.widthRatio
        dx = min(max(dx, -half), half)
        top.brain.teleport(to: CGPoint(x: Double(b.foot.x) + dx, y: Double(b.foot.y) + b.headHeight + 1), stack: true)
    }

    /// 叠在 `lower` 上面的窗口排在它前面（上面的小人脚踩在下面那只头上，要画在它前面）
    func raiseStack(on lower: Pet, depth: Int = 0) {
        guard depth < 16 else { return }
        for p in pets where p !== lower && !p.hidden && p.brain.below == lower.config.id {
            p.window.panel.order(.above, relativeTo: lower.window.panel.windowNumber)
            raiseStack(on: p, depth: depth + 1)
        }
    }

    func savePositions() {
        let ids = Set(config.pets.map(\.id))
        var p = SavedPositions(pets: positions.pets.filter { ids.contains($0.key) })
        for pet in pets where pet.placed {
            p.pets[pet.config.id] = .init(x: (Double(pet.brain.foot.x) * 10).rounded() / 10, y: (Double(pet.brain.foot.y) * 10).rounded() / 10,
                                          on: pet.brain.below)
        }
        guard p != positions else { return }
        positions = p
        do { try p.save(to: Paths.positions) } catch { Log.error("存 positions.json 失败：\(error)") }
    }

    /* ---------------------------------------------------------------- 配置 */

    private func saveConfig() {
        do {
            let data = try config.encoded()
            guard data != lastConfigData else { return }
            lastConfigData = data
            try data.write(to: Paths.config, options: .atomic)
        } catch {
            Log.error("存 config.json 失败：\(error)")
        }
    }

    private static func uniqueIDs(_ list: [PetConfig]) -> [PetConfig] {
        var seen = Set<String>()
        return list.map { pc in
            var c = pc
            if seen.contains(c.id) { c.id = UUID().uuidString }
            seen.insert(c.id)
            return c
        }
    }

    /// 换一份配置：桌宠按 id 增删改，全局开关立即生效，存盘，通知设置页
    func apply(_ newConfig: AppConfig, reason: String) {
        var new = newConfig
        new.pets = Array(Self.uniqueIDs(new.pets.map { $0.sanitized() }).prefix(AppConfig.maxPets))
        let old = config
        config = new
        let ids = Set(new.pets.map(\.id))
        for pet in pets where !ids.contains(pet.config.id) {
            pet.close()
            positions.pets[pet.config.id] = nil
        }
        var next: [Pet] = []
        for pc in new.pets {
            if let pet = pets.first(where: { $0.config.id == pc.id }) {
                pet.update(config: pc)
                next.append(pet)
            } else {
                let pet = Pet(config: pc, manager: self)
                pet.dropOnPlace = positions.pets[pc.id] == nil
                next.append(pet)
            }
        }
        pets = next
        if old.hideInFullscreen != new.hideInFullscreen {
            for pet in pets { pet.window.setFullscreenAuxiliary(!new.hideInFullscreen) }
        }
        if old.voice != new.voice {
            for pet in pets { pet.applyVoice() }
        }
        if old.language != new.language {
            L10n.set(new.language)
            onLanguageChange?()
            for p in pages { p.applyLanguage() }
        }
        auth.apply(new.auth)
        updater.apply(new.updates)
        if old.walkOnWindows != new.walkOnWindows || old.ignoredApps != new.ignoredApps || old.hideInFullscreen != new.hideInFullscreen {
            rescan()
        }
        saveConfig()
        savePositions()
        pushState()
        Log.info("配置已更新（\(reason)）：\(pets.count) 只桌宠")
    }

    func updatePet(_ id: String, patch: [String: Any]) {
        guard let i = config.pets.firstIndex(where: { $0.id == id }) else { return }
        var p = patch
        p["id"] = nil
        guard let pc = merged(config.pets[i], patch: p) else {
            Log.warn("改桌宠 \(id) 的参数不对：\(patch)")
            return
        }
        var c = config
        c.pets[i] = pc
        apply(c, reason: "改桌宠 \(id.prefix(6))：\(patch.keys.sorted().joined(separator: ","))")
    }

    @discardableResult
    func addPet(model: String?) -> Bool {
        guard config.pets.count < AppConfig.maxPets else { return false }
        var c = config
        if let m = model, m != AppConfig.builtinModel {
            c.pets.append(PetConfig(model: m, outfit: nil, group: nil))
        } else {
            c.pets.append(PetConfig())
        }
        apply(c, reason: "添加桌宠")
        return true
    }

    func removePet(_ id: String) {
        var c = config
        c.pets.removeAll { $0.id == id }
        apply(c, reason: "收起桌宠 \(id.prefix(6))")
    }

    func updateGlobal(patch: [String: Any]) {
        var p = patch
        p["pets"] = nil
        p["teams"] = nil
        p["version"] = nil
        guard let c = merged(config, patch: p) else {
            Log.warn("全局设置参数不对：\(patch)")
            return
        }
        apply(c, reason: "全局设置：\(patch.keys.sorted().joined(separator: ","))")
    }

    /* ---------------------------------------------------------------- 套组 */

    /// 协调同一 link 的桌宠（没载入完、隐藏着的不算）
    private func stepCompanions() {
        let now = CACurrentMediaTime()
        let dt = companionsAt == 0 ? 0 : min(now - companionsAt, 0.5)
        companionsAt = now
        guard !frozen else { return }
        let members = pets.filter { $0.info != nil && !$0.hidden }.map {
            Companions.Member(id: $0.config.id, link: $0.config.link, brain: $0.brain, world: world(for: $0))
        }
        companions.step(dt: dt, members: members)
    }

    /* ---------------------------------------------------------------- 看鼠标 / 作息 */

    private func stepAttention() {
        let now = CACurrentMediaTime()
        let dt = attentionAt == 0 ? 0 : min(now - attentionAt, 0.5)
        attentionAt = now
        guard !frozen else { return }
        let cal = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let idle = UserActivity.idleSeconds()
        lastIdle = idle
        let input = Attention.Input(
            // 进程间调用：只在快要睡着时才查
            idle: idle, mouse: UserActivity.mouse(),
            screenKeptAwake: config.restWhenIdle && (idle ?? 0) >= tuning.restSleep ? UserActivity.screenKeptAwake() : nil, hour: Double(cal.hour ?? 12) + Double(cal.minute ?? 0) / 60,
            watchMouse: config.watchMouse, restWhenIdle: config.restWhenIdle
        )
        let shown = pets.filter { $0.info != nil && !$0.hidden }
        let before = attention.level
        let greeter = attention.step(dt: dt, input: input, members: shown.map { Attention.Member(id: $0.config.id, brain: $0.brain) }, tuning: tuning)
        if attention.level != before {
            Log.info("作息：\(before.rawValue) → \(attention.level.rawValue)（闲置 \(Int(idle ?? 0)) 秒\(input.screenKeptAwake == true ? "，有程序不让屏幕熄灭" : "")）")
        }
        if let id = greeter, let pet = shown.first(where: { $0.config.id == id }) { pet.greet() }
    }

    private func teamName(_ raw: String?, _ c: AppConfig) -> String {
        let name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return String(name.prefix(40)) }
        var n = c.teams.count + 1
        let base = tr("套组", "套組", "Squad")
        while c.teams.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }

    /// 把当前桌面上的桌宠存成一个新套组；当前这些桌宠随即联动起来
    @discardableResult
    func saveTeam(name: String?) -> Bool {
        guard !config.pets.isEmpty else { return false }
        var c = config
        let team = Team(name: teamName(name, c), members: c.pets.map { var p = $0; p.link = nil; return p })
        c.teams.append(team)
        for i in c.pets.indices { c.pets[i].link = team.id }
        apply(c, reason: "存套组「\(team.name)」（\(team.members.count) 只）")
        return true
    }

    /// 把当前桌面上的桌宠写回某个套组（召出后改了大小、时装、加减了成员）
    func overwriteTeam(_ id: String) {
        guard let i = config.teams.firstIndex(where: { $0.id == id }), !config.pets.isEmpty else { return }
        var c = config
        c.teams[i].members = c.pets.map { var p = $0; p.link = nil; return p }
        for j in c.pets.indices { c.pets[j].link = id }
        apply(c, reason: "更新套组「\(c.teams[i].name)」")
    }

    /// 召出套组：替换桌面上的全部桌宠（从主屏中间并排掉下来）；还没下载的在线模型排队下载
    func summonTeam(_ id: String) {
        guard let team = config.teams.first(where: { $0.id == id }), !team.members.isEmpty else { return }
        var c = config
        c.pets = team.summoned()
        wantedModels.formUnion(c.pets.map(\.model).filter { ModelLibrary.find($0) == nil })
        apply(c, reason: "召出套组「\(team.name)」")
        requestWantedModels()
    }

    /// 把 wantedModels 里模型目录认得的排队下载（目录还没拿到就等下次 onChange）
    private func requestWantedModels() {
        guard !wantedModels.isEmpty, let catalog = updater.catalog else { return }
        let found = catalog.models.filter { wantedModels.contains($0.name) }
        wantedModels.subtract(found.map(\.name))
        // 目录里压根没有的（导入的模型被删了之类）别一直惦记
        wantedModels.formIntersection(catalog.models.map(\.name))
        updater.requestModels(found.map(\.id))
    }

    func renameTeam(_ id: String, name: String?) {
        guard let i = config.teams.firstIndex(where: { $0.id == id }) else { return }
        var c = config
        c.teams[i].name = teamName(name, c)
        apply(c, reason: "套组改名「\(c.teams[i].name)」")
    }

    /// 删掉套组；桌面上从它召出来的桌宠留着，但不再联动
    func deleteTeam(_ id: String) {
        guard let team = config.teams.first(where: { $0.id == id }) else { return }
        var c = config
        c.teams.removeAll { $0.id == id }
        for i in c.pets.indices where c.pets[i].link == id { c.pets[i].link = nil }
        apply(c, reason: "删除套组「\(team.name)」")
    }

    func summon(_ id: String?) {
        for (i, pet) in pets.enumerated() where id == nil || pet.config.id == id {
            pet.summon(to: spawnPoint(index: i, drop: true))
        }
    }

    /* ---------------------------------------------------------------- 热更新 */

    private func filesChanged(_ paths: [String]) {
        let root = Paths.support.standardizedFileURL.path
        var web = false, models = false, cfg = false
        for p in paths where p.hasPrefix(root) {
            let rel = p.dropFirst(root.count)
            if rel.hasPrefix("/web-dev.incoming") || rel.hasPrefix("/web-dev.replaced") { continue } // 远程更新自己会触发重载
            if rel.hasPrefix("/web-dev") { web = true }
            else if rel.hasPrefix("/models/") || rel == "/models" { models = true }
            else if rel == "/config.json" { cfg = true }
        }
        if web, CACurrentMediaTime() < ignoreWebEventsUntil { web = false }
        if web { webDebounce.call { [weak self] in self?.reloadWeb(reason: "网页热更新") } }
        if models { modelsDebounce.call { [weak self] in self?.modelsDidChange() } }
        if cfg { configDebounce.call { [weak self] in self?.configFileChanged() } }
    }

    func reloadWeb(reason: String) {
        webDebounce.cancel()
        Paths.refreshWebRoot()
        loadTuning()
        Log.info("\(reason)：重载 \(pets.count) 只桌宠\(pages.isEmpty ? "" : " + \(pages.count) 个窗口")（网页：\(Paths.usingDevWeb ? "开发版 web-dev" : "App 内置")）")
        for pet in pets { pet.loadPage() }
        for p in pages { p.loadPage() }
    }

    func modelsDidChange() {
        for pet in pets { pet.modelFilesMaybeChanged() }
        pushState()
    }

    private func configFileChanged() {
        guard let data = try? Data(contentsOf: Paths.config), data != lastConfigData else { return }
        do {
            let c = try JSONDecoder().decode(AppConfig.self, from: data)
            lastConfigData = data
            apply(c, reason: "config.json 被手动改了")
        } catch {
            Log.warn("config.json 改得读不懂了，先不管（改好保存就会生效）：\(error)")
        }
    }

    /* ---------------------------------------------------------------- 设置窗口 */

    /// 行为调参随前端发布（web 根目录的 rhodeside-tuning.json）：前端热更新后重新读
    private func loadTuning() {
        let t = Tuning.load(from: Paths.webRoot.appendingPathComponent("rhodeside-tuning.json"))
        guard t != tuning else { return }
        tuning = t
        for pet in pets { pet.applyTuning(t) }
        Log.info("行为参数已更新")
    }

    /// 打开主窗口；tab = pets / models / settings（nil：新开停在桌宠页，已开着就不切）
    func openSettings(tab: String? = nil) {
        if let s = settings {
            if let tab { s.navigate(tab) }
        } else {
            settings = SettingsController(manager: self, page: .settings, tab: tab)
        }
        settings?.show()
    }

    /// 首次启动的引导：登录（下载模型）或跳过
    func openWelcome() {
        if welcome == nil { welcome = SettingsController(manager: self, page: .welcome) }
        welcome?.show()
    }

    /// 引导页「完成」：ids = 模型库里勾选的。开始下载，并让还没有模型的桌宠用勾选的第一个
    func finishOnboarding(download ids: [String] = []) {
        updater.requestModels(ids)
        var c = config
        c.onboarded = true
        let names = ids.compactMap { id in updater.catalog?.models.first { $0.id == id }?.name }
        if let first = names.first {
            for i in c.pets.indices where ModelLibrary.find(c.pets[i].model) == nil && !names.contains(c.pets[i].model) {
                c.pets[i].model = first
                c.pets[i].outfit = nil
                c.pets[i].group = nil
            }
        }
        apply(c, reason: "完成引导")
        welcome?.window.close()
    }





    /// 关了就释放（连网页进程一起）。同步置空：马上再打开时建一个新窗口，不复用已拆掉消息通道的旧页面
    func pageClosed(_ c: SettingsController) {
        // 关掉引导窗口 = 跳过（不然每次启动都会再弹）
        if welcome === c, !config.onboarded {
            var cfg = config
            cfg.onboarded = true
            apply(cfg, reason: "关闭引导")
        }
        if settings === c { settings = nil }
        if welcome === c { welcome = nil }
    }

    /// rhodeside://debug/eval-page?page=settings|welcome&js=…：结果写日志
    func debugEvalPage(_ page: String, js: String) {
        let byName = ["settings": settings, "welcome": welcome]
        guard let c = byName[page] ?? nil else { return Log.warn("\(page) 窗口没开") }
        c.webView.evaluateJavaScript(js) { result, error in
            Log.info("[\(page)] eval → \(error.map { "错误：\($0.localizedDescription)" } ?? String(describing: result ?? "nil"))")
        }
    }

    func pushState() {
        guard !pages.isEmpty else { return }
        let state = settingsState()
        for p in pages { p.webView.send(state) }
    }

    func petChanged(_ pet: Pet) {
        pushState()
    }

    func settingsState() -> [String: Any] {
        let login = LoginItem.state
        return [
            "type": "state",
            "version": Paths.version,
            "webDev": Paths.usingDevWeb,
            "maxPets": AppConfig.maxPets,
            "builtinModel": AppConfig.builtinModel,
            "defaultIgnoredApps": AppConfig.defaultIgnoredApps,
            "config": jsonObject(config),
            "models": ModelLibrary.all().map { ["name": $0.name, "builtin": $0.builtin, "files": $0.files] as [String: Any] },
            "pets": pets.map(\.summary),
            "loginItem": ["enabled": login.enabled, "detail": login.detail] as [String: Any],
            "hidden": userHidden,
            "updates": updater.status,
            "auth": auth.status,
            "catalog": updater.modelStatus,
            "logUpload": logUploader.status,
            "appBuild": NSNumber(value: Paths.appBuild),
            // 「跟随系统」时网页按这个定语言（WebView 的 navigator.languages 不一定是系统的）
            "systemLanguages": Locale.preferredLanguages,
        ]
    }

    /* ---------------------------------------------------------------- 调试 */

    func debugState() -> [String: Any] {
        [
            "time": ISO8601DateFormatter().string(from: Date()),
            "version": Paths.version,
            "webRoot": Paths.usingDevWeb ? "web-dev" : "bundle",
            "pid": Int(getpid()),
            "memoryMB": memoryReport(),
            "frozen": frozen,
            "idleSeconds": lastIdle ?? -1,
            "restLevel": attention.level.rawValue,
            "screenKeptAwake": UserActivity.screenKeptAwake() ?? NSNull(),
            "mouse": ["x": Double(NSEvent.mouseLocation.x), "y": Double(NSEvent.mouseLocation.y)],
            "userHidden": userHidden,
            "loginItem": LoginItem.state.detail,
            "screens": screens.map { ["id": Int($0.id), "frame": rectDict($0.frame), "visibleFrame": rectDict($0.visibleFrame)] as [String: Any] },
            "fullscreen": fullscreen.map { Int($0) },
            "windows": windows.map { ["id": Int($0.id), "owner": $0.owner, "frame": rectDict($0.frame)] as [String: Any] },
            "platforms": platforms.map { ["kind": String(describing: $0.kind), "y": $0.segment.y, "minX": $0.segment.minX, "maxX": $0.segment.maxX] as [String: Any] },
            "pets": pets.map(\.state),
            "config": jsonObject(config),
        ]
    }

    /// 资源监控看哪些进程：App 自己、WebKit 的 GPU 进程（所有网页共用一个）、每只桌宠和每个窗口的网页进程
    private func monitoredProcesses() -> [ResourceMonitor.Proc] {
        var out = [ResourceMonitor.Proc(name: "App", kind: .app, pid: getpid())]
        let views = pets.map(\.window.webView) + pages.map(\.webView)
        if let gpu = views.lazy.compactMap(\.gpuProcessID).first { out.append(.init(name: "GPU", kind: .gpu, pid: gpu)) }
        for pet in pets {
            if let pid = pet.window.webView.webProcessID { out.append(.init(name: pet.monitorName, kind: .web, pid: pid)) }
        }
        for page in pages {
            if let pid = page.webView.webProcessID { out.append(.init(name: page.monitorName, kind: .web, pid: pid)) }
        }
        return out
    }

    func memoryReport() -> [String: Any] {
        var web: [String: Any] = [:]
        for pet in pets {
            if let pid = pet.window.webView.webProcessID { web[pet.short] = Memory.footprintMB(pid) ?? NSNull() }
        }
        if let pid = settings?.webView.webProcessID { web["settings"] = Memory.footprintMB(pid) ?? NSNull() }
        return ["app": Memory.footprintMB(getpid()) ?? NSNull(), "web": web]
    }

    func snapshotAll() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let tag = f.string(from: Date())
        writeJSON(debugState(), to: Paths.snapshots.appendingPathComponent("\(tag)-state.json"))
        for pet in pets { pet.requestSnapshot(tag: tag) }
        Log.info("调试快照 \(tag)：\(pets.count) 只（~/Library/Logs/Rhodeside/snapshots）")
        pruneSnapshots()
    }

    func writeState() {
        let s = debugState()
        writeJSON(s, to: Paths.logs.appendingPathComponent("state.json"))
        Log.info("状态 → state.json；内存（MB）：\(s["memoryMB"] ?? "?")")
    }

    private func writeJSON(_ obj: Any, to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func pruneSnapshots() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.snapshots, includingPropertiesForKeys: nil) else { return }
        let sorted = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for f in sorted.dropFirst(60) { try? fm.removeItem(at: f) }
    }
}
