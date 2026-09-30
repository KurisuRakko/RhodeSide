import AppKit
import PetCore

/* -------------------------------------------------------------------- 运行标记 */

/// ~/Library/Application Support/Rhodeside/running：启动时写（RunRecord JSON），每分钟更新心跳和内存，正常退出时删掉。
/// 下次启动还在 = 上次没走到 applicationWillTerminate（崩溃、被强制结束、断电、被系统杀掉）。
enum RunMarker {
    private(set) static var previousRunCrashed = false
    /// 上次的记录（老版本只写了 pid，读不出来就是 nil）
    private(set) static var previous: RunRecord?
    private static var current: RunRecord?
    private static var url: URL { Paths.support.appendingPathComponent("running") }

    static func begin() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        previousRunCrashed = FileManager.default.fileExists(atPath: url.path)
        if previousRunCrashed, let data = try? Data(contentsOf: url) { previous = try? decoder.decode(RunRecord.self, from: data) }
        current = RunRecord(pid: getpid(), version: Paths.version, started: Date())
        save()
    }

    /// 每分钟（ResourceMonitor 采样后）调
    static func beat(_ update: (inout RunRecord) -> Void) {
        guard var r = current else { return }
        r.beat = Date()
        update(&r)
        current = r
        save()
    }

    static func end() {
        current = nil
        try? FileManager.default.removeItem(at: url)
    }

    private static func save() {
        guard let r = current, let data = try? encoder.encode(r) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/* -------------------------------------------------------------------- 崩溃信号 */

/// 崩溃信号（段错误、Swift 运行时错误、abort……）到来时往日志里写一行 [FATAL]，再照常崩溃（系统照样生成崩溃报告，
/// 下次启动 LogUploader 会把报告摘要写进日志并上传）。
///
/// 信号处理函数里只能做异步信号安全的事：不分配内存、不加锁、不用 DateFormatter。所以文字都在 install 时
/// 预先做成 C 字符串，时间自己算，最后一次 write(2) 写进日志文件。
enum CrashTrap {
    private static let fatal: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGSYS]
    private static var fd: Int32 = -1
    /// 本地时区偏移（秒）；每分钟随心跳刷新（夏令时）
    private static var tzOffset = 0
    private static var started = 0
    /// 下标 = 信号编号
    private static var names = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 64)
    private static var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    /// 最近一次资源采样（MB，-1 = 还没采过）：崩溃那一行带上
    static var lastAppMB: Double = -1
    static var lastWebMB: Double = -1
    /// 走到了 applicationWillTerminate：之后的 exit() 是正常退出
    static var terminating = false
    private static var fired = false

    static func install(fd: Int32) {
        self.fd = fd
        refreshTimeZone()
        started = Int(time(nil))
        // 静态变量都在这里先碰一下：第一次访问会做初始化（分配内存），不能留到信号处理函数里
        _ = (buffer, handler, lastAppMB, lastWebMB, terminating, fired)
        names.initialize(repeating: nil, count: 64)
        for sig in fatal { names[Int(sig)] = strdup(Signals.describe(sig)) }

        // 栈溢出时原来的栈已经没法用了：信号处理函数跑在单独的栈上（只管主线程；其他线程栈溢出就不记这一行了）
        let size = 128 * 1024
        var ss = stack_t(ss_sp: malloc(size), ss_size: size, ss_flags: 0)
        sigaltstack(&ss, nil)

        for sig in fatal {
            var sa = sigaction()
            sa.__sigaction_u.__sa_sigaction = handler
            // 恢复默认处理在处理函数里自己做：macOS 上 SA_RESETHAND 对 SIGTRAP / SIGILL 不生效（实测会无限重入）
            sa.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&sa.sa_mask)
            sigaction(sig, &sa, nil)
        }

        atexit {
            guard !CrashTrap.terminating else { return }
            Log.warn("进程直接调用了 exit() 结束（没走正常退出流程）")
            Log.flush()
        }
    }

    static func refreshTimeZone() {
        tzOffset = TimeZone.current.secondsFromGMT()
    }

    private static let handler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { sig, info, _ in
        // 先恢复默认处理：返回后再次触发就是真的崩溃
        // （不用数组字面量：可能分配内存）
        signal(SIGSEGV, SIG_DFL); signal(SIGBUS, SIG_DFL); signal(SIGILL, SIG_DFL); signal(SIGTRAP, SIG_DFL)
        signal(SIGABRT, SIG_DFL); signal(SIGFPE, SIG_DFL); signal(SIGSYS, SIG_DFL)
        // 谁发的：内核把 si_code 改写过（kill -SEGV 也是 SEGV_ACCERR），不可信。实测：真故障 si_pid = 0 且 si_addr 非空；
        // kill / pthread_kill 发来的 si_addr 是空，raise 的 si_pid 是自己
        let sender = Int(info?.pointee.si_pid ?? 0)
        let user = sender != 0 || info?.pointee.si_addr == nil
        // 硬件异常：返回后那条指令再执行一次，这回按默认处理崩溃，崩溃报告里是原来的现场。
        // abort() 和发来的信号返回后不会再来一次：自己再发一遍（拿不准的也再发一遍，宁可现场差一点也不能吞掉信号）
        let refault = (sig == SIGSEGV || sig == SIGBUS || sig == SIGTRAP || sig == SIGILL) && !user
        defer { if !refault { raise(sig) } }
        // 两个线程同时崩：只写一行
        guard !CrashTrap.fired else { return }
        CrashTrap.fired = true
        var o = Out(base: CrashTrap.buffer, cap: 1024)
        var tv = timeval()
        gettimeofday(&tv, nil)
        let local = Int(tv.tv_sec) + CrashTrap.tzOffset
        let days = local >= 0 ? local / 86400 : (local - 86399) / 86400
        let secs = local - days * 86400
        let d = CivilDate.from(days: days)
        o.dec(d.year, 4); o.put("-"); o.dec(d.month, 2); o.put("-"); o.dec(d.day, 2); o.put(" ")
        o.dec(secs / 3600, 2); o.put(":"); o.dec(secs % 3600 / 60, 2); o.put(":"); o.dec(secs % 60, 2)
        o.put("."); o.dec(Int(tv.tv_usec) / 1000, 3)
        o.put(" [FATAL] 崩溃：收到 ")
        if sig >= 0, sig < 64, let name = CrashTrap.names[Int(sig)] { o.cstr(name) } else { o.put("信号 "); o.dec(Int(sig), 1) }
        if sig == SIGABRT {
            // abort() 自己给自己发，写 pid 没意义
        } else if sender != 0 {
            o.put("（由 pid "); o.dec(sender, 1); o.put(" 发送）")
        } else if user {
            o.put("（由别的进程或线程发送）")
        } else if sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGFPE {
            o.put("，地址 "); o.hex(UInt(bitPattern: info?.pointee.si_addr))
        }
        o.put(pthread_main_np() != 0 ? "，在主线程" : "，在后台线程")
        o.put("，启动后 "); o.dec(Int(tv.tv_sec) - CrashTrap.started, 1); o.put(" 秒")
        if CrashTrap.lastAppMB >= 0 {
            o.put("；最近一次采样 App "); o.dec(Int(CrashTrap.lastAppMB), 1); o.put(" MB，网页合计 "); o.dec(Int(CrashTrap.lastWebMB), 1); o.put(" MB")
        }
        o.put("\n")
        if CrashTrap.fd >= 0 { _ = write(CrashTrap.fd, o.base, o.n) } else { _ = write(STDERR_FILENO, o.base, o.n) }
    }

    /// 往固定缓冲区里拼字节（不分配内存）
    private struct Out {
        let base: UnsafeMutablePointer<UInt8>
        let cap: Int
        var n = 0

        mutating func byte(_ b: UInt8) {
            if n < cap { base[n] = b; n += 1 }
        }

        mutating func put(_ s: StaticString) {
            s.withUTF8Buffer { for b in $0 { byte(b) } }
        }

        mutating func cstr(_ p: UnsafePointer<CChar>) {
            var i = 0
            while p[i] != 0 { byte(UInt8(bitPattern: p[i])); i += 1 }
        }

        /// 十进制，至少 width 位（前面补 0）
        mutating func dec(_ v: Int, _ width: Int) {
            if v < 0 { byte(0x2D) }
            let x = v.magnitude
            var p: UInt = 1
            var len = 1
            while x / p >= 10 { p *= 10; len += 1 }
            var pad = width - len
            while pad > 0 { byte(0x30); pad -= 1 }
            while p > 0 { byte(UInt8(x / p % 10) + 0x30); p /= 10 }
        }

        mutating func hex(_ v: UInt) {
            put("0x")
            for shift in stride(from: 60, through: 0, by: -4) {
                let nib = UInt8((v >> UInt(shift)) & 0xF)
                byte(nib < 10 ? nib + 0x30 : nib - 10 + 0x61)
            }
        }
    }
}

