import Foundation

struct Oops: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// 导入模型：先把用户选的文件夹（只拷模型相关的文件）复制到 import/<批次>/<名字>/，
/// 让设置页用 SpineStage 的 loader 经 rhodeside-res:// 真载一遍检查，通过了再挪进 models/。
final class Importer {
    struct Job {
        let token: String
        let name: String
        let dir: URL
        let files: [String]
    }

    static let maxBytes = 512 * 1024 * 1024
    private var jobs: [String: Job] = [:]

    /// 上次没收尾的导入临时目录，启动时清掉
    static func cleanupStale() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: Paths.imports, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
    }

    /// 文件夹每个算一个模型；零散的文件合起来算一个
    func stage(_ urls: [URL]) -> (jobs: [Job], errors: [String]) {
        var out: [Job] = []
        var errors: [String] = []
        let dirs = urls.filter(isDirectory)
        let files = urls.filter { !isDirectory($0) }
        for d in dirs {
            do { out.append(try stage(sources: [d], name: d.lastPathComponent, keepStructureOf: d)) } catch {
                errors.append("\(d.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !files.isEmpty {
            do { out.append(try stage(sources: files, name: Self.name(forFiles: files), keepStructureOf: nil)) } catch {
                errors.append(error.localizedDescription)
            }
        }
        for j in out { jobs[j.token] = j }
        return (out, errors)
    }

    func commit(_ token: String) throws -> String {
        guard let job = jobs.removeValue(forKey: token) else { throw Oops("导入任务已失效，请重新导入") }
        let final = ModelLibrary.uniqueName(job.name)
        try FileManager.default.moveItem(at: job.dir, to: Paths.userModels.appendingPathComponent(final, isDirectory: true))
        try? FileManager.default.removeItem(at: Paths.imports.appendingPathComponent(token))
        Log.info("导入模型「\(final)」（\(job.files.count) 个文件）")
        return final
    }

    func abort(_ token: String) {
        jobs[token] = nil
        try? FileManager.default.removeItem(at: Paths.imports.appendingPathComponent(token))
    }

    private func stage(sources: [URL], name: String, keepStructureOf root: URL?) throws -> Job {
        let fm = FileManager.default
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let dest = Paths.imports.appendingPathComponent(token).appendingPathComponent(name, isDirectory: true)
        // 要拷的文件：(源, 目标里的相对路径)
        var todo: [(URL, String)] = []
        for src in sources {
            if let root {
                guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
                let base = root.standardizedFileURL.path
                for case let url as URL in en where ModelLibrary.extensions.contains(url.pathExtension.lowercased()) {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    let p = url.standardizedFileURL.path
                    guard p.hasPrefix(base + "/") else { continue }
                    todo.append((url, String(p.dropFirst(base.count + 1))))
                }
            } else if ModelLibrary.extensions.contains(src.pathExtension.lowercased()) {
                todo.append((src, src.lastPathComponent))
            }
        }
        guard !todo.isEmpty else { throw Oops("未找到模型文件（.skel / .json / .atlas / .png）") }
        var seen = Set<String>()
        for (_, rel) in todo where !seen.insert(rel.lowercased()).inserted {
            throw Oops("有两个同名文件「\(rel)」，请分别放进各自的文件夹再导入")
        }
        let total = todo.reduce(0) { $0 + ((try? $1.0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        guard total <= Self.maxBytes else { throw Oops("文件过大（\(total / 1_048_576) MB），上限 \(Self.maxBytes / 1_048_576) MB") }
        do {
            for (src, rel) in todo {
                let to = dest.appendingPathComponent(rel)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: to)
            }
        } catch {
            try? fm.removeItem(at: Paths.imports.appendingPathComponent(token))
            throw Oops("复制文件失败：\(error.localizedDescription)")
        }
        return Job(token: token, name: name, dir: dest, files: ModelLibrary.listFiles(dest, prefix: name))
    }

    /// 零散文件起名：第一个骨骼文件的名字（去掉 build_ 前缀）
    static func name(forFiles files: [URL]) -> String {
        let skel = files.first { ["skel", "json"].contains($0.pathExtension.lowercased()) } ?? files[0]
        var stem = skel.deletingPathExtension().lastPathComponent
        if stem.lowercased().hasSuffix(".skel") { stem = String(stem.dropLast(5)) }
        if stem.lowercased().hasPrefix("build_") { stem = String(stem.dropFirst(6)) }
        return stem.isEmpty ? "未命名模型" : stem
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
