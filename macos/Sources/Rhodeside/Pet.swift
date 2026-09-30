import AppKit
import PetCore
import QuartzCore
import WebKit

/// 网页 `loaded` 回来的模型信息（尺寸都已经是 pt）
struct LoadedInfo {
    var model: String
    var outfit: String
    var group: String
    var sets: [[String: String]]
    var roles: Roles
    var animations: [String: Double]
    var layout: PetLayout
    /// 待机姿势的包围盒，以脚底为原点
    var rest: CGRect
}

/// 一只桌宠：原生层管位置、行为和鼠标，网页（pet.html）只按命令画。
final class Pet: NSObject {
    private(set) var config: PetConfig
    let window: PetWindow
    let brain: Brain
    private unowned let manager: PetManager

    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private(set) var info: LoadedInfo?
    private(set) var lastError: String?
    /// 已经放到屏幕上了（第一次 loaded 之后）
    private(set) var placed = false
    /// 放到屏幕上时从天上掉下来（运行中新加的桌宠）
    var dropOnPlace = false
    private var loadedFiles: [String] = []
    /// 当前帧小人的包围盒（窗口坐标，y 向上），网页约 10 次/秒报一次
    private var bounds: CGRect?
    /// 网页量包围盒那一帧小人的 x（窗口内坐标）：走路时按现在的位置平移包围盒，前缘不会点不到
    private var boundsX: CGFloat?
    private var sentAnim = -1
    private var sentDir = 0
    /// 最近一次发给网页的脚底位置（窗口内横坐标）、速度、窗口宽度
    private var sentPosX: CGFloat = -1
    private var sentPosVX: Double = .nan
    private var sentPosW: CGFloat = 0
    private var faceSentAt: CFTimeInterval = 0
    private(set) var hidden = true
    private var wantHidden = false
    private var press: Press?
    private var hitSeq = 0
    private var hitInFlight: (id: Int, at: CFTimeInterval)?
    private var hitAnswer: (point: CGPoint, inside: Bool, at: CFTimeInterval)?
    private var crashes: [Date] = []
    private var rateClass = -1
    private var webFPS = -1
    private var fellBack = false
    /// 悬停透明：当前的淡出程度（0 = 正常，1 = 完全淡到 hoverAlpha），逐帧逼近目标
    private var fade: Double = 0
    private var reportedBehavior: Behavior?
    /// 战斗形态的套组动作（控制面板的按钮）；基建形态是空的
    private(set) var combos: [Combo] = []
    /// 帧间隔统计（调试用，debug/state 读完清零）：帧数、超过 1.5 倍预期间隔的次数、最大间隔
    private var tickCount = 0
    private var tickLate = 0
    private var tickMaxGap: CFTimeInterval = 0

    private struct Press {
        var start: CGPoint
        var grab: CGVector
        var moved = false
        var samples: [(t: CFTimeInterval, p: CGPoint)]
    }

    var short: String { String(config.id.prefix(6)) }

