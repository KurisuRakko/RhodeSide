import Foundation

/// 日志增量上传读到哪了：哪个文件（inode）的第几个字节。
///
/// 日志只在启动时轮转（rhodeside.log 改名成 rhodeside.1.log，inode 跟着走），所以游标记 inode 就能认出
/// 「上次读的那个文件现在叫 .1 了」，把它剩下的部分和新文件一起补上。
public struct LogCursor: Codable, Equatable, Sendable {
    public var file: UInt64
    public var offset: Int64

    public init(file: UInt64, offset: Int64) {
        self.file = file
        self.offset = offset
    }
}

public struct LogFileInfo: Equatable, Sendable {
    public var inode: UInt64
    public var size: Int64

    public init(inode: UInt64, size: Int64) {
        self.inode = inode
        self.size = size
    }
}

public struct LogSlice: Equatable, Sendable {
    public enum Which: Sendable { case current, previous }
    public var which: Which
    public var start: Int64
    public var end: Int64

    public init(_ which: Which, _ start: Int64, _ end: Int64) {
        self.which = which
        self.start = start
        self.end = end
    }

    public var length: Int64 { end - start }
}

public enum LogPlan {
    /// 要读的片段（按时间先后）、读完之后的游标、有没有因为超过 limit 丢掉开头
    public static func slices(cursor: LogCursor?, current: LogFileInfo?, previous: LogFileInfo?, limit: Int64)
        -> (slices: [LogSlice], next: LogCursor?, truncated: Bool)
    {
        guard let current else { return ([], cursor, false) }
        var out: [LogSlice] = []
        if let c = cursor, c.file == current.inode {
            // 同一个文件变短了（被清空过）：从头读
            out.append(LogSlice(.current, c.offset <= current.size ? c.offset : 0, current.size))
        } else {
            if let c = cursor, let p = previous, c.file == p.inode {
                out.append(LogSlice(.previous, c.offset <= p.size ? c.offset : 0, p.size))
            }
            out.append(LogSlice(.current, 0, current.size))
        }
        out = out.filter { $0.length > 0 }

        // 超了只留最后 limit 字节
        var excess = out.reduce(0) { $0 + $1.length } - max(0, limit)
        let truncated = excess > 0
        while excess > 0, !out.isEmpty {
            if out[0].length <= excess {
                excess -= out[0].length
                out.removeFirst()
            } else {
                out[0].start += excess
                excess = 0
            }
        }
        return (out, LogCursor(file: current.inode, offset: current.size), truncated)
    }
}
