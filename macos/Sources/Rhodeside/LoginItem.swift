import Foundation
import ServiceManagement

/// 登录时启动：用 ~/Library/LaunchAgents 里的 plist，按路径启动。
/// 不用 SMAppService.mainApp：它的登记绑定代码签名，ad-hoc 签名每次编译都变，重新部署后登记就失效了（2026-09-29 实测）。
enum LoginItem {
    static let agentLabel = "com.rakko.rhodeside"
    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    static var state: (enabled: Bool, detail: String) {
        FileManager.default.fileExists(atPath: agentURL.path) ? (true, "已启用") : (false, "未启用")
    }

    /// 返回给用户看的错误（nil = 成功）
    static func set(_ on: Bool) -> String? {
        // 清掉旧版本通过 SMAppService 做的登记，免得登录时启动两次
        if SMAppService.mainApp.status != .notRegistered { try? SMAppService.mainApp.unregister() }
        guard on else {
            removeAgent()
            return nil
        }
        do {
            try writeAgent()
            Log.info("登录时启动：\(agentURL.path)")
            return nil
        } catch {
            return "登录项设置失败：\(error.localizedDescription)"
        }
    }

    /// App 挪了位置（比如从别处拷到 ~/Applications）时，已启用的 plist 跟着改路径
    static func refreshIfEnabled() {
        guard state.enabled else { return }
        try? writeAgent()
    }

    private static func writeAgent() throws {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundleURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": [Paths.bundleID],
        ]
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agentURL, options: .atomic)
    }

    private static func removeAgent() {
        try? FileManager.default.removeItem(at: agentURL)
    }

    /// 调试：rhodeside://debug/login-item?do=status|register|unregister|probe
    static func debug(_ action: String) -> String {
        let svc = SMAppService.mainApp
        var out = ["前：\(describe(svc.status))，LaunchAgent \(FileManager.default.fileExists(atPath: agentURL.path) ? "有" : "无")"]
        func attempt(_ what: String, _ f: () throws -> Void) {
            do { try f(); out.append("\(what) 成功 → \(describe(svc.status))") } catch { out.append("\(what) 失败：\(error.localizedDescription) → \(describe(svc.status))") }
        }
        switch action {
        case "register": attempt("register") { try svc.register() }
        case "unregister": attempt("unregister") { try svc.unregister() }
        case "probe":
            attempt("register") { try svc.register() }
            attempt("unregister") { try svc.unregister() }
        default: break
        }
        return "登录项探路（\(action)）：" + out.joined(separator: "；")
    }
}
