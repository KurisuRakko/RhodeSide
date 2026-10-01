import Foundation
import PetCore

/// 模型 = models/ 下的一个文件夹。用户导入的在 Application Support，App 内置的在 Resources；同名时用户的优先。
struct ModelEntry {
    let name: String
    let dir: URL
    let builtin: Bool
    /// 相对 models/ 的路径（`名字/子目录/文件`），和 web/src/stage 的 models/index.json 同一种写法
    let files: [String]
}

enum ModelLibrary {
    /// wav / mp3：voice/ 下的基建语音（fetch-voice.mjs）
    static let extensions: Set<String> = ["skel", "json", "atlas", "txt", "bytes", "png", "webp", "wav", "mp3"]

    static func all() -> [ModelEntry] {
        let user = entries(in: Paths.userModels, builtin: false)
        let names = Set(user.map(\.name))
        let builtin = entries(in: Paths.builtinModels, builtin: true).filter { !names.contains($0.name) }
        return builtin + user
    }

    static func find(_ name: String) -> ModelEntry? {
        guard validName(name) else { return nil }
        for (root, builtin) in [(Paths.userModels, false), (Paths.builtinModels, true)] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            if isDirectory(dir) {
                let files = listFiles(dir, prefix: name)
                if !files.isEmpty { return ModelEntry(name: name, dir: dir, builtin: builtin, files: files) }
            }
        }
        return nil
    }

    /// scheme handler 用：`[模型, 子路径…]` → 文件
    static func resolve(_ parts: [String]) -> URL? {
        guard parts.count >= 2 else { return nil }
        for root in [Paths.userModels, Paths.builtinModels] {
            if let f = SchemeHandler.join(root, parts), FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    static func isUserModel(_ name: String) -> Bool {
        isDirectory(Paths.userModels.appendingPathComponent(name, isDirectory: true))
    }

    /// 导入时起名：和已有的（内置 + 导入）都不重名
    static func uniqueName(_ base: String) -> String {
        let clean = base.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = clean.isEmpty ? tr("未命名模型", "未命名模型", "Untitled model") : clean
        let taken = Set(all().map(\.name))
        if !taken.contains(stem) { return stem }
        var i = 2
        while taken.contains("\(stem) \(i)") { i += 1 }
        return "\(stem) \(i)"
    }

    /// 删除用户导入的模型（挪进废纸篓，删错了还能捡回来）
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    static func delete(_ name: String) throws {
        guard validName(name) else { throw NSError(domain: "Rhodeside", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("模型名不合法", "模型名稱不合法", "Invalid model name")]) }
        let dir = Paths.userModels.appendingPathComponent(name, isDirectory: true)
        guard isDirectory(dir) else { throw NSError(domain: "Rhodeside", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("内置模型不能删", "內置模型不能刪除", "Built-in models can't be deleted")]) }
        try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
    }

    static func listFiles(_ dir: URL, prefix: String) -> [String] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        let base = dir.standardizedFileURL.path
        var out: [String] = []
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  extensions.contains(url.pathExtension.lowercased()) else { continue }
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(base + "/") else { continue }
            out.append(prefix + "/" + p.dropFirst(base.count + 1))
        }
        return out.sorted()
    }

    private static func entries(in root: URL, builtin: Bool) -> [ModelEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            let dir = root.appendingPathComponent(name, isDirectory: true)
            guard !name.hasPrefix("."), isDirectory(dir) else { return nil }
            let files = listFiles(dir, prefix: name)
            return files.isEmpty ? nil : ModelEntry(name: name, dir: dir, builtin: builtin, files: files)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
}
