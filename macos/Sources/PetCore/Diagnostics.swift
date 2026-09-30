import Foundation

/* -------------------------------------------------------------------- 运行记录 */

/// 运行标记文件的内容：启动时写一份，之后每分钟更新心跳和最近一次资源采样。
/// 下次启动还看得到它 = 这次没走到正常退出，就把它写进日志（什么时候没的、死前占了多少内存）。
public struct RunRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var version: String
    public var started: Date
    /// 最后一次心跳（每分钟）
    public var beat: Date?
    /// 最近一次采样：App / 网页合计 / GPU 进程，MB
    public var appMB: Double?
    public var webMB: Double?
    public var gpuMB: Double?
    /// 最近一次的系统内存压力：normal / warning / critical
    public var pressure: String?

    public init(pid: Int32, version: String, started: Date) {
        self.pid = pid
        self.version = version
        self.started = started
    }

    /// 上次没正常退出时写进日志的那句话
    public func uncleanExitSummary(now: Date) -> String {
        var s = "上次运行（\(version)，pid \(pid)，\(Self.clock(started)) 启动）没有正常退出（崩溃、被强制结束、断电或内存不够被系统杀掉）"
        if let beat {
            s += "；最后一次心跳 \(Self.clock(beat))（启动后 \(Self.duration(beat.timeIntervalSince(started)))，距今 \(Self.duration(now.timeIntervalSince(beat)))）"
        } else {
            s += "；启动后一分钟内就没了"
        }
        var mem: [String] = []
        if let appMB { mem.append("App \(Int(appMB)) MB") }
        if let webMB { mem.append("网页合计 \(Int(webMB)) MB") }
        if let gpuMB { mem.append("GPU \(Int(gpuMB)) MB") }
        if !mem.isEmpty { s += "；当时内存：\(mem.joined(separator: "，"))" }
        if let pressure, pressure != "normal" { s += "；系统内存压力：\(Self.pressureName(pressure))" }
        return s
    }

    public static func pressureName(_ p: String) -> String {
        switch p {
        case "normal": return "正常"
        case "warning": return "警告（内存紧张）"
        case "critical": return "严重（内存快用光了）"
        default: return p
        }
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    /// 3 秒 / 12 分 / 3 小时 5 分 / 2 天 4 小时
    public static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分" }
        if s < 86400 { return s % 3600 / 60 == 0 ? "\(s / 3600) 小时" : "\(s / 3600) 小时 \(s % 3600 / 60) 分" }
        return s % 86400 / 3600 == 0 ? "\(s / 86400) 天" : "\(s / 86400) 天 \(s % 86400 / 3600) 小时"
    }
}

/* -------------------------------------------------------------------- 信号 */

public enum Signals {
    /// 信号名和一句人话（崩溃类信号写进日志时用）
    public static func describe(_ sig: Int32) -> String {
        switch sig {
        case SIGSEGV: return "SIGSEGV（段错误：访问了无效内存）"
        case SIGBUS: return "SIGBUS（总线错误：访问了无效内存）"
        case SIGILL: return "SIGILL（非法指令）"
        case SIGTRAP: return "SIGTRAP（Swift 运行时错误：强制解包 nil、数组越界、fatalError 等）"
        case SIGABRT: return "SIGABRT（abort：未捕获的异常或断言失败）"
        case SIGFPE: return "SIGFPE（算术错误，如整数除零）"
        case SIGSYS: return "SIGSYS（错误的系统调用）"
        case SIGTERM: return "SIGTERM（被要求退出）"
        case SIGINT: return "SIGINT（Ctrl-C）"
        case SIGHUP: return "SIGHUP（终端断开）"
        case SIGKILL: return "SIGKILL（被强制结束）"
        default: return "信号 \(sig)"
        }
    }
}

/* -------------------------------------------------------------------- 系统崩溃报告 */

