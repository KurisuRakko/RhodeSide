import AppKit
import PetCore
import SystemConfiguration

/// 日志自动上传（总是开，没有开关）：把 rhodeside.log 新增的部分传到更新通道的 `POST /v1/logs`。
/// - 每天一次（启动一分钟后和之后每小时看一眼，距上次成功 ≥ 24 小时就传）；
/// - 上次没正常退出（崩溃、被强制结束；见 RunMarker）：启动 3 秒后立刻传，连同系统的崩溃报告
///   （`~/Library/Logs/DiagnosticReports/Rhodeside*.ips`，以及这个 App 的 WebKit 网页 / GPU 进程的崩溃报告；
///   每次上传都会顺手补传没传过的，传之前先把摘要写进日志：异常类型、信号、终止原因、崩溃线程的调用栈）；
/// 没有手动上传入口（2026-09-30 去掉了设置里的「立即上传日志」）。
/// 登录了带票据（服务器按账号归档），没登录也传（匿名）：登录不上正是最需要日志的时候。失败不前移游标，下个小时再试。
final class LogUploader {
    /// 单次最多传这么多原始日志（超了只传最后这些）
    static let limit: Int64 = 4_000_000
    private static let day: TimeInterval = 24 * 3600

    private struct State: Codable {
        var device: String
        var cursor: LogCursor?
        var lastUpload: Date?
        /// 上次崩溃后还没传成功
        var pendingCrash: Bool?
        /// 已经传过的系统崩溃报告（文件名）
        var reported: [String]?
        /// 已经把摘要写进日志的崩溃报告（文件名）
        var summarized: [String]?
    }

    private let updater: RemoteUpdater
    private let auth: Auth
    private var state: State
    private var timer: Timer?
    private var running: Task<Void, Never>?
    private(set) var lastError: String?
    private let session: URLSession
    var onChange: (() -> Void)?

    /* ---------------------------------------------------------------- 生命周期 */

    init(updater: RemoteUpdater, auth: Auth) {
        self.updater = updater
        self.auth = auth
        state = Self.load() ?? State(device: UUID().uuidString.lowercased())
        if RunMarker.previousRunCrashed { state.pendingCrash = true }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        c.httpAdditionalHeaders = ["User-Agent": "Rhodeside/\(Paths.version)"]
        session = URLSession(configuration: c)
        save()
    }

    func start() {
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if state.pendingCrash == true { Log.info("有异常退出的日志还没上传，3 秒后上传") }
        // 崩溃后尽快传（PetManager.init 里就调，一启动就崩的版本也来得及）；平时不跟启动抢时间
        DispatchQueue.main.asyncAfter(deadline: .now() + (state.pendingCrash == true ? 3 : 60)) { [weak self] in self?.tick() }
    }

    private func tick() {
        let due = state.lastUpload.map { Date().timeIntervalSince($0) >= Self.day } ?? true
        if state.pendingCrash == true { run("crash") } else if due { run("daily") }
    }

    var status: [String: Any] {
        [
            "lastUpload": state.lastUpload.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "error": lastError ?? NSNull(),
            "busy": running != nil,
        ]
    }

    /// reason：daily / crash。已经在传时什么也不做
    private func run(_ reason: String) {
        guard running == nil else { return }
        running = Task { @MainActor in
            do {
                try await self.upload(reason)
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
                Log.warn("日志上传（\(reason)）失败：\(error.logDescription)")
            }
            self.running = nil
            self.onChange?()
        }
        onChange?()
    }

    /* ---------------------------------------------------------------- 上传 */

