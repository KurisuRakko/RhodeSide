import Foundation

enum Paths {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.rakko.rhodeside"

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// App 的构建号（毫秒时间戳，build-app.sh 写进 Info.plist 的 RhodesideBuild）；没有就是 0
    static let appBuild: Int64 = Int64(Bundle.main.infoDictionary?["RhodesideBuild"] as? String ?? "") ?? 0

    /// ~/Library/Application Support/Rhodeside
    static let support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Rhodeside", isDirectory: true)
    static var userModels: URL { support.appendingPathComponent("models", isDirectory: true) }
    static var imports: URL { support.appendingPathComponent("import", isDirectory: true) }
    /// `deploy.sh web` 热更新推上来的网页；存在就优先用它
    static var webDev: URL { support.appendingPathComponent("web-dev", isDirectory: true) }
    static var config: URL { support.appendingPathComponent("config.json") }
    static var positions: URL { support.appendingPathComponent("positions.json") }
    /// App 自更新的工作目录：待装的新版本、交接脚本、结果
    static var updates: URL { support.appendingPathComponent("updates", isDirectory: true) }
    /// Priestess 令牌（600）。不放钥匙串：ad-hoc 签名每次更新都会变，钥匙串会反复弹授权框
    static var authFile: URL { support.appendingPathComponent("auth.json") }
    /// 日志上传的设备 id、读到哪了、上次上传时间
    static var logUpload: URL { support.appendingPathComponent("log-upload.json") }

    /// ~/Library/Caches/Rhodeside/previews：模型库的预览（默认时装的基建模型），随时可以清掉
    static let previews: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Rhodeside/previews", isDirectory: true)

    /// ~/Library/Logs/Rhodeside
    static let logs: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Rhodeside", isDirectory: true)
    static var snapshots: URL { logs.appendingPathComponent("snapshots", isDirectory: true) }

    static var resources: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }
    static var bundledWeb: URL { resources.appendingPathComponent("web", isDirectory: true) }
    static var builtinModels: URL { resources.appendingPathComponent("models", isDirectory: true) }

    /// 前端构建号（毫秒时间戳，deploy.sh 写进 .rhodeside-build）；没有就是 0
    static func webBuild(_ dir: URL) -> Int64 {
        guard let s = try? String(contentsOf: dir.appendingPathComponent(".rhodeside-build"), encoding: .utf8) else { return 0 }
        return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static let lock = NSLock()
    private static var devWebCached: Bool?

    /// 热更新推上来的前端（web-dev）只在构建号不比 App 自带的旧时才用：全量更新 App 之后，旧的 web-dev 自动失效。
    /// 每个资源请求都要问一次，所以缓存起来；web-dev 变了由 refreshWebRoot() 重算
    static var usingDevWeb: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let v = devWebCached { return v }
        let v = FileManager.default.fileExists(atPath: webDev.appendingPathComponent("pet.html").path) && webBuild(webDev) >= webBuild(bundledWeb)
        devWebCached = v
        return v
    }

    static func refreshWebRoot() {
        lock.lock()
        devWebCached = nil
        lock.unlock()
    }

    /// 网页从哪读：开发版优先，否则 App 自带的
    static var webRoot: URL { usingDevWeb ? webDev : bundledWeb }

    static func ensureDirectories() {
        for dir in [support, userModels, imports, updates, logs, snapshots] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