    init(config: PetConfig, manager: PetManager) {
        self.config = config.sanitized()
        self.manager = manager
        brain = Brain(params: PetParams(height: self.config.height, halfWidth: self.config.height * 0.2, stride: self.config.stride), foot: .zero)
        brain.tuning = manager.tuning
        brain.setActivity(self.config.activity)
        let proxy = WeakScriptHandler()
        window = PetWindow(configuration: WebBridge.configuration(handler: proxy, scheme: manager.scheme))
        super.init()
        proxy.target = self
        window.catcher.delegate = self
        window.webView.navigationDelegate = self
        window.setFullscreenAuxiliary(!manager.config.hideInFullscreen)
        if let view = window.panel.contentView {
            let l = view.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        loadPage()
    }

    func close() {
        link?.invalidate() // CADisplayLink 强引用 target，不 invalidate 就一直不释放
        link = nil
        NotificationCenter.default.removeObserver(self)
        window.webView.stopLoading()
        window.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        window.panel.orderOut(nil)
        window.panel.close()
    }

    /* ---------------------------------------------------------------- 网页 */

    /// 重新加载 pet.html（热更新 / 崩溃恢复）。位置和行为在原生层，不受影响
    func loadPage() {
        window.webView.load(URLRequest(url: SchemeHandler.url("pet.html")))
    }

    private func sendLoad() {
        var name = config.model
        if ModelLibrary.find(name) == nil, name != AppConfig.builtinModel {
            lastError = "未找到模型「\(name)」，改用默认模型"
            Log.warn("[\(short)] \(lastError!)")
            name = AppConfig.builtinModel
        }
        guard let model = ModelLibrary.find(name) else {
            lastError = ModelStore.isDismissed(name: config.model)
                ? "模型「\(config.model)」已删除，可以在模型库里重新下载"
                : "模型「\(config.model)」还没下载，可以在模型库里下载"
            Log.info("[\(short)] \(lastError!)")
            // 模型被删了：之前画着的也收起来（不能继续显示已删除的模型）
            loadedFiles = []
            if info != nil {
                info = nil
                applyVisibility()
            }
            manager.petChanged(self)
            return
        }
        loadedFiles = model.files
        var msg: [String: Any] = ["type": "load", "base": "./models/", "files": model.files, "height": config.height, "pma": config.pma, "voice": voiceMessage()]
        if name == config.model {
            if let o = config.outfit { msg["outfit"] = o }
            if let g = config.group { msg["group"] = g }
        } else {
            msg["group"] = "基建"
        }
        msg["model"] = name
        window.webView.send(msg)
    }

    /// 语音开关 / 音量（全局设置）：页面拿它决定播不播、多大声
    func voiceMessage() -> [String: Any] {
        let v = manager.config.voice
        return ["enabled": v.enabled, "volume": v.volume]
    }

    func applyVoice() {
        var msg = voiceMessage()
        msg["type"] = "voice"
        window.webView.send(msg)
    }

    /// 模型目录变了：这只用的模型文件有变化（或被删了）才重新载入
    func modelFilesMaybeChanged() {
        if ModelLibrary.find(config.model)?.files != loadedFiles { sendLoad() }
    }

    /// 在线模型换了新版本（文件名可能没变）：用它的桌宠强制重载
    func modelUpdated(_ name: String) {
        if config.model == name || info?.model == name { sendLoad() }
    }

    func update(config new: PetConfig) {
        let new = new.sanitized()
        let old = config
        config = new
        if old.model != new.model || old.outfit != new.outfit || old.group != new.group || old.pma != new.pma {
            sendLoad()
        } else if old.height != new.height {
            window.webView.send(["type": "scale", "height": new.height])
        }
        if old.stride != new.stride { brain.params.stride = new.stride }
        if old.activity != new.activity { brain.setActivity(new.activity) }
        if old.pose != new.pose { brain.pose = validPose(new.pose) }
    }

    /// 配置里的动作在当前模型里没有（换了模型 / 时装）：用模型自己的待机
    private func validPose(_ p: String?) -> String? {
        guard let p, info?.animations[p] != nil else { return nil }
        return p
    }

    /// 控制面板的套组按钮
    @discardableResult
    func playCombo(_ id: String) -> Bool {
        guard let c = combos.first(where: { $0.id == id }) else { return false }
        return brain.play(c.steps)
    }

    func applyTuning(_ t: Tuning) { brain.tuning = t }

    /// 控制面板的动作按钮
    @discardableResult
    func perform(_ b: Behavior) -> Bool { brain.perform(b) }

    private func handleLoaded(_ b: Body) {
        guard let layout = parseLayout(b.dict("layout")), let rest = b.rect("rest") else {
            Log.error("[\(short)] loaded 消息缺 layout/rest")
            return
        }
        let r = b.dict("roles")
        let roles = Roles(idle: r?.string("idle"), move: r?.string("move"), interact: r?.string("interact"), sit: r?.string("sit"), sleep: r?.string("sleep"))
        var anims: [String: Double] = [:]
        for a in b.array("animations") {
            if let d = a as? [String: Any], let n = d["name"] as? String { anims[n] = (d["duration"] as? NSNumber)?.doubleValue ?? 0 }
        }
        let sets = b.array("sets").compactMap { $0 as? [String: String] }
        let model = b.string("model") ?? config.model
        info = LoadedInfo(model: model, outfit: b.string("outfit") ?? "", group: b.string("group") ?? "", sets: sets, roles: roles, animations: anims, layout: layout, rest: rest)
        if model == config.model { lastError = nil }
        brain.params = PetParams(height: Double(rest.height), halfWidth: max(10, Double(rest.width) / 2), stride: config.stride, roles: roles,
                                 interactDuration: anims[roles.interact ?? ""] ?? 1)
        // 正面 / 背面是战斗模型：不走动，待机循环控制面板选的动作，点一下播攻击。
        // 只认同时带基建组的（PRTS 那种布局）；只有一套骨骼的导入模型也会被归到「正面」，它们照常走
        let hasBase = sets.contains { $0["group"]?.hasPrefix("基建") == true }
        let battle = hasBase && !(info!.group.hasPrefix("基建"))
        combos = battle ? b.array("combos").compactMap(Self.parseCombo) : []
        brain.attack = combos.first { $0.id.caseInsensitiveCompare("Attack") == .orderedSame }?.steps ?? []
        brain.setBattle(battle)
        brain.pose = validPose(config.pose)
        brain.refreshAnimation()
        sentAnim = -1
        sentDir = 0
        sentPosX = -1
        bounds = nil
        if !placed {
            placed = true
            brain.teleport(to: manager.initialFoot(for: self, drop: dropOnPlace))
        }
        applyFrame()
        manager.petVisibilityMayChange(self)
        manager.petChanged(self)
        Log.info("[\(short)] 载入 \(model) · \(info!.outfit) · \(info!.group)；窗口 \(Int(layout.w))×\(Int(layout.h)) pt；动画 \(anims.count) 个")
    }

    private func handleLayout(_ b: Body) {
        guard let layout = parseLayout(b.dict("layout")), let rest = b.rect("rest"), info != nil else { return }
        info!.layout = layout
        info!.rest = rest
        brain.params.height = Double(rest.height)
        brain.params.halfWidth = max(10, Double(rest.width) / 2)
        bounds = nil
        applyFrame()
    }

    /// 网页认出来的套组（web/src/stage/combos.ts）
    private static func parseCombo(_ raw: Any) -> Combo? {
        guard let d = raw as? [String: Any], let id = d["id"] as? String, let label = d["label"] as? String,
              let steps = d["steps"] as? [[String: Any]] else { return nil }
        let parsed = steps.compactMap { s -> ComboStep? in
            guard let n = s["name"] as? String else { return nil }
            return ComboStep(name: n, loop: s["loop"] as? Bool ?? false, seconds: (s["seconds"] as? NSNumber)?.doubleValue ?? 1)
        }
        return parsed.isEmpty ? nil : Combo(id: id, label: label, steps: parsed)
    }

    private func parseLayout(_ b: Body?) -> PetLayout? {
        guard let b, let w = b.double("w"), let h = b.double("h"), let fx = b.double("footX"), let fy = b.double("footY") else { return nil }
        return PetLayout(w: w, h: h, footX: fx, footY: fy)
    }

    private func handleError(_ b: Body) {
        let text = b.string("text") ?? "?"
        Log.error("[\(short) 网页] \(b.string("stage") ?? "") \(text)")
        guard b.string("stage") == "load" else { return }
        lastError = "加载失败：\(text)"
        manager.petChanged(self)
        // 从来没载入成功过、又不是内置模型：退回内置模型，至少有只小人
        if info == nil, !fellBack, config.model != AppConfig.builtinModel, let m = ModelLibrary.find(AppConfig.builtinModel) {
            fellBack = true
            loadedFiles = m.files
            window.webView.send(["type": "load", "base": "./models/", "files": m.files, "height": config.height, "group": "基建", "model": m.name])
        }
    }

    /* ---------------------------------------------------------------- 每帧 */

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 0 : min(now - lastTick, 0.1)
        if lastTick != 0 {
            let expected = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
            tickCount += 1
            if now - lastTick > expected * 1.5 { tickLate += 1 }
            tickMaxGap = max(tickMaxGap, now - lastTick)
            if now - lastTick > 0.1, !hidden { Log.warn("[\(short)] 主线程卡了 \(Int((now - lastTick) * 1000)) ms（\(brain.behavior.rawValue)）") }
        }
        lastTick = now
        guard info != nil, !hidden else { return }
        if brain.facePending, now - faceSentAt > 0.25 { brain.facePending = false }
        let world = manager.world(for: self)
        if let p = press, p.moved {
            let m = NSEvent.mouseLocation
            brain.drag(to: CGPoint(x: m.x - p.grab.dx, y: m.y - p.grab.dy), world: world)
        } else if !manager.frozen {
            brain.step(dt: dt, world: world)
        }
        syncWeb(now)
        applyFrame()
        updateMouse(now)
        updateAlpha(dt)
        updateRates()
        if brain.behavior != reportedBehavior {
            reportedBehavior = brain.behavior
            manager.petChanged(self)
        }
    }