/// 把系统的崩溃报告（`~/Library/Logs/DiagnosticReports/*.ips`，第一行是头部 JSON，后面是正文 JSON）
/// 摘成几行写进日志：异常类型、信号、终止原因、运行时留言（fatalError 的文字等）、崩溃线程的前几帧。
public enum CrashReport {
    public static func summary(_ text: String, frames limit: Int = 12) -> String? {
        guard let nl = text.firstIndex(of: "\n"),
              let head = json(text[..<nl]),
              let body = json(text[text.index(after: nl)...])
        else { return nil }
        var parts: [String] = []

        if let e = body["exception"] as? [String: Any] {
            var s = e["type"] as? String ?? "?"
            if let sig = e["signal"] as? String { s += "（\(sig)）" }
            if let sub = e["subtype"] as? String { s += " \(sub)" }
            if let codes = e["codes"] as? String { s += "，codes \(codes)" }
            parts.append("异常 \(s)")
        }
        if let t = body["termination"] as? [String: Any] {
            var s = t["indicator"] as? String ?? ""
            let ns = t["namespace"] as? String
            let code = (t["code"] as? NSNumber).map { "\($0)" }
            if ns != nil || code != nil { s += "（\([ns, code].compactMap { $0 }.joined(separator: " "))）" }
            if let by = t["byProc"] as? String { s += "，由 \(by) 结束" }
            if let reasons = t["reasons"] as? [String], !reasons.isEmpty { s += "：\(reasons.joined(separator: "；"))" }
            parts.append("终止 \(s)")
        }
        if let v = [head["app_version"], head["build_version"]].compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) { parts.append("版本 \(v)") }
        if let up = (body["uptime"] as? NSNumber)?.doubleValue { parts.append("系统开机 \(RunRecord.duration(up))") }

