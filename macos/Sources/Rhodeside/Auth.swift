import AppKit
import CryptoKit
import PetCore

/// Priestess 原生流登录（PKCE S256）。
///
/// 默认浏览器打开 `/login` → 登录后跳到 `https://rhodeside.rakko.cn/auth/callback#login_code=…`
/// → 那个静态页转给 `rhodeside://auth/callback?login_code=…&state=…` → 这里 `/exchange` 换令牌。
/// refresh token 轮转一次性且有复用检测：所有刷新走同一个 Task（单飞），否则并发刷新会撤掉整条会话。
///
/// 续签：refresh token 30 天有效，每次刷新换一枚新的。App 开着时每小时看一眼（启动、唤醒也看），
/// 距上次拿到新 refresh token 超过 12 小时就主动刷新一次——每天打开就一直续上、不会掉登录；
/// 太久（30 天）没打开，Priestess 回 invalid_refresh_token，退回未登录要重新登录（正常现象）。
/// 网络不通不退登录，令牌留着下个小时再试。
final class Auth {
    enum Phase: String {
        case disabled, signedOut, signingIn, signedIn
        /// 403 app_access_denied：账号有效但没有 Rhodeside 的权限
        case denied
    }

    static let returnURL = "https://rhodeside.rakko.cn/auth/callback"

    private(set) var phase: Phase = .signedOut
    private(set) var user: String?
    private(set) var error: String?
    private var config: AuthConfig
    private var tokens: Tokens?
    /// 进行中的登录（state → verifier）：可能开了好几个登录页，只保留最近 3 个
    private var pending: [(state: String, verifier: String, started: Date)] = []
    private var refreshing: Task<String, Error>?
    private var renewTimer: Timer?
    /// clearTokens 一次加一：分辨刷新任务是不是属于当前这组令牌
    private var generation = 0
    /// 距上次拿到新 refresh token 超过这么久就主动续签
    static let renewAfter: TimeInterval = 12 * 3600
    private let session: URLSession
    var onChange: (() -> Void)?

    struct Tokens: Codable {
        var access: String
        var refresh: String
        /// access token 的 exp（从 JWT 里读，不验签：只用来决定什么时候提前刷新）
        var accessExpires: Date
        var user: String?
        /// 上次拿到这枚 refresh token 的时间（登录或刷新）；老文件没有这项，按「该续签了」处理
        var renewed: Date?
    }

    struct AuthError: LocalizedError {
        let status: Int
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    enum Failure: LocalizedError {
        case notSignedIn, denied
        var errorDescription: String? {
            switch self {
            case .notSignedIn: "需要登录 Priestess"
            case .denied: "当前账号没有 Rhodeside 的使用权限"
            }
        }
    }

    init(config raw: AuthConfig) {
        var config = raw
        if !Self.trusted(config.api) { config.api = AuthConfig.defaultAPI }
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": "Rhodeside/\(Paths.version)"]
        session = URLSession(configuration: c)
        tokens = Self.loadTokens()
        user = tokens?.user
        phase = tokens == nil ? .signedOut : .signedIn
    }

    /// 更新和在线模型都必须登录（config.auth.enabled 保留在配置里但不再起作用）
    var enabled: Bool { true }

    func apply(_ raw: AuthConfig) {
        var c = raw
        // 令牌只发往 https 的 rakko.cn 主机（配置被改成别的地址时退回默认）
        if !Self.trusted(c.api) { c.api = AuthConfig.defaultAPI }
        guard c != config else { return }
        let identityChanged = c.api != config.api || c.appID != config.appID
        config = c
        if identityChanged { clearTokens() }
        phase = tokens == nil ? .signedOut : .signedIn
        error = nil
        onChange?()
    }

    var status: [String: Any] {
        ["enabled": true, "phase": phase.rawValue, "user": user ?? NSNull(), "error": error ?? NSNull()]
    }

    private var base: String { "\(config.api)/auth/priestess/oidc" }

    /* ---------------------------------------------------------------- 登录 / 回调 / 登出 */

