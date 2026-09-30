import Foundation
import WebKit

/// WKUserContentController 会强引用 handler：中间隔一层弱引用，免得 Pet ↔ WebView 循环引用
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    /// target 可以晚点再设（Swift 的 init 里 super.init 之前拿不到 self）
    init(_ target: WKScriptMessageHandler? = nil) { self.target = target }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

enum WebBridge {
    static let handlerName = "rhodeside"

    /// `proxy` 由 userContentController 强引用（它自己只弱引用真正的 handler）
    static func configuration(handler proxy: WeakScriptHandler, scheme: SchemeHandler) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(scheme, forURLScheme: SchemeHandler.scheme)
        cfg.userContentController.add(proxy, name: handlerName)
        return cfg
    }
}

extension WKWebView {
    /// 原生 → 网页：调页面里的 `window.rhodeside.receive(msg)`（参数走 WebKit 序列化，不拼 JS 字符串）
    func send(_ msg: [String: Any]) {
        callAsyncJavaScript("if (window.rhodeside) window.rhodeside.receive(msg)", arguments: ["msg": msg], in: nil, in: .page) { result in
            if case .failure(let err) = result {
                Log.warn("发给网页失败（\(msg["type"] ?? "?")）：\(err.localizedDescription)")
            }
        }
    }

    /// 网页进程的 pid（私有属性，只用于调试信息；取不到就是 nil）
    var webProcessID: pid_t? {
        let sel = NSSelectorFromString("_webProcessIdentifier")
        guard responds(to: sel), let n = value(forKey: "_webProcessIdentifier") as? NSNumber else { return nil }
        let pid = n.int32Value
        return pid > 0 ? pid : nil
    }
}

/// 网页消息体（[String: Any]）取值的小工具
struct Body {
    let raw: [String: Any]
    init?(_ any: Any) {
        guard let d = any as? [String: Any] else { return nil }
        raw = d
    }
    init(dict: [String: Any]) { raw = dict }

    var type: String { raw["type"] as? String ?? "" }
    func string(_ k: String) -> String? { raw[k] as? String }
    func double(_ k: String) -> Double? { (raw[k] as? NSNumber)?.doubleValue }
    func bool(_ k: String) -> Bool? { (raw[k] as? NSNumber)?.boolValue }
    func dict(_ k: String) -> Body? { (raw[k] as? [String: Any]).map { Body(dict: $0) } }
    func array(_ k: String) -> [Any] { raw[k] as? [Any] ?? [] }
    func strings(_ k: String) -> [String] { array(k).compactMap { $0 as? String } }

    func rect(_ k: String) -> CGRect? {
        guard let b = dict(k), let x = b.double("x"), let y = b.double("y"), let w = b.double("w"), let h = b.double("h") else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Codable → 能传给 callAsyncJavaScript 的字典
func jsonObject<T: Encodable>(_ value: T) -> Any {
    guard let data = try? JSONEncoder().encode(value), let obj = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
    return obj
}

/// 在 Codable 值上合并一个 patch 字典（设置页改一项就发一项）
func merged<T: Codable>(_ value: T, patch: [String: Any]) -> T? {
    guard var dict = jsonObject(value) as? [String: Any] else { return nil }
    for (k, v) in patch { dict[k] = v is NSNull ? nil : v }
    guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