    private func syncWeb(_ now: CFTimeInterval) {
        if brain.dir != sentDir {
            let first = sentDir == 0
            sentDir = brain.dir
            window.webView.send(["type": "face", "dir": brain.dir])
            if !first {
                brain.facePending = true
                faceSentAt = now
            }
        }
        if let a = brain.anim, a.token != sentAnim {
            sentAnim = a.token
            window.webView.send(["type": "play", "name": a.name, "loop": a.loop])
        }
    }

    /// 窗口是横跨所在屏幕的一条带子（屏幕宽 × 小人高），小人在带子里的横坐标由网页画。
    /// 这样走路、站着时窗口完全不动：macOS 每次移动窗口都要向 WindowServer 要一个同步 fence，
    /// 多屏时偶尔会阻塞主线程几百毫秒（实测 20 秒里 2 次、最长 350ms），逐帧移动窗口必然掉帧。
    /// 只有下落、被拖、跟着窗口走时才上下挪窗口。
    private func applyFrame() {
        guard let layout = info?.layout else { return }
        let screen = manager.screenFrame(near: brain.foot)
        let s = window.panel.backingScaleFactor > 0 ? window.panel.backingScaleFactor : 2
        let y = ((brain.foot.y - layout.footY) * s).rounded() / s
        let target = NSRect(x: screen.minX, y: y, width: screen.width, height: CGFloat(layout.h))
        let cur = window.panel.frame
        if cur.size != target.size || cur.minX != target.minX {
            window.panel.setFrame(target, display: true)
        } else if cur.minY != target.minY {
            window.panel.setFrameOrigin(target.origin)
        }
        let x = brain.foot.x - target.minX
        let vx = brain.visualVX
        if abs(x - sentPosX) > 0.01 || vx != sentPosVX || target.width != sentPosW {
            sentPosX = x
            sentPosVX = vx
            sentPosW = target.width
            window.webView.send(["type": "pos", "x": x, "vx": vx, "w": target.width])
        }
    }