    func login() {

        let state = Self.randomToken(24)
        let verifier = Self.randomToken(48) // 64 个 URL-safe 字符，落在 43–128 之间
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        pending = Array((pending + [(state, verifier, Date())]).suffix(3))
        var u = URLComponents(string: "\(base)/login")!
        u.queryItems = [
            .init(name: "app_id", value: config.appID),
            .init(name: "return_to", value: Self.returnURL),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        phase = .signingIn
        error = nil
        onChange?()
        Log.info("Priestess：打开浏览器登录")
        NSWorkspace.shared.open(u.url!)
    }

    /// `rhodeside://auth/callback?login_code=…&state=…`（或 `auth_error=…`）
    func handleCallback(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func arg(_ k: String) -> String? { items.first { $0.name == k }?.value }
        if let e = arg("auth_error") {
            fail(arg("auth_error_description") ?? e)
            return
        }
        guard let code = arg("login_code") else { return fail("回调里没有 login_code") }
        pending.removeAll { Date().timeIntervalSince($0.started) > 600 }
        guard !pending.isEmpty else { return fail("没有进行中的登录（或已超时），请重新登录") }
        // 带了 state 就必须对得上；没带时只在只有一个进行中的登录时接受（PKCE 仍然把登录码绑在这个 verifier 上）
        let match = arg("state").map { s in pending.first { $0.state == s } } ?? (pending.count == 1 ? pending.first : nil)
        guard let p = match else { return fail("state 不匹配，已拒绝这次登录") }
        pending = []
        Task { @MainActor in
            do {
                let json = try await post("/exchange", ["login_code": code, "code_verifier": p.verifier])
                try store(json)
                await fetchUser()
                phase = .signedIn
                error = nil
                Log.info("Priestess：已登录\(user.map { "（\($0)）" } ?? "")")
            } catch {
                handle(error)
            }
            onChange?()
        }
    }

    func logout() {
        let refresh = tokens?.refresh
        clearTokens()
        phase = .signedOut
        error = nil
        onChange?()
        Log.info("Priestess：已退出登录")
        if let refresh { Task { @MainActor in _ = try? await self.post("/logout", ["refresh_token": refresh]) } }
    }

    /* ---------------------------------------------------------------- 续签 */

    /// PetManager 启动时调：几秒后看一次，之后每小时一次
    func startRenewal() {
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.renewIfDue() }
        RunLoop.main.add(t, forMode: .common)
        renewTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.renewIfDue() }
    }

    /// 已登录且上次续签超过 12 小时：主动刷新一次（平时换票据时已经在刷新，这里兜住关了自动更新、一直没用到令牌的情况）
    func renewIfDue() {
        guard phase == .signedIn, let t = tokens, refreshing == nil else { return }
        if let r = t.renewed, Date().timeIntervalSince(r) < Self.renewAfter { return }
        Task { @MainActor in
            if (try? await self.refresh()) != nil { Log.info("Priestess：已续签登录") }
        }
    }

    /* ---------------------------------------------------------------- 令牌 */

    /// 可用的 access token；快过期时先刷新（单飞）
    @MainActor
    func accessToken() async throws -> String {
        if phase == .denied { throw Failure.denied }
        guard let t = tokens else { throw Failure.notSignedIn }
        if t.accessExpires.timeIntervalSinceNow > 60 { return t.access }
        return try await refresh()
    }

    /// 票据服务说这个账号没有权限（403 app_access_denied）
    func markDenied() {
        clearTokens()
        phase = .denied
        error = Failure.denied.localizedDescription
        onChange?()
    }

    /// 资源服务说 access token 无效（401）：作废当前 access，下次强制刷新
    func invalidateAccess() {
        tokens?.accessExpires = .distantPast
    }

    @MainActor
    private func refresh() async throws -> String {
        if let running = refreshing { return try await running.value }
        let gen = generation
        let task = Task<String, Error> { @MainActor in
            // 刷新途中退出 / 重新登录了（clearTokens 换了代）：这个旧任务别动新会话的单飞槽和状态
            defer { if generation == gen { refreshing = nil } }
            guard let t = tokens else { throw Failure.notSignedIn }
            do {
                let json = try await post("/refresh", ["refresh_token": t.refresh])
                guard generation == gen, tokens?.refresh == t.refresh else { throw Failure.notSignedIn }
                try store(json)
                // 之前刷新失败留下的错误（多半是断网）已经过去了
                if error != nil { error = nil; onChange?() }
                return tokens!.access
            } catch {
                guard generation == gen else { throw error }
                handle(error)
                onChange?()
                throw error
            }
        }
        refreshing = task
        return try await task.value
    }

