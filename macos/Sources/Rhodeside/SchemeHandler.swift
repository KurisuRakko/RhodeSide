import Foundation
import UniformTypeIdentifiers
import WebKit

/// `rhodeside-res://app/<路径>`：页面、JS、模型都从这里读，整页同源。
///   - `models/<模型>/…` → 用户导入的模型（Application Support），没有再找 App 内置的
///   - `import/<批次>/…`  → 正在导入、等网页检查的模型
///   - `previews/<id>/…`  → 模型库的预览（缓存目录）
///   - 其余              → 网页目录（热更新推上来的开发版优先，否则 App 自带的）
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "rhodeside-res"
    /// 每个请求都记日志（调试用：defaults write com.rakko.rhodeside verboseResources -bool YES）
    static let verbose = UserDefaults.standard.bool(forKey: "verboseResources")
    static func url(_ path: String) -> URL { URL(string: "\(scheme)://app/\(path)")! }

    /// 还没回完的请求；被 stop 的从这里拿掉，之后绝不能再回调（否则 WebKit 会抛异常）
    private var active = Set<ObjectIdentifier>()
    private let io = DispatchQueue(label: "rhodeside.res", qos: .userInitiated, attributes: .concurrent)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        guard let url = task.request.url else {
            active.remove(id)
            task.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        io.async {
            let file = Self.resolve(path)
            let data = file.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            DispatchQueue.main.async {
                guard self.active.remove(id) != nil else { return }
                let status = data == nil ? 404 : 200
                let body = data ?? Data("not found: \(path)".utf8)
                let type = data == nil ? "text/plain; charset=utf-8" : Self.mimeType(for: file!)
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": type,
                    "Content-Length": String(body.count),
                    "Cache-Control": "no-store",
                    "Access-Control-Allow-Origin": "*",
                ])!
                if status == 404 { Log.warn("资源 404：\(path)") } else if Self.verbose { Log.info("资源 200：\(path)（\(body.count) B）") }
                task.didReceive(response)
                task.didReceive(body)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    /// URL 路径（已解码，以 / 开头）→ 本地文件；不允许 `..` 跑出根目录
    static func resolve(_ path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let file: URL?
        switch parts[0] {
        case "models":
            file = ModelLibrary.resolve(Array(parts.dropFirst()))
        case "import":
            file = join(Paths.imports, Array(parts.dropFirst()))
        case "previews":
            file = join(Paths.previews, Array(parts.dropFirst()))
        default:
            file = join(Paths.webRoot, parts)
        }
        guard let f = file else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return f
    }

    static func join(_ root: URL, _ parts: [String]) -> URL? {
        guard !parts.isEmpty else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "atlas", "txt": return "text/plain; charset=utf-8"
        case "skel", "bytes": return "application/octet-stream"
        default: return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