    /// 悬停透明开着、没按 ⌥：鼠标在小人附近时变淡并一律穿透（拖不动、点不到，按住 ⌥ 恢复）
    private var fadeActive: Bool {
        config.hoverFade && press == nil && !NSEvent.modifierFlags.contains(.option)
    }

    /// 按小人现在的位置平移过的包围盒（窗口内坐标）
    private var liveBounds: CGRect? {
        guard let b = bounds else { return nil }
        guard let sx = boundsX else { return b }
        return b.offsetBy(dx: brain.foot.x - window.panel.frame.minX - sx, dy: 0)
    }

    private func mouseNearPet() -> Bool {
        guard let b = liveBounds else { return false }
        let m = NSEvent.mouseLocation
        let f = window.panel.frame
        return b.insetBy(dx: -6, dy: -6).contains(CGPoint(x: m.x - f.minX, y: m.y - f.minY))
    }

    private func updateAlpha(_ dt: Double) {
        let target = fadeActive && mouseNearPet() ? 1.0 : 0.0
        fade += (target - fade) * min(1, dt * 12)
        if abs(target - fade) < 0.01 { fade = target }
        let base = config.opacity
        let alpha = CGFloat(base * (1 - fade * (1 - manager.tuning.hoverAlpha)))
        if abs(window.panel.alphaValue - alpha) > 0.002 { window.panel.alphaValue = alpha }
    }