    @MainActor
    private func fetchUser() async {
        guard let t = tokens else { return }
        var req = URLRequest(url: URL(string: "\(base)/me")!)
        req.setValue("Bearer \(t.access)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let u = json["user"] as? [String: Any]
        else { return }
        user = (u["name"] as? String) ?? (u["email"] as? String) ?? (u["sub"] as? String)
        tokens?.user = user
        if let tokens { Self.saveTokens(tokens) }
    }

    private func store(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw AuthError(status: 200, code: "bad_response", message: "Priestess 返回的令牌不完整")
        }
        let exp = Self.jwtExpiry(access) ?? Date().addingTimeInterval(600)
        let t = Tokens(access: access, refresh: refresh, accessExpires: exp, user: tokens?.user ?? user, renewed: Date())
        tokens = t
        Self.saveTokens(t)
    }

    /// 按 Priestess 的错误码归类：该退登录的退，网络问题只记一下（令牌留着，下次再试）
    private func handle(_ e: Error) {
        if let e = e as? AuthError {
            switch (e.status, e.code) {
            case (403, "app_access_denied"):
                clearTokens()
                phase = .denied
                error = Failure.denied.localizedDescription
            case (401, "invalid_refresh_token"), (401, "invalid_login_code"):
                clearTokens()
                phase = .signedOut
                error = e.code == "invalid_login_code" ? "登录码已失效，请重新登录" : "登录已过期，请重新登录"
            case (403, "app_disabled"), (404, "app_not_found"):
                clearTokens()
                phase = .signedOut
                error = "Priestess 里没有可用的 \(config.appID) 应用（未注册或已停用）"
            case (403, "local_user_disabled"):
                clearTokens()
                phase = .signedOut
                error = "账号已停用"
            case (400, "pkce_required"):
                phase = tokens == nil ? .signedOut : .signedIn
                error = "登录缺少 PKCE 参数，请重新登录"
            case (401, _):
                clearTokens()
                phase = .signedOut
                error = "登录已失效，请重新登录（\(e.code)）"
            default:
                if tokens == nil { phase = .signedOut }
                error = "\(e.message)（\(e.code)）"
            }
        } else {
            if tokens == nil { phase = .signedOut }
            error = e.localizedDescription
        }
        Log.warn("Priestess：\(error ?? "未知错误")")
    }

    private func fail(_ msg: String) {
        phase = tokens == nil ? .signedOut : .signedIn
        error = msg
        Log.warn("Priestess 登录失败：\(msg)")
        onChange?()
    }

    private func clearTokens() {
        tokens = nil
        user = nil
        refreshing = nil
        generation += 1
        try? FileManager.default.removeItem(at: Paths.authFile)
    }

    /* ---------------------------------------------------------------- HTTP 与存储 */

    @MainActor
    private func post(_ path: String, _ body: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let err = json["error"] as? [String: Any]
            throw AuthError(status: status, code: err?["code"] as? String ?? "http_\(status)",
                            message: err?["message"] as? String ?? "Priestess HTTP \(status)")
        }
        return json
    }

    private static func loadTokens() -> Tokens? {
        guard let data = try? Data(contentsOf: Paths.authFile) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Tokens.self, from: data)
    }

    private static func saveTokens(_ t: Tokens) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(t) else { return }
        let fm = FileManager.default
        let tmp = Paths.authFile.appendingPathExtension("tmp")
        fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        if rename(tmp.path, Paths.authFile.path) != 0 { try? fm.removeItem(at: tmp) }
    }

    static func trusted(_ s: String) -> Bool {
        guard let u = URL(string: s), u.scheme == "https", let h = u.host?.lowercased() else { return false }
        return h == "rakko.cn" || h.hasSuffix(".rakko.cn")
    }

    static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func randomToken(_ bytes: Int) -> String {
        var d = Data(count: bytes)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64url(d)
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
