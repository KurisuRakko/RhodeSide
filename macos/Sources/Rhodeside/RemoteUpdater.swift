import AppKit
import CryptoKit
import PetCore

/// 公网更新：定时拉两份签名清单（带 ETag，没变化是 304）。
/// - `v1/app.json`：App 本身。新版本下载、验签后交给 AppInstaller，换掉 .app 并重启（起不来会自动回滚）。
/// - `v1/manifest.json`：前端。下载、验签后解压到 web-dev，原地重载所有页面。
///
/// 信任链：清单是 `{key, payload, sig}`，sig 是服务器私钥对 payload 字节的 Ed25519 签名，公钥写死在这里；
/// 包的 sha256 和大小写在已签名的 payload 里，payload 的 kind 区分 App / 前端（防止拿一份清单冒充另一份）。
/// 更新通道开了鉴权时，每个请求带 Priestess 换来的票据（X-Rhodeside-Ticket）。
final class RemoteUpdater {
    /// 原生层 ↔ 网页的消息协议版本；改协议时和 scripts/publish.mjs 的 BRIDGE 一起 +1，旧 App 就不会装上新协议的前端
    static let bridge = 3
    static let publicKey = "22wsvEszLCFB/sCF9GSQuYfq0PtB9YU94J3CEuAm8dc="

    let auth: Auth
    private(set) var lastCheck: Date?
    private(set) var lastError: String?
    private(set) var remoteWeb: Int64?
    private(set) var remoteApp: Int64?
    private(set) var appState: String?
    private var config: UpdateConfig
    private var timer: Timer?
    private var busy = false
    private let session: URLSession
    /// 每份清单最后一次的结论（304 时沿用；不可用的清单连同错误一起记住，直到清单变化）
    private var cache: [String: (etag: String?, result: Result<Manifest, Oops>)] = [:]
    /// 包下载 / 安装失败的退避：build → (次数, 下次再试的时间)
    private var backoff: [Int64: (count: Int, until: Date)] = [:]
    private var ticket: (value: String, expires: Date)?
    /// 在线模型目录（ETag 缓存）、正在下载的模型、每个模型最近的失败
    private var modelCache: (etag: String?, result: Result<ModelStore.Catalog, Oops>)?
    private(set) var catalog: ModelStore.Catalog?
    private var modelDownloading: String?
    private var modelFailed: [String: String] = [:]
    private var modelBackoff: [String: (count: Int, until: Date)] = [:]
    /// 正在下载的预览（同一个模型点两次只下一次）
    private var previewTasks: [String: Task<[String], Error>] = [:]
    /// 装好 / 更新了模型
    var onModelsChanged: ((String) -> Void)?

    func resetTicket() {
        ticket = nil
        ticketBlockedUntil = nil
    }
    /// 换票连续被拒（新令牌也 401）：先停 5 分钟，别每 5 秒轮转一次 refresh token
    private var ticketBlockedUntil: Date?
    /// 装好新前端之后回调（PetManager 用来重载页面）
    var onApplied: ((Int64) -> Void)?
    var onChange: (() -> Void)?
    /// App 自更新要重启：有桌宠正被拖着时先等等
    var canRestart: () -> Bool = { true }

    init(config: UpdateConfig, auth: Auth) {
        self.config = config
        self.auth = auth
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 300
        c.httpAdditionalHeaders = ["User-Agent": "Rhodeside/\(Paths.version)"]
        session = URLSession(configuration: c)
        takeInstallResult()
    }

    /// 交接脚本在新版本报告健康之后才写结果：每轮检查都看一眼
    private func takeInstallResult() {
        guard let r = AppInstaller.takeResult() else { return }
        switch r {
        case .ok(let b): Log.info("App 已更新到 build \(b)")
        case .rolledBack(let b):
            AppInstaller.markFailed(b)
            appState = "failed"
            Log.warn("App build \(b) 启动失败，已回滚到当前版本")
        }
    }