        var lines = [parts.joined(separator: "；")]
        if let asi = body["asi"] as? [String: Any] {
            for (lib, v) in asi.sorted(by: { $0.key < $1.key }) {
                let msgs = (v as? [String]) ?? [String(describing: v)]
                for m in msgs where !m.isEmpty { lines.append("  附加信息（\(lib)）：\(m.trimmingCharacters(in: .whitespacesAndNewlines))") }
            }
        }

        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        // 未捕获的 NSException：抛出点的调用栈在 lastExceptionBacktrace，比崩溃线程（已经在 abort 里）有用
        if let bt = body["lastExceptionBacktrace"] as? [[String: Any]], !bt.isEmpty {
            lines.append("  异常抛出时的调用栈：")
            lines += frames(bt, images: images, limit: limit)
        } else {
            let idx = (body["faultingThread"] as? NSNumber)?.intValue ?? threads.firstIndex { ($0["triggered"] as? Bool) == true }
            if let idx, threads.indices.contains(idx) {
                let t = threads[idx]
                let name = t["queue"] as? String ?? t["name"] as? String
                lines.append("  崩溃线程 \(idx)\(name.map { "（\($0)）" } ?? "")：")
                lines += frames((t["frames"] as? [[String: Any]]) ?? [], images: images, limit: limit)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func frames(_ fs: [[String: Any]], images: [[String: Any]], limit: Int) -> [String] {
        var out: [String] = []
        for (i, f) in fs.prefix(limit).enumerated() {
            let img = (f["imageIndex"] as? NSNumber).map(\.intValue).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "?"
            var s = "    \(i) \(img)  "
            if let sym = f["symbol"] as? String {
                s += sym
                if let loc = f["symbolLocation"] as? NSNumber { s += " + \(loc)" }
            } else if let off = f["imageOffset"] as? NSNumber {
                s += "+0x" + String(off.uint64Value, radix: 16)
            }
            if let file = f["sourceFile"] as? String {
                s += "（\(file)\((f["sourceLine"] as? NSNumber).map { ":\($0)" } ?? "")）"
            }
            out.append(s)
        }
        if fs.count > limit { out.append("    …（共 \(fs.count) 帧）") }
        return out
    }

    private static func json<S: StringProtocol>(_ s: S) -> [String: Any]? {
        guard let data = String(s).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/* -------------------------------------------------------------------- 资源告警 */

public struct ResourceSample: Equatable, Sendable {
    public enum Kind: String, Sendable { case app, web, gpu }
    public var name: String
    public var kind: Kind
    public var mb: Double
    /// 上一次采样以来的平均 CPU（100 = 占满一个核）；第一次采样没有
    public var cpu: Double?

    public init(name: String, kind: Kind, mb: Double, cpu: Double? = nil) {
        self.name = name
        self.kind = kind
        self.mb = mb
        self.cpu = cpu
    }
}

public struct ResourceLimits: Sendable {
    /// 单个进程的内存上限（MB）。平时：App ~25、每只桌宠的网页 ~60、GPU ~350
    public var appMB: Double = 400
    public var webMB: Double = 400
    public var gpuMB: Double = 1500
    /// 所有进程合计
    public var totalMB: Double = 3000
    /// 连续两次采样都比启动后的最低值高出这么多（MB）就算「持续上涨」（App 和网页进程；GPU 随桌宠数变，不算）
    public var growthMB: Double = 300
    /// CPU 连续两次采样都超过这个（%）才报
    public var cpu: Double = 80
    /// 同一件事至少隔这么久再报一次，除非又比上次报的时候高了一半
    public var cooldown: TimeInterval = 1800

    public init() {}
}

/// 定时采样后判断「占用过大」：内存超上限、合计超上限、内存持续上涨、CPU 持续过高。只返回要写进日志的警告。
public final class ResourceAlarm {
    public var limits: ResourceLimits
    private var warned: [String: (at: TimeInterval, value: Double)] = [:]
    private var baseline: [String: Double] = [:]
    private var hot: [String: Int] = [:]
    private var high: [String: Int] = [:]

    public init(limits: ResourceLimits = ResourceLimits()) {
        self.limits = limits
    }

    public func check(_ samples: [ResourceSample], now: TimeInterval) -> [String] {
        var out: [String] = []
        let names = Set(samples.map(\.name))
        baseline = baseline.filter { names.contains($0.key) }
        hot = hot.filter { names.contains($0.key) }
        high = high.filter { names.contains($0.key) }

        for s in samples {
            let limit: Double = switch s.kind {
            case .app: limits.appMB
            case .web: limits.webMB
            case .gpu: limits.gpuMB
            }
            if s.mb > limit, fire("mem:\(s.name)", s.mb, now) {
                out.append("内存占用过大：\(s.name) \(Int(s.mb)) MB（上限 \(Int(limit)) MB）")
            }

            if s.kind != .gpu {
                let base = min(baseline[s.name] ?? s.mb, s.mb)
                baseline[s.name] = base
                // 连续两次：一次加载高峰不算
                high[s.name] = s.mb - base > limits.growthMB ? (high[s.name] ?? 0) + 1 : 0
                if high[s.name]! >= 2, fire("grow:\(s.name)", s.mb, now) {
                    out.append("内存持续上涨：\(s.name) 从 \(Int(base)) MB 涨到 \(Int(s.mb)) MB（可能有泄漏）")
                }
            }

            if let cpu = s.cpu {
                hot[s.name] = cpu > limits.cpu ? (hot[s.name] ?? 0) + 1 : 0
                if hot[s.name]! >= 2, fire("cpu:\(s.name)", cpu, now) {
                    out.append("CPU 占用过高：\(s.name) 持续 \(Int(cpu))%（100% = 占满一个核）")
                }
            }
        }

        let total = samples.reduce(0) { $0 + $1.mb }
        if total > limits.totalMB, fire("mem:total", total, now) {
            out.append("内存占用过大：合计 \(Int(total)) MB（上限 \(Int(limits.totalMB)) MB）")
        }
        return out
    }

    /// 冷却时间内不重复报，除非比上次报的时候又高了一半
    private func fire(_ key: String, _ value: Double, _ now: TimeInterval) -> Bool {
        if let w = warned[key], now - w.at < limits.cooldown, value < w.value * 1.5 { return false }
        warned[key] = (now, value)
        return true
    }
}

/* -------------------------------------------------------------------- 日期（信号处理函数里用） */

public enum CivilDate {
    /// 1970-01-01 起的天数 → 年月日（Howard Hinnant 的算法，纯整数运算：崩溃信号处理函数里不能用 DateFormatter）
    public static func from(days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}
