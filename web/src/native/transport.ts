/**
 * 页面 ↔ 原生壳的传输层：前端里唯一允许碰具体 WebView API 的地方，其余代码只认这里的 post / listen / native。
 *
 * 协议（任何平台的壳都只要实现这两件事）：
 *   - 页面 → 原生：`post(msg)`，msg 是可 JSON 序列化的对象（`type` 字段区分消息）
 *   - 原生 → 页面：调 `window.rhodeside.receive(msg)`；Windows WebView2 也可以直接 PostWebMessageAsJson
 *
 * 认得的 WebView：
 *   - macOS WKWebView / Linux WebKitGTK：`webkit.messageHandlers.rhodeside`
 *   - Windows WebView2：`chrome.webview`
 * 都没有 = 普通浏览器（vite dev 调界面），`native` 为 false，`post` 返回 false，由调用方走调试分支。
 */

type Sink = { postMessage(m: unknown): void }
type WebView2 = Sink & { addEventListener(type: 'message', fn: (e: { data: unknown }) => void): void }

const w = window as unknown as {
  webkit?: { messageHandlers?: { rhodeside?: Sink } }
  chrome?: { webview?: WebView2 }
  rhodeside?: { receive(msg: never): void }
}

const webkit = w.webkit?.messageHandlers?.rhodeside
const webview2 = webkit ? undefined : w.chrome?.webview
const sink: Sink | undefined = webkit ?? webview2

/** 在原生壳里（不是普通浏览器） */
export const native = !!sink

/** 发给原生层；不在壳里时什么都不做并返回 false。 */
export function post(msg: object): boolean {
  if (!sink) return false
  sink.postMessage(msg)
  return true
}

/** 接收原生层发来的消息。一个页面只调一次。 */
export function listen<T>(receive: (msg: T) => void) {
  w.rhodeside = { receive }
  webview2?.addEventListener('message', (e) => receive(e.data as T))
}
