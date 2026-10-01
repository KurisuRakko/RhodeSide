import AppKit
import PetCore

/// 全量窗口扫描放到后台线程：CGWindowListCopyWindowInfo 实测中位数 3ms、p90 20ms、最坏 46ms，
/// 放在主线程上每 0.1 秒就会让小人的移动卡掉 1–3 帧。
final class BackgroundScanner {
    struct Result {
        let screens: [ScreenInfo]
        let windows: [WindowInfo]
        let platforms: [Platform]
        let fullscreen: Set<UInt32>
        let frames: [UInt32: CGRect]
        let order: [UInt32]
        let focus: Focus
    }

    private let queue = DispatchQueue(label: "rhodeside.scan", qos: .userInitiated)
    /// 只在主线程读写：上一轮没回来就跳过这一轮，不排队
    private var busy = false

    func scan(screens: [ScreenInfo], primaryHeight: CGFloat, frontPID: pid_t?, config: AppConfig, completion: @escaping (Result) -> Void) {
        guard !busy else { return }
        busy = true
        let pid = getpid()
        let ignored = Set(config.ignoredApps.map { $0.lowercased() })
        let walk = config.walkOnWindows
        let hide = config.hideInFullscreen
        queue.async {
            let scan = WindowScanner.scan(ownPID: pid, ignored: ignored, primaryHeight: primaryHeight, frontPID: frontPID)
            let wins = scan.windows
            let result = Result(
                screens: screens,
                windows: wins,
                platforms: Platforms.compute(screens: screens, windows: wins, walkOnWindows: walk),
                fullscreen: hide ? Platforms.fullscreenScreens(screens: screens, windows: wins) : [],
                frames: Dictionary(wins.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a }),
                order: scan.order,
                focus: scan.focus
            )
            DispatchQueue.main.async {
                self.busy = false
                completion(result)
            }
        }
    }
}

/// 小人脚下那个窗口的实时位置：后台线程每 8ms 查一次，主线程每帧只读缓存（单窗口查询最坏也要 30ms）。
/// 没有小人站在窗口上时计时器挂起，不空转。
final class WindowTracker {
    enum State: Equatable {
        case unknown
        case gone
        case at(CGRect)
    }

    private let lock = NSLock()
    private var wanted: [UInt32: CFTimeInterval] = [:]
    private var results: [UInt32: State] = [:]
    private var primaryHeight: CGFloat = 0
    private var running = false
    private let queue = DispatchQueue(label: "rhodeside.track", qos: .userInteractive)
    private let timer: DispatchSourceTimer

    init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }
    }

    deinit {
        lock.lock()
        let r = running
        lock.unlock()
        if !r { timer.resume() } // 挂起状态下 cancel 会崩，先恢复
        timer.cancel()
    }

    /// 主线程每帧调：登记关注这个窗口，返回最近一次查到的状态
    func state(of id: UInt32, primaryHeight ph: CGFloat) -> State {
        lock.lock()
        defer { lock.unlock() }
        wanted[id] = CACurrentMediaTime()
        primaryHeight = ph
        if !running {
            running = true
            timer.resume()
        }
        return results[id] ?? .unknown
    }

    private func poll() {
        let now = CACurrentMediaTime()
        lock.lock()
        wanted = wanted.filter { now - $0.value < 1 } // 一秒没人问就不查了
        results = results.filter { wanted[$0.key] != nil }
        let ids = Array(wanted.keys)
        let ph = primaryHeight
        if ids.isEmpty {
            running = false
            timer.suspend()
            lock.unlock()
            return
        }
        lock.unlock()
        var fresh: [UInt32: State] = [:]
        for id in ids { fresh[id] = WindowScanner.currentFrame(of: id, primaryHeight: ph).map { .at($0) } ?? .gone }
        lock.lock()
        for (id, s) in fresh where wanted[id] != nil { results[id] = s }
        lock.unlock()
    }
}