    func apply(_ raw: UpdateConfig) {
        var c = raw
        // 更新通道只接受 https 的 rakko.cn 主机：票据请求会带上 Priestess 令牌
        if !Auth.trusted(c.url) { c.url = UpdateConfig.defaultURL }
        let changed = c != config || timer == nil
        config = c
        guard changed else { return }
        timer?.invalidate()
        timer = nil
        cache = [:]
        // 自动更新关了也要定时跑：模型下载不归这个开关管
        guard URL(string: c.url) != nil else {
            onChange?()
            return
        }
        let t = Timer(timeInterval: max(2, c.interval), repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    /// 更新通道地址（日志上传也发到这里）
    var baseURL: URL? { URL(string: config.url) }

    var status: [String: Any] {
        [
            "enabled": config.enabled,
            "url": config.url,
            "current": Paths.webBuild(Paths.webRoot),
            "remote": remoteWeb.map { NSNumber(value: $0) } ?? NSNull(),
            "app": [
                "current": NSNumber(value: Paths.appBuild),
                "remote": remoteApp.map { NSNumber(value: $0) } ?? NSNull(),
                "state": appState ?? NSNull(),
            ] as [String: Any],
            "lastCheck": lastCheck.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "error": lastError ?? NSNull(),
        ]
    }

    /// force：忽略 ETag 和退避，重新拉（设置页的「立即检查」）
    /// force：忽略 ETag、退避和回滚黑名单，重新拉（设置页的「立即检查」，自动更新关着也算用户明确要求）
    func check(force: Bool = false) {
        guard !busy, let base = URL(string: config.url) else { return }
        let updates = config.enabled || force
        if force {
            cache = [:]
            backoff = [:]
            ticketBlockedUntil = nil
            AppInstaller.clearFailed()
            modelCache = nil
            modelBackoff = [:]
            modelFailed = [:]
        }
        busy = true
        Task { @MainActor in
            await self.cycle(base: base, updates: updates)
            self.busy = false
        }
    }

    /* ---------------------------------------------------------------- 一轮检查 */

    @MainActor
    private func cycle(base: URL, updates: Bool) async {
        let oldError = lastError
        let old = (remoteWeb, remoteApp, appState)
        lastCheck = Date()
        takeInstallResult()
        defer {
            if lastError != oldError || old != (remoteWeb, remoteApp, appState) { onChange?() }
        }
        let headers: [String: String]
        do {
            headers = try await ticketHeaders(base: base)
        } catch {
            lastError = error.localizedDescription
            return
        }

        var errors: [String] = []
        if updates { await checkUpdates(base: base, headers: headers, errors: &errors) }
        if appState == "restarting" { return }
        await checkModels(base: base, headers: headers, errors: &errors)

        lastError = errors.isEmpty ? nil : errors.joined(separator: "；")
        if let e = lastError, e != oldError { Log.warn("更新检查：\(e)") }
    }

    @MainActor
    private func checkUpdates(base: URL, headers: [String: String], errors: inout [String]) async {
        // App 先于前端：新 App 自带同版本前端，协议版本也可能变了
        switch await manifest(base: base, path: "v1/app.json", kind: "app", headers: headers) {
        case .success(let m?):
            remoteApp = m.build
            if m.build <= Paths.appBuild {
                appState = nil
            } else if AppInstaller.hasFailed(m.build) {
                appState = "failed"
            } else {
                if let e = await updateApp(base: base, m, headers: headers) { errors.append(e) }
                if appState == "restarting" { return }
            }
        case .success(nil): remoteApp = nil
        case .failure(let e): errors.append("App：\(e.localizedDescription)")
        }

        switch await manifest(base: base, path: "v1/manifest.json", kind: "web", headers: headers) {
        case .success(let m?):
            remoteWeb = m.build
            if m.bridge != Self.bridge {
                errors.append("前端协议版本 \(m.bridge) 与 App（\(Self.bridge)）不一致，等待 App 更新")
            } else if m.build > Paths.webBuild(Paths.webRoot) {
                if let e = await updateWeb(base: base, m, headers: headers) { errors.append(e) }
            }
        case .success(nil): remoteWeb = nil
        case .failure(let e): errors.append("前端：\(e.localizedDescription)")
        }
    }

    /* ---------------------------------------------------------------- 在线模型 */

    var modelStatus: [[String: Any]] { ModelStore.status(catalog, downloading: modelDownloading, failed: modelFailed) }

    /// 模型库 / 设置页点了「下载」
    func requestModels(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        ModelStore.requested(ids)
        for id in ids {
            modelBackoff[id] = nil
            modelFailed[id] = nil
        }
        onChange?()
        check()
    }

    /// 模型库预览：默认时装的基建模型（缓存里有同版本的就直接用）。返回相对 previews/ 的文件列表
    @MainActor
    func preview(_ id: String) async throws -> [String] {
        guard let base = URL(string: config.url) else { throw Oops("更新地址不对") }
        guard let m = catalog?.models.first(where: { $0.id == id }) else { throw Oops("模型库里没有这个模型") }
        guard let p = m.preview else { throw Oops("这个模型没有预览") }
        if let files = ModelStore.cachedPreview(m) { return files }
        if let running = previewTasks[id] { return try await running.value }
        let task = Task { @MainActor () throws -> [String] in
            let headers = try await self.ticketHeaders(base: base)
            let file = try await self.download(base: base, path: p.path, size: p.size, sha256: p.sha256, tag: "preview-\(m.id)", headers: headers)
            return try await Task.detached { try ModelStore.installPreview(file, m) }.value
        }
        previewTasks[id] = task
        defer { previewTasks[id] = nil }
        return try await task.value
    }

    @MainActor
    private func checkModels(base: URL, headers: [String: String], errors: inout [String]) async {
        var req = URLRequest(url: base.appendingPathComponent("v1/models.json"))
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let tag = modelCache?.etag { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        let result: Result<ModelStore.Catalog, Oops>
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 304 where modelCache != nil:
                result = modelCache!.result
            case 200:
                do { result = .success(try ModelStore.verify(data)) } catch { result = .failure(error as? Oops ?? Oops(error.localizedDescription)) }
                modelCache = (http?.value(forHTTPHeaderField: "ETag"), result)
            case 404:
                catalog = nil
                return
            case 401:
                ticket = nil
                return errors.append("模型：需要登录")
            case let code:
                return errors.append("模型目录 HTTP \(code)")
            }
        } catch {
            return errors.append("模型：\(error.localizedDescription)")
        }
        switch result {
        case .failure(let e): return errors.append("模型：\(e.localizedDescription)")
        case .success(let c):
            catalog = c
            ModelStore.lastCatalog = c
        }
        // 一个接一个装（一次勾了很多个也不用等好几轮）；失败的退避，下一轮再说。
        // 一轮最多 90 秒：剩下的下一轮（5 秒后）接着装，中间 App / 前端更新检查不会被整批下载挡住
        let todo = ModelStore.wanted(catalog!).filter { m in modelBackoff[m.id].map { Date() >= $0.until } ?? true }
        let started = Date()
        for m in todo {
            if Date().timeIntervalSince(started) > 90 { break }
            modelDownloading = m.id
            onChange?()
            do {
                // 票据 10 分钟过期：每个都重新要一次（没到期时直接用缓存）
                let headers = try await ticketHeaders(base: base)
                let file = try await download(base: base, path: m.path, size: m.size, sha256: m.sha256, tag: "model-\(m.id)", headers: headers)
                try await Task.detached { try ModelStore.install(file, m) }.value
                modelBackoff[m.id] = nil
                modelFailed[m.id] = nil
                Log.info("在线模型：已装上「\(m.name)」（\(m.version)）")
                onModelsChanged?(m.name)
            } catch {
                let n = (modelBackoff[m.id]?.count ?? 0) + 1
                modelBackoff[m.id] = (n, Date().addingTimeInterval(min(3600, 30 * pow(4, Double(n - 1)))))
                modelFailed[m.id] = error.localizedDescription
                errors.append("模型「\(m.name)」：\(error.localizedDescription)")
                // 票据失效（401）就别接着试剩下的了
                if ticket == nil { break }
            }
        }
        modelDownloading = nil
        if !todo.isEmpty { onChange?() }
    }

    @MainActor
    private func updateWeb(base: URL, _ m: Manifest, headers: [String: String]) async -> String? {
        guard ready(m.build) else { return nil }
        do {
            let file = try await download(base: base, m, headers: headers)
            try await Task.detached { try WebInstaller.install(file, build: m.build) }.value
            backoff[m.build] = nil
            Log.info("远程热更新：已装上前端 build \(m.build)")
            onApplied?(m.build)
            return nil
        } catch {
            failed(m.build)
            return "前端 build \(m.build)：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func updateApp(base: URL, _ m: Manifest, headers: [String: String]) async -> String? {
        if let why = AppInstaller.canSelfUpdate { return why }
        guard ready(m.build) else { return nil }
        guard canRestart() else {
            appState = "waiting"
            return nil
        }
        appState = "downloading"
        onChange?()
        do {
            let file = try await download(base: base, m, headers: headers)
            appState = "installing"
            let staged = try await Task.detached { try AppInstaller.stage(file, build: m.build) }.value
            guard canRestart() else {
                appState = "waiting"
                return nil
            }
            try AppInstaller.handOff(staged, build: m.build)
            appState = "restarting"
            Log.info("App 自更新：build \(Paths.appBuild) → \(m.build)，重启")
            timer?.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return nil
        } catch {
            appState = nil
            failed(m.build)
            return "App build \(m.build)：\(error.localizedDescription)"
        }
    }

    private func ready(_ build: Int64) -> Bool {
        guard let b = backoff[build] else { return true }
        return Date() >= b.until
    }

    /// 失败后 30 秒、2 分钟、8 分钟……再试，最长 1 小时
    private func failed(_ build: Int64) {
        let n = (backoff[build]?.count ?? 0) + 1
        backoff[build] = (n, Date().addingTimeInterval(min(3600, 30 * pow(4, Double(n - 1)))))
    }

    /* ---------------------------------------------------------------- 清单与下载 */

    struct Manifest: Decodable {
        struct Bundle: Decodable {
            let path: String
            let sha256: String
            let size: Int
        }

        let schema: Int
        let kind: String?
        let build: Int64
        let bridge: Int
        let bundle: Bundle
    }

    private struct Envelope: Decodable {
        let key: String
        let payload: String
        let sig: String
    }

    /// 验签名信封，返回签过名的 payload 原始字节
    static func openEnvelope(_ data: Data) throws -> Data {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let payload = Data(base64Encoded: env.payload), let sig = Data(base64Encoded: env.sig),
              let keyData = Data(base64Encoded: publicKey)
        else { throw Oops("清单格式不对") }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard key.isValidSignature(sig, for: payload) else { throw Oops("清单签名无效") }
        return payload
    }

    static func verify(_ data: Data, kind: String) throws -> Manifest {
        let payload = try openEnvelope(data)
        guard let m = try? JSONDecoder().decode(Manifest.self, from: payload), m.schema == 1 else { throw Oops("清单版本不支持") }
        guard (m.kind ?? "web") == kind else { throw Oops("清单类型不对（\(m.kind ?? "web")）") }
        let prefix = kind == "app" ? "v1/apps/" : "v1/bundles/"
        guard m.bundle.path.hasPrefix(prefix), !m.bundle.path.contains("..") else { throw Oops("清单里的包路径不合法") }
        return m
    }

    /// nil = 通道里没有这份清单（404）
    @MainActor
    private func manifest(base: URL, path: String, kind: String, headers: [String: String]) async -> Result<Manifest?, Oops> {
        var req = URLRequest(url: base.appendingPathComponent(path))
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let tag = cache[path]?.etag { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 304:
                guard let c = cache[path] else { return .failure(Oops("清单返回 304，但本地没有缓存")) }
                return c.result.map { Optional($0) }
            case 200:
                let r: Result<Manifest, Oops>
                do { r = .success(try Self.verify(data, kind: kind)) } catch { r = .failure(error as? Oops ?? Oops(error.localizedDescription)) }
                cache[path] = (http?.value(forHTTPHeaderField: "ETag"), r)
                return r.map { Optional($0) }
            case 404:
                cache[path] = nil
                return .success(nil)
            case 401:
                ticket = nil
                return .failure(Oops(auth.enabled ? "票据无效，下次重新换票" : "更新通道需要登录（设置 → 账号）"))
            case let s:
                return .failure(Oops("清单 HTTP \(s)"))
            }
        } catch {
            return .failure(Oops(error.localizedDescription))
        }
    }

    @MainActor
    private func download(base: URL, _ m: Manifest, headers: [String: String]) async throws -> URL {
        try await download(base: base, path: m.bundle.path, size: m.bundle.size, sha256: m.bundle.sha256, tag: "download-\(m.build)", headers: headers)
    }

    @MainActor
    private func download(base: URL, path: String, size: Int, sha256 sha: String, tag: String, headers: [String: String]) async throws -> URL {
        var req = URLRequest(url: base.appendingPathComponent(path))
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (tmp, resp) = try await session.download(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { ticket = nil }
        guard status == 200 else { throw Oops("下载失败（HTTP \(status)）") }
        let file = Paths.updates.appendingPathComponent("\(tag).tar.gz")
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
        let ok = try await Task.detached { () -> Bool in
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return bytes.count == size && digest == sha
        }.value
        guard ok else {
            try? FileManager.default.removeItem(at: file)
            throw Oops("包校验失败（大小或 sha256 不符）")
        }
        return file
    }

    /* ---------------------------------------------------------------- 票据 */

    /// 鉴权关着：不带票据。开着：用 access token 换 10 分钟的票据，快过期再换（日志上传也用）
    @MainActor
    func ticketHeaders(base: URL) async throws -> [String: String] {
        guard auth.enabled else { return [:] }
        if let until = ticketBlockedUntil, Date() < until { throw Oops("换票被拒，\(Int(until.timeIntervalSinceNow / 60) + 1) 分钟后重试（或点「立即检查」）") }
        if let t = ticket, t.expires.timeIntervalSinceNow > 60 { return ["X-Rhodeside-Ticket": t.value] }
        for attempt in 0..<2 {
            let access = try await auth.accessToken()
            var req = URLRequest(url: base.appendingPathComponent("v1/ticket"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if status == 200, let value = json["ticket"] as? String, let exp = json["expires"] as? Double {
                ticket = (value, Date(timeIntervalSince1970: exp))
                return ["X-Rhodeside-Ticket": value]
            }
            let code = (json["error"] as? [String: Any])?["code"] as? String
            if status == 401, attempt == 0 {
                auth.invalidateAccess()
                continue
            }
            if status == 403, code == "app_access_denied" {
                auth.markDenied()
                throw Auth.Failure.denied
            }
            if status == 401 || status == 403 { ticketBlockedUntil = Date().addingTimeInterval(300) }
            throw Oops("换票失败（HTTP \(status)\(code.map { "，\($0)" } ?? "")）")
        }
        ticketBlockedUntil = Date().addingTimeInterval(300)
        throw Oops("换票失败：新令牌仍被拒绝")
    }
}

/* -------------------------------------------------------------------- 安装 */

/// 包解压前先列一遍：拒绝绝对路径、`..`、符号链接和硬链接（纵深防御；正常情况下签名已经保证了内容）
private func vetArchive(_ archive: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    p.arguments = ["-tvzf", archive.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { throw Oops("包无法读取") }
    for line in text.split(separator: "\n") {
        if line.first == "l" || line.first == "h" || line.contains(" -> ") || line.contains(" link to ")
            || line.contains("../") || line.hasSuffix("/..") || line.contains(" /") {
            throw Oops("包里有不安全的条目")
        }
    }
}

func untar(_ archive: URL, into dir: URL) throws {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: archive) }
    try vetArchive(archive)
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-xzf", archive.path, "-C", dir.path]
    try tar.run()
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else {
        try? fm.removeItem(at: dir)
        throw Oops("解压失败")
    }
}

enum WebInstaller {
    /// 解压到 web-dev.incoming，检查完整后整个换掉 web-dev（FSEvents 不看 .incoming，换完由 onApplied 重载）
    static func install(_ archive: URL, build: Int64) throws {
        let fm = FileManager.default
        let incoming = Paths.support.appendingPathComponent("web-dev.incoming", isDirectory: true)
        let old = Paths.support.appendingPathComponent("web-dev.replaced", isDirectory: true)
        try? fm.removeItem(at: old)
        try untar(archive, into: incoming)
        guard fm.fileExists(atPath: incoming.appendingPathComponent("pet.html").path),
              fm.fileExists(atPath: incoming.appendingPathComponent("settings.html").path)
        else {
            try? fm.removeItem(at: incoming)
            throw Oops("前端包内容不完整")
        }
        try String(build).write(to: incoming.appendingPathComponent(".rhodeside-build"), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: Paths.webDev.path) { try fm.moveItem(at: Paths.webDev, to: old) }
        try fm.moveItem(at: incoming, to: Paths.webDev)
        try? fm.removeItem(at: old)
    }
}

/// App 自更新。
///
/// 1. stage：解压到 updates/staged/Rhodeside.app，核对 bundle id、构建号、代码签名。
/// 2. handOff：写交接脚本，用 `launchctl submit` 作为独立任务启动（不随本进程退出），本进程随后正常退出（会存好位置）。
/// 3. 脚本：等旧进程退出 → 旧 .app 挪成 .previous → 新的挪进来 → 启动 → 等新进程写 healthy-<build>（最多 40 秒）
///    → 成功删掉 .previous；失败杀掉新的、换回旧的再启动，并写 result.json 让旧版本记住这个 build 别再装。
enum AppInstaller {
    static let helperLabel = "com.rakko.rhodeside.updater"
    private static var staged: URL { Paths.updates.appendingPathComponent("staged", isDirectory: true) }
    private static var resultFile: URL { Paths.updates.appendingPathComponent("result.json") }
    private static var failedFile: URL { Paths.updates.appendingPathComponent("failed-builds.json") }

    static func stage(_ archive: URL, build: Int64) throws -> URL {
        try untar(archive, into: staged)
        let app = staged.appendingPathComponent("Rhodeside.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw Oops("新版本缺 Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == Paths.bundleID else { throw Oops("新版本的 bundle id 不对") }
        guard (info["RhodesideBuild"] as? String).flatMap({ Int64($0) }) == build else { throw Oops("新版本的构建号与清单不符") }
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Rhodeside").path) else {
            throw Oops("新版本缺可执行文件")
        }
        guard run("/usr/bin/codesign", ["--verify", "--strict", app.path]) == 0 else { throw Oops("新版本代码签名校验失败") }
        return app
    }

    static func handOff(_ app: URL, build: Int64) throws {
        let script = Paths.updates.appendingPathComponent("install.sh")
        try helperScript.write(to: script, atomically: true, encoding: .utf8)
        run("/bin/launchctl", ["remove", helperLabel])
        let status = run("/bin/launchctl", [
            "submit", "-l", helperLabel, "--", "/bin/bash", script.path,
            String(getpid()), app.path, Bundle.main.bundleURL.path, String(build), Paths.updates.path,
        ])
        guard status == 0 else { throw Oops("启动安装任务失败（launchctl \(status)）") }
    }

    /// 新版本启动后调：告诉交接脚本「起来了」
    static func markHealthy() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: Paths.updates.path)) ?? [] where name.hasPrefix("healthy-") || name.hasPrefix("ran-") {
            try? fm.removeItem(at: Paths.updates.appendingPathComponent(name))
        }
        fm.createFile(atPath: Paths.updates.appendingPathComponent("healthy-\(Paths.appBuild)").path, contents: Data())
    }

