import AppKit
import CryptoKit
import PetCore

/// Priestess 原生流登录（PKCE S256）。
///
/// 默认浏览器打开 `/login` → 登录后跳到 `https://rhodeside.rakko.cn/auth/callback#login_code=…`
/// → 那个静态页转给 `rhodeside://auth/callback?login_code=…&state=…` → 这里 `/exchange` 换令牌。
/// refresh token 轮转一次性且有复用检测：所有刷新走同一个 Task（单飞），否则并发刷新会撤掉整条会话。
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
    private let session: URLSession
    var onChange: (() -> Void)?

    struct Tokens: Codable {
        var access: String
        var refresh: String
        /// access token 的 exp（从 JWT 里读，不验签：只用来决定什么时候提前刷新）
        var accessExpires: Date
        var user: String?
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
            case .notSignedIn: tr("需要登录 Priestess", "需要登入 Priestess", "Sign in to Priestess first")
            case .denied: tr("当前账号没有 Rhodeside 的使用权限", "目前的帳戶沒有 Rhodeside 的使用權限", "This account doesn't have access to Rhodeside")
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
        guard let code = arg("login_code") else { return fail(tr("回调里没有 login_code", "回調裡沒有 login_code", "The callback has no login_code")) }
        pending.removeAll { Date().timeIntervalSince($0.started) > 600 }
        guard !pending.isEmpty else { return fail(tr("没有进行中的登录（或已超时），请重新登录", "沒有進行中的登入（或已逾時），請重新登入", "No sign-in in progress (or it timed out). Please sign in again")) }
        // 带了 state 就必须对得上；没带时只在只有一个进行中的登录时接受（PKCE 仍然把登录码绑在这个 verifier 上）
        let match = arg("state").map { s in pending.first { $0.state == s } } ?? (pending.count == 1 ? pending.first : nil)
        guard let p = match else { return fail(tr("state 不匹配，已拒绝这次登录", "state 不符，已拒絕這次登入", "State mismatch; this sign-in was rejected")) }
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
        let task = Task<String, Error> { @MainActor in
            defer { refreshing = nil }
            guard let t = tokens else { throw Failure.notSignedIn }
            do {
                let json = try await post("/refresh", ["refresh_token": t.refresh])
                // 刷新途中退出或重新登录了：这组令牌作废，别写回去
                guard tokens?.refresh == t.refresh else { throw Failure.notSignedIn }
                try store(json)
                return tokens!.access
            } catch {
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
            throw AuthError(status: 200, code: "bad_response", message: tr("Priestess 返回的令牌不完整", "Priestess 傳回的權杖不完整", "Priestess returned an incomplete token"))
        }
        let exp = Self.jwtExpiry(access) ?? Date().addingTimeInterval(600)
        let t = Tokens(access: access, refresh: refresh, accessExpires: exp, user: tokens?.user ?? user)
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
                error = e.code == "invalid_login_code" ? tr("登录码已失效，请重新登录", "登入碼已失效，請重新登入", "The sign-in code expired. Please sign in again") : tr("登录已失效，请重新登录", "登入已失效，請重新登入", "Your sign-in expired. Please sign in again")
            case (403, "app_disabled"), (404, "app_not_found"):
                clearTokens()
                phase = .signedOut
                error = tr("Priestess 里没有可用的 \(config.appID) 应用（未注册或已停用）", "Priestess 裡沒有可用的 \(config.appID) 應用程式（未註冊或已停用）", "Priestess has no usable \(config.appID) app (not registered or disabled)")
            case (403, "local_user_disabled"):
                clearTokens()
                phase = .signedOut
                error = tr("账号已停用", "帳戶已停用", "This account has been disabled")
            case (400, "pkce_required"):
                phase = tokens == nil ? .signedOut : .signedIn
                error = tr("登录缺少 PKCE 参数，请重新登录", "登入缺少 PKCE 參數，請重新登入", "Sign-in is missing PKCE parameters. Please sign in again")
            case (401, _):
                clearTokens()
                phase = .signedOut
                error = tr("登录已失效，请重新登录（\(e.code)）", "登入已失效，請重新登入（\(e.code)）", "Your sign-in expired. Please sign in again (\(e.code))")
            default:
                if tokens == nil { phase = .signedOut }
                error = tr("\(e.message)（\(e.code)）", "\(e.message)（\(e.code)）", "\(e.message) (\(e.code))")
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