    /// 只有鼠标在小人身上（按画布像素判断）时窗口才接鼠标，其余地方穿透给下面的窗口
    private func updateMouse(_ now: CFTimeInterval) {
        let panel = window.panel
        var ignore = true
        if fadeActive {
            hitAnswer = nil
        } else if press != nil {
            ignore = false
        } else if let b = liveBounds {
            let m = NSEvent.mouseLocation
            let local = CGPoint(x: m.x - panel.frame.minX, y: m.y - panel.frame.minY)
            if b.insetBy(dx: -4, dy: -4).contains(local) {
                if let a = hitAnswer, hypot(a.point.x - local.x, a.point.y - local.y) < 3, now - a.at < 0.2 {
                    ignore = !a.inside
                } else {
                    ignore = panel.ignoresMouseEvents // 等网页回答期间保持原样
                    if hitInFlight == nil || now - hitInFlight!.at > 0.25 {
                        hitSeq += 1
                        hitInFlight = (hitSeq, now)
                        window.webView.send(["type": "hit", "id": hitSeq, "x": local.x, "y": local.y])
                    }
                }
            } else {
                hitAnswer = nil
            }
        }
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    private func handleHit(_ b: Body) {
        guard let id = b.double("id"), Int(id) == hitInFlight?.id else { return }
        hitInFlight = nil
        hitAnswer = (CGPoint(x: b.double("x") ?? 0, y: b.double("y") ?? 0), b.bool("inside") ?? false, CACurrentMediaTime())
        if SchemeHandler.verbose { Log.info("[\(short)] 点击判定 (\(Int(b.double("x") ?? 0)), \(Int(b.double("y") ?? 0))) → \(hitAnswer!.inside ? "在身上" : "透明")") }
    }

    /// 省电：站着不动时原生层 30Hz 就够（只剩鼠标检测）。
    /// 渲染只在行走、下落、拖拽、互动时 60fps，其余 30fps：WebKit 每次提交图层都可能卡一下，提交少一半，停顿也少一半
    private func updateRates() {
        let fast = brain.isMoving || press != nil || brain.isOnWindow
        let cls = fast ? 1 : 0
        if cls != rateClass {
            rateClass = cls
            link?.preferredFrameRateRange = fast ? .default : CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        }
        let smooth: Set<Behavior> = [.walk, .fall, .held, .interact]
        let fps = smooth.contains(brain.behavior) || press != nil ? 0 : 30
        if fps != webFPS {
            webFPS = fps
            window.webView.send(["type": "fps", "value": fps])
        }
    }

    /* ---------------------------------------------------------------- 显示 / 隐藏 */

    func setHidden(_ h: Bool) {
        wantHidden = h
        applyVisibility()
    }

    private func applyVisibility() {
        let hide = wantHidden || info == nil
        guard hide != hidden else { return }
        hidden = hide
        if hide {
            window.panel.orderOut(nil)
        } else {
            applyFrame()
            window.panel.orderFrontRegardless()
            lastTick = 0
        }
        window.webView.send(["type": "pause", "paused": hide])
    }

    /// 屏幕休眠（锁屏、合盖）时停掉渲染；不看窗口遮挡状态：透明窗口的遮挡判断不可靠
    func setSuspended(_ s: Bool) {
        guard !hidden else { return }
        window.webView.send(["type": "pause", "paused": s])
    }

    /// 「叫回来」：从主屏上方掉下来
    func summon(to p: CGPoint) {
        guard placed else { return }
        press = nil
        brain.teleport(to: p)
    }

    /* ---------------------------------------------------------------- 调试 */

    /// 调试：在这只的页面里跑一段 JS，结果写日志
    func debugEval(_ js: String) {
        window.webView.evaluateJavaScript(js) { [short] result, error in
            if let error { Log.warn("[\(short)] eval 出错：\(error)") } else { Log.info("[\(short)] eval → \(String(describing: result))") }
        }
    }

    func requestSnapshot(tag: String) {
        window.webView.send(["type": "snapshot", "id": tag])
    }

    private func saveSnapshot(_ b: Body) {
        let tag = b.string("id") ?? "snap"
        let base = Paths.snapshots.appendingPathComponent("\(tag)-\(short)")
        if let png = b.string("png"), let data = Data(base64Encoded: png) {
            try? data.write(to: base.appendingPathExtension("png"))
        }
        var web = b.raw
        web["png"] = nil
        let doc: [String: Any] = ["native": state, "web": web]
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: base.appendingPathExtension("json"))
        }
        Log.info("[\(short)] 快照 → \(base.lastPathComponent).png")
    }

    var state: [String: Any] {
        [
            "id": config.id,
            "model": config.model,
            "loaded": info.map { ["model": $0.model, "outfit": $0.outfit, "group": $0.group, "layout": jsonObject($0.layout), "rest": rectDict($0.rest)] } ?? NSNull(),
            "error": lastError ?? NSNull(),
            "behavior": brain.behavior.rawValue,
            "dir": brain.dir,
            "foot": ["x": brain.foot.x, "y": brain.foot.y],
            "support": String(describing: brain.support),
            "frame": rectDict(window.panel.frame),
            "bounds": bounds.map(rectDict) ?? NSNull(),
            "hidden": hidden,
            "ignoresMouseEvents": window.panel.ignoresMouseEvents,
            "alpha": Double(window.panel.alphaValue),
            "activity": brain.activity.rawValue,
            "occlusionVisible": window.panel.occlusionState.contains(.visible),
            "screen": window.panel.screen?.localizedName ?? NSNull(),
            "webPID": window.webView.webProcessID.map { Int($0) } ?? NSNull(),
            "ticks": tickStats(),
        ]
    }

    private func tickStats() -> [String: Any] {
        defer {
            tickCount = 0
            tickLate = 0
            tickMaxGap = 0
        }
        return ["frames": tickCount, "late": tickLate, "maxGapMs": (tickMaxGap * 10000).rounded() / 10]
    }

    /// 正被按住 / 拖着（这时不做会重启 App 的事）
    var isPressed: Bool { press != nil }

    /// 给设置页、控制面板的摘要
    var summary: [String: Any] {
        let r = brain.params.roles
        return [
            "id": config.id,
            "behavior": brain.behavior.rawValue,
            "standing": brain.support != .none && brain.behavior != .held && brain.behavior != .fall,
            "can": ["interact": r.interact != nil, "sit": r.sit != nil, "sleep": r.sleep != nil, "move": r.move != nil && !brain.battle],
            "battle": brain.battle,
            "animations": (info?.animations.keys.sorted() ?? []) as [String],
            "combos": combos.map { ["id": $0.id, "label": $0.label] },
            "pose": (brain.pose ?? r.idle).map { $0 as Any } ?? NSNull(),
            "loaded": info.map { ["model": $0.model, "outfit": $0.outfit, "group": $0.group, "sets": $0.sets] } ?? NSNull(),
            "error": lastError ?? NSNull(),
        ]
    }
}

