import Foundation

/// 日志写 ~/Library/Logs/Rhodeside/rhodeside.log（超过 2MB 轮转一份）。网页的 console 也转发到这里。
enum Log {
    private static let queue = DispatchQueue(label: "rhodeside.log")
    private static var handle: FileHandle?
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func setup() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let file = Paths.logs.appendingPathComponent("rhodeside.log")
        if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 2_000_000 {
            let old = Paths.logs.appendingPathComponent("rhodeside.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: file, to: old)
        }
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        NSSetUncaughtExceptionHandler { e in
            Log.error("未捕获的异常：\(e.name.rawValue) \(e.reason ?? "")\n\(e.callStackSymbols.joined(separator: "\n"))")
            Log.flush()
        }
        // 段错误、Swift 运行时错误等崩溃信号：直接 write(2) 到同一个文件
        CrashTrap.install(fd: handle?.fileDescriptor ?? -1)
    }

    static func info(_ s: @autoclosure () -> String) { write("INFO", s()) }
    // 警告和错误同步写：紧接着崩溃（信号不会 flush）时这几行也在文件里，崩溃后自动上传才看得到
    static func warn(_ s: @autoclosure () -> String) { write("WARN", s(), sync: true) }
    static func error(_ s: @autoclosure () -> String) { write("ERROR", s(), sync: true) }

    static func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private static func write(_ level: String, _ text: String, sync: Bool = false) {
        let line = "\(stamp.string(from: Date())) [\(level)] \(text)\n"
        let work = {
            guard let data = line.data(using: .utf8) else { return }
            if let h = handle { try? h.write(contentsOf: data) } else { FileHandle.standardError.write(data) }
        }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
}