    @MainActor
    private func upload(_ reason: String) async throws {
        guard let base = updater.baseURL else { throw Oops(tr("更新地址不对", "更新地址不正確", "Invalid update URL")) }
        let reports = Self.crashReports(except: Set(state.reported ?? []))
        // 崩溃报告的摘要先写进日志（跟这次的日志一起传上去，本地 tail 也看得到）
        for file in reports where !(state.summarized ?? []).contains(file.lastPathComponent) {
            let name = file.lastPathComponent
            let text = await Task.detached { (try? String(contentsOf: file, encoding: .utf8)).flatMap { CrashReport.summary($0) } }.value
            Log.warn("系统崩溃报告 \(name)：\(text.map { "\n\($0)" } ?? "读不懂")")
            state.summarized = Array(((state.summarized ?? []) + [name]).suffix(100))
        }
        save()
        Log.flush()
        let cursor = state.cursor
        let chunk = try await Task.detached { try Self.readNew(cursor: cursor) }.value
        var anonymous = false

        if !chunk.data.isEmpty {
            var q = [URLQueryItem(name: "kind", value: "log"), URLQueryItem(name: "reason", value: reason)]
            if chunk.truncated { q.append(URLQueryItem(name: "truncated", value: "1")) }
            anonymous = try await post(base: base, query: q, body: chunk.data)
        }
        state.cursor = chunk.next
        save()

        var sent = 0
        for file in reports {
            do {
                let data = try await Task.detached { try Self.pack(Data(contentsOf: file)) }.value
                anonymous = try await post(base: base, query: [
                    URLQueryItem(name: "kind", value: "crash"),
                    URLQueryItem(name: "reason", value: reason),
                    URLQueryItem(name: "name", value: file.lastPathComponent),
                ], body: data) || anonymous
                sent += 1
            } catch let e as Rejected {
                // 服务器明确不收（文件名、大小不合规）：记成传过，别每小时卡在这一份上
                Log.warn("崩溃报告 \(file.lastPathComponent) 被服务器拒收：\(e.localizedDescription)")
            }
            state.reported = Array(((state.reported ?? []) + [file.lastPathComponent]).suffix(100))
            save()
        }

        // 崩溃后系统的崩溃报告可能还没写完（ReportCrash 要符号化）：两分钟后再补查一次
        // （只看 App 自己的：顺手传了几份 WebKit 的报告不代表 App 这次的报告已经写好了）
        if reason == "crash", !reports.contains(where: { $0.lastPathComponent.hasPrefix("Rhodeside") }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, Self.crashReports(except: Set(self.state.reported ?? [])).contains(where: { $0.lastPathComponent.hasPrefix("Rhodeside") }) else { return }
                self.run("crash")
            }
        }