func rectDict(_ r: CGRect) -> [String: Double] {
    ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)]
}

/* -------------------------------------------------------------------- 网页消息 */

extension Pet: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let b = Body(message.body) else { return }
        switch b.type {
        case "ready": sendLoad()
        case "loaded": handleLoaded(b)
        case "layout": handleLayout(b)
        case "faced": brain.facePending = false
        case "bounds":
            bounds = CGRect(x: b.double("x") ?? 0, y: b.double("y") ?? 0, width: b.double("w") ?? 0, height: b.double("h") ?? 0)
            boundsX = b.double("sx").map { CGFloat($0) }
        case "animDone": if let n = b.string("name") { brain.animationFinished(n) }
        case "hit": handleHit(b)
        case "snapshot": saveSnapshot(b)
        case "log":
            let text = "[\(short) 网页] \(b.string("text") ?? "")"
            if ["warn", "error"].contains(b.string("level") ?? "") { Log.warn(text) } else { Log.info(text) }
        case "error": handleError(b)
        default: break
        }
    }
}

extension Pet: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashes = crashes.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        Log.error("[\(short)] 网页进程退出了（一分钟内第 \(crashes.count) 次）")
        guard crashes.count <= 3 else {
            lastError = "渲染进程 1 分钟内崩溃 \(crashes.count) 次，已停止自动重载"
            manager.petChanged(self)
            return
        }
        loadPage()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.info("[\(short)] pet.html 载入完成（\(webView.url?.absoluteString ?? "?")）")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.error("[\(short)] pet.html 载入失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.error("[\(short)] pet.html 打不开：\(error.localizedDescription)")
    }
}

