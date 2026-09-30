import CoreServices
import Foundation

/// FSEvents 递归监听一个目录，回调给出变了的路径（主线程）。用来做热更新：网页目录、模型目录、config.json。
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(path: String, latency: TimeInterval = 0.25, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray as? [String] ?? []
            me.handler(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, .main)
            FSEventStreamStart(s)
        } else {
            Log.error("FSEvents 监听不了 \(path)")
        }
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}

/// 一段时间内多次触发只执行最后一次
final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    init(_ delay: TimeInterval) { self.delay = delay }

    func cancel() { work?.cancel(); work = nil }

    func call(_ block: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: block)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}