        state.lastUpload = Date()
        state.pendingCrash = nil
        save()
        Log.info("日志上传（\(reason)）：\(chunk.raw) 字节\(sent == 0 ? "" : "，\(sent) 份崩溃报告")\(anonymous ? "（匿名）" : "")")
    }

    /// 服务器回了 4xx（429 除外）：这份内容重试也没用
    private struct Rejected: LocalizedError {
        let errorDescription: String?
    }

    /// 返回这次是不是匿名传的
    @MainActor
    private func post(base: URL, query: [URLQueryItem], body: Data) async throws -> Bool {
        // 每个请求都重新要票据（没到期直接用缓存）：一轮里好几个请求，别让后面的带着过期票据掉进匿名；拿不到（没登录、换票被拒）就匿名传
        let headers = (try? await updater.ticketHeaders(base: base)) ?? [:]
        var u = URLComponents(url: base.appendingPathComponent("v1/logs"), resolvingAgainstBaseURL: false)!
        u.queryItems = query + [
            URLQueryItem(name: "build", value: String(Paths.appBuild)),
            URLQueryItem(name: "web", value: String(Paths.webBuild(Paths.webRoot))),
        ]
        var req = URLRequest(url: u.url!)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(state.device, forHTTPHeaderField: "X-Rhodeside-Device")
        // 电脑名、账号名放头里（不进访问日志），百分号编码（可能有中文）
        req.setValue(Self.encode(Self.computerName), forHTTPHeaderField: "X-Rhodeside-Host")
        req.setValue(Self.encode(auth.user ?? ""), forHTTPHeaderField: "X-Rhodeside-User")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: req, from: body)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String).map { tr("：\($0)", "：\($0)", ": \($0)") } ?? ""
            let msg = tr("服务器返回 HTTP \(status)", "伺服器傳回 HTTP \(status)", "Server returned HTTP \(status)") + detail
            if (400..<500).contains(status), status != 429 { throw Rejected(errorDescription: msg) }
            throw Oops(msg)
        }
        return headers.isEmpty
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    /// 「系统设置 → 通用 → 共享」里的电脑名，服务器上用来认设备（Host.current() 可能卡在 DNS 上，不用它）
    private static let computerName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ""

    /* ---------------------------------------------------------------- 读文件（后台线程） */

    private struct Chunk {
        /// 已压缩（raw deflate）；没有新内容时为空
        var data: Data
        var raw: Int
        var next: LogCursor?
        var truncated: Bool
    }

    private static func readNew(cursor: LogCursor?) throws -> Chunk {
        let cur = Paths.logs.appendingPathComponent("rhodeside.log")
        let prev = Paths.logs.appendingPathComponent("rhodeside.1.log")
        let plan = LogPlan.slices(cursor: cursor, current: info(cur), previous: info(prev), limit: limit)
        var text = Data()
        for s in plan.slices {
            let h = try FileHandle(forReadingFrom: s.which == .current ? cur : prev)
            defer { try? h.close() }
            try h.seek(toOffset: UInt64(s.start))
            text.append(try h.read(upToCount: Int(s.length)) ?? Data())
        }
        // 截掉了开头：从下一个整行开始
        if plan.truncated, let nl = text.firstIndex(of: 0x0A) { text = Data(text[text.index(after: nl)...]) }
        return Chunk(data: text.isEmpty ? Data() : try pack(text), raw: text.count, next: plan.next, truncated: plan.truncated)
    }

    private static func info(_ url: URL) -> LogFileInfo? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (a[.size] as? NSNumber)?.int64Value
        else { return nil }
        return LogFileInfo(inode: inode, size: size)
    }

    /// NSData 的 .zlib 是 raw deflate（RFC 1951，没有 zlib 头），服务器用 inflateRaw 解
    private static func pack(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    /// 最近 7 天、没传过的系统崩溃报告：App 自己的最新 5 份，和它的 WebKit 子进程（网页 / GPU）的最新 3 份（分开数，WebKit 的挤不掉 App 的）
    private static func crashReports(except done: Set<String>) -> [URL] {
        let dir = Paths.logs.deletingLastPathComponent().appendingPathComponent("DiagnosticReports", isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        let since = Date().addingTimeInterval(-7 * day)
        let found = files.filter { f in
            let name = f.lastPathComponent
            guard name.hasPrefix("Rhodeside") || name.hasPrefix("com.apple.WebKit"), f.pathExtension == "ips", !done.contains(name),
                  let v = try? f.resourceValues(forKeys: Set(keys)),
                  (v.contentModificationDate ?? .distantPast) > since, (v.fileSize ?? 0) <= 4_000_000
            else { return false }
            return name.hasPrefix("Rhodeside") || ownWebKitReport(f)
        }
        let date = { (f: URL) in (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let sorted = found.map { ($0, date($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
        let app = sorted.filter { $0.lastPathComponent.hasPrefix("Rhodeside") }
        let web = sorted.filter { !$0.lastPathComponent.hasPrefix("Rhodeside") }
        return Array(app.suffix(5)) + Array(web.suffix(3))
    }

    /// WebKit 进程的崩溃报告也可能是 Safari 等别的 App 的：看正文开头的 responsibleProc。结论缓存起来（报告不会变）
    private static var webKitOwner: [String: Bool] = [:]
    private static let ownerPattern = try! NSRegularExpression(pattern: #""responsibleProc"\s*:\s*"Rhodeside""#)

    private static func ownWebKitReport(_ f: URL) -> Bool {
        if let v = webKitOwner[f.lastPathComponent] { return v }
        var mine = false
        if let h = try? FileHandle(forReadingFrom: f) {
            defer { try? h.close() }
            let head = String(decoding: (try? h.read(upToCount: 16_384)) ?? Data(), as: UTF8.self)
            mine = ownerPattern.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) != nil
        }
        webKitOwner[f.lastPathComponent] = mine
        return mine
    }

    /* ---------------------------------------------------------------- 状态文件 */

    private static func load() -> State? {
        guard let data = try? Data(contentsOf: Paths.logUpload) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(State.self, from: data)
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(state).write(to: Paths.logUpload, options: .atomic)
    }
}