/* -------------------------------------------------------------------- 鼠标 */

extension Pet: MouseCatcherDelegate {
    func catcherMouseDown(_ e: NSEvent) {
        let m = NSEvent.mouseLocation
        press = Press(start: m, grab: CGVector(dx: m.x - brain.foot.x, dy: m.y - brain.foot.y), samples: [(CACurrentMediaTime(), m)])
    }

    func catcherMouseDragged(_ e: NSEvent) {
        guard var p = press else { return }
        let m = NSEvent.mouseLocation
        if !p.moved, hypot(m.x - p.start.x, m.y - p.start.y) > 4 {
            p.moved = true
            brain.grab()
            window.panel.orderFrontRegardless() // 拎起来的放到别的小人上面
        }
        let now = CACurrentMediaTime()
        p.samples.append((now, m))
        p.samples.removeAll { now - $0.t > 0.12 }
        press = p
        if p.moved {
            brain.drag(to: CGPoint(x: m.x - p.grab.dx, y: m.y - p.grab.dy), world: manager.world(for: self))
            applyFrame()
        }
    }

    func catcherMouseUp(_ e: NSEvent) {
        guard var p = press else { return }
        press = nil
        let now = CACurrentMediaTime()
        p.samples.append((now, NSEvent.mouseLocation))
        if p.moved {
            brain.release(velocity: throwVelocity(p.samples, now: now))
        } else {
            brain.click()
            // 基建形态点一下会说话（模型有 voice/ 才有声音，播什么由页面挑）
            if !brain.battle { window.webView.send(["type": "touch"]) }
        }
    }

    /// 最近 80ms 的鼠标位移估算扔出去的速度；松手前停住了就是 0
    private func throwVelocity(_ samples: [(t: CFTimeInterval, p: CGPoint)], now: CFTimeInterval) -> CGVector {
        let recent = samples.filter { now - $0.t <= 0.08 }
        guard let first = recent.first, let last = recent.last, last.t - first.t > 0.01 else { return .zero }
        let dt = last.t - first.t
        return CGVector(dx: (last.p.x - first.p.x) / dt, dy: (last.p.y - first.p.y) / dt)
    }

    /// 小人身上不响应右键（动作和设置都在控制面板里）；事件吞掉，不弹菜单
    func catcherRightMouseDown(_ e: NSEvent) {}
}