/* -------------------------------------------------------------------- 资源监控 */

/// 每分钟采一次 App、每只桌宠的网页进程、GPU 进程的内存和 CPU：
/// - 超上限 / 持续上涨 / CPU 持续过高 → 立刻 WARN（ResourceAlarm 决定，同一件事半小时内不重复报）；
/// - 每 10 分钟写一行 INFO 汇总；系统内存压力变了也写；
/// - 顺手更新运行标记的心跳（下次启动发现上次没正常退出时，能知道死前占了多少内存）。
final class ResourceMonitor {
    struct Proc {
        var name: String
        var kind: ResourceSample.Kind
        var pid: pid_t
    }

    private static let interval: TimeInterval = 60
    private static let summaryEvery = 10
    private let processes: () -> [Proc]
    private let alarm = ResourceAlarm()
    private var cpuSeen: [pid_t: (ns: UInt64, at: CFTimeInterval)] = [:]
    private(set) var latest: [ResourceSample] = []
    private var count = 0
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private(set) var pressure = "normal"
    private var pressureLogged: CFTimeInterval = -.infinity

    init(processes: @escaping () -> [Proc]) {
        self.processes = processes
    }

    func start() {
        _ = sample()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let e = src?.data else { return }
            let p = e.contains(.critical) ? "critical" : e.contains(.warning) ? "warning" : "normal"
            guard p != self.pressure else { return }
            self.pressure = p
            let s = self.sample()
            self.beat(s)
            // 内存紧张的机器上会在正常 / 警告之间来回跳：严重总是记，其余 5 分钟最多一行
            let now = CACurrentMediaTime()
            guard p == "critical" || now - self.pressureLogged > 300 else { return }
            self.pressureLogged = now
            let text = "系统内存压力：\(RunRecord.pressureName(p))；\(self.summary(s))"
            if p == "normal" { Log.info(text) } else { Log.warn(text) }
        }
        src.resume()
        pressureSource = src
    }

    func stop() {
        timer?.invalidate()
        pressureSource?.cancel()
    }

    /// 最近一次采样里这个名字的内存（MB）
    func lastMB(_ name: String) -> Double? {
        latest.first { $0.name == name }?.mb
    }

    private func tick() {
        count += 1
        let s = sample()
        for w in alarm.check(s, now: CACurrentMediaTime()) { Log.warn("\(w)；\(summary(s))") }
        if count == 1 || count % Self.summaryEvery == 0 { Log.info(summary(s)) }
        beat(s)
    }

    private func beat(_ s: [ResourceSample]) {
        CrashTrap.refreshTimeZone()
        let web = s.filter { $0.kind == .web }.reduce(0) { $0 + $1.mb }
        CrashTrap.lastAppMB = s.first { $0.kind == .app }?.mb ?? -1
        CrashTrap.lastWebMB = web
        RunMarker.beat { r in
            r.appMB = s.first { $0.kind == .app }?.mb
            r.webMB = web
            r.gpuMB = s.first { $0.kind == .gpu }?.mb
            r.pressure = pressure
        }
    }

    private func sample() -> [ResourceSample] {
        let now = CACurrentMediaTime()
        var out: [ResourceSample] = []
        var seen: Set<pid_t> = []
        for p in processes() where !seen.contains(p.pid) {
            seen.insert(p.pid)
            guard let u = Memory.usage(p.pid) else { continue }
            var cpu: Double?
            if let prev = cpuSeen[p.pid], now > prev.at, u.cpuNs >= prev.ns {
                cpu = Double(u.cpuNs - prev.ns) / 1e9 / (now - prev.at) * 100
            }
            cpuSeen[p.pid] = (u.cpuNs, now)
            out.append(ResourceSample(name: p.name, kind: p.kind, mb: u.mb, cpu: cpu))
        }
        cpuSeen = cpuSeen.filter { seen.contains($0.key) }
        latest = out
        return out
    }

    /// 「资源：App 28 MB 1%；GPU 352 MB 4%；网页 ab12cd 61 MB 6%；合计 441 MB；系统内存压力正常」
    func summary(_ s: [ResourceSample]) -> String {
        let items = s.map { x in "\(x.name) \(Int(x.mb.rounded())) MB\(x.cpu.map { " \(Int($0.rounded()))%" } ?? "")" }
        let total = s.reduce(0) { $0 + $1.mb }
        return "资源：\(items.joined(separator: "；"))；合计 \(Int(total.rounded())) MB；系统内存压力\(RunRecord.pressureName(pressure))"
    }
}