    enum Outcome { case ok(Int64), rolledBack(Int64) }

    /// 读并删掉上一次自更新的结果
    static func takeResult() -> Outcome? {
        guard let data = try? Data(contentsOf: resultFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let build = (json["build"] as? NSNumber)?.int64Value
        else { return nil }
        try? FileManager.default.removeItem(at: resultFile)
        return json["result"] as? String == "ok" ? .ok(build) : .rolledBack(build)
    }

    static func hasFailed(_ build: Int64) -> Bool { failedBuilds().contains(build) }

    static func clearFailed() { try? FileManager.default.removeItem(at: failedFile) }

    /// 能不能自更新：得是装好的 .app（有构建号），而且所在目录可写（能把旧版挪开）
    static var canSelfUpdate: String? {
        let app = Bundle.main.bundleURL
        guard Paths.appBuild > 0, app.pathExtension == "app" else { return "当前不是打包安装的 App，跳过自更新" }
        guard !app.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
        else { return "App 所在目录不可写，无法自更新（请重新安装到 ~/Applications）" }
        return nil
    }

    static func markFailed(_ build: Int64) {
        let list = Array((failedBuilds() + [build]).suffix(20))
        try? JSONSerialization.data(withJSONObject: list.map { NSNumber(value: $0) }).write(to: failedFile)
    }

    private static func failedBuilds() -> [Int64] {
        guard let data = try? Data(contentsOf: failedFile), let list = try? JSONSerialization.jsonObject(with: data) as? [NSNumber] else { return [] }
        return list.map(\.int64Value)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static let helperScript = #"""
    #!/bin/bash
    # Rhodeside 自更新交接脚本（由 App 写出，launchctl submit 启动）。参数：旧 pid、新 .app、目标路径、构建号、updates 目录
    PID=$1 NEW=$2 DEST=$3 BUILD=$4 DIR=$5
    PREV="$DEST.previous"
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    exec >>"$DIR/install.log" 2>&1
    log() { echo "$(date '+%F %T') $*"; }
    # 先写结果再启动：App 启动时读 result.json，回滚的 build 记进黑名单
    finish() { printf '{"result":"%s","build":%s}\n' "$1" "$BUILD" > "$DIR/result.json"; [ -n "${2:-}" ] && open "$2"; launchctl remove com.rakko.rhodeside.updater; exit 0; }
    # launchctl submit 的任务会被 launchd 保活：脚本意外退出后会再跑一遍。每个 build 只做一次
    if [ -e "$DIR/ran-$BUILD" ]; then launchctl remove com.rakko.rhodeside.updater; exit 0; fi
    touch "$DIR/ran-$BUILD"
    log "开始安装 build $BUILD，等待 pid $PID 退出"
    for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$PID" 2>/dev/null; then log "旧进程没退，强制结束"; kill -KILL "$PID"; sleep 0.5; fi
    rm -rf "$PREV"
    if [ -d "$DEST" ] && ! mv "$DEST" "$PREV"; then log "挪走旧版本失败"; finish rolledBack "$DEST"; fi
    if ! mv "$NEW" "$DEST"; then log "放入新版本失败，恢复旧版本"; mv "$PREV" "$DEST"; finish rolledBack "$DEST"; fi
    rm -f "$DIR/healthy-$BUILD"
    "$LSREGISTER" -f "$DEST" || true
    open "$DEST"
    for i in $(seq 1 80); do
      [ -f "$DIR/healthy-$BUILD" ] && break
      # 新进程已经没了（启动就崩 / 退出）：不用等满 40 秒
      if [ "$i" -gt 6 ] && ! pgrep -f "$DEST/Contents/MacOS/Rhodeside" >/dev/null; then sleep 1; [ -f "$DIR/healthy-$BUILD" ] || break; fi
      sleep 0.5
    done
    if [ -f "$DIR/healthy-$BUILD" ]; then
      rm -rf "$PREV" "$DIR/healthy-$BUILD"
      log "build $BUILD 已启动"
      finish ok
    fi
    log "build $BUILD 没有报告启动成功（进程退出或 40 秒超时），回滚"
    pkill -TERM -f "$DEST/Contents/MacOS/Rhodeside"; sleep 2; pkill -KILL -f "$DEST/Contents/MacOS/Rhodeside"
    rm -rf "$DEST"
    mv "$PREV" "$DEST"
    "$LSREGISTER" -f "$DEST" || true
    finish rolledBack "$DEST"
    """#
}