/* -------------------------------------------------------------------- 错误码 */

extension Error {
    /// 日志里用：系统错误带上错误域和错误码（「未能连接到服务器。（NSURLErrorDomain -1004）」），方便查；自己的 Oops 只有文字
    var logDescription: String {
        let ns = self as NSError
        guard !ns.domain.hasPrefix("Rhodeside.") else { return localizedDescription }
        var s = "\(localizedDescription)（\(ns.domain) \(ns.code)"
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { s += "，底层 \(u.domain) \(u.code)" }
        return s + "）"
    }
}

/* -------------------------------------------------------------------- 机器信息 */

enum Machine {
    /// 「MacBookPro18,3，Apple M1 Pro，10 核，16 GB 内存」
    static var summary: String {
        let p = ProcessInfo.processInfo
        let gb = Double(p.physicalMemory) / 1_073_741_824
        return [sysctl("hw.model"), sysctl("machdep.cpu.brand_string"), "\(p.activeProcessorCount) 核", "\(Int(gb.rounded())) GB 内存"]
            .compactMap { $0 }.joined(separator: "，")
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/* -------------------------------------------------------------------- 网页进程终止原因 */

enum WebTermination {
    /// WebKit 私有的 _WKProcessTerminationReason
    static func describe(_ reason: Int) -> String {
        switch reason {
        case 0: return "超出内存上限（网页内存溢出，被 WebKit 结束）"
        case 1: return "超出 CPU 上限（被 WebKit 结束）"
        case 2: return "被结束（App 要求、空闲回收或换进程）"
        case 3: return "崩溃或无响应"
        default: return "原因码 \(reason)"
        }
    }
}
