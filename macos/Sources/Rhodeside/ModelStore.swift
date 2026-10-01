import CryptoKit
import Foundation
import PetCore

/// 在线模型（有授权的模型只放服务器，登录后才能下载）。
///
/// 目录 `v1/models.json` 是和 App / 前端同一把钥匙签的信封（payload.kind = "models"），每个模型：
/// `{id, name, version, path, sha256, size, default, skins, preview}`。version 是模型内容的哈希，内容不变版本就不变。
/// 装在 `models/<name>/`（和导入的模型同一个目录，设置页可以删）；装了哪个版本记在 `models-installed.json`。
/// 下载哪些：只有用户在模型库 / 设置页点过「下载」的，以及已经装着、出了新版本的。登录本身不触发任何下载；
/// default 只是模型库里默认勾上。
/// 预览包（preview）= 默认时装的基建模型，模型库点一下才下，解压到缓存目录 `previews/<id>/`。
enum ModelStore {
    struct Entry: Codable, Equatable {
        let id: String
        let name: String
        let version: String
        let path: String
        let sha256: String
        let size: Int
        let `default`: Bool?
        /// 时装套数（模型库列表里显示）
        let skins: Int?
        let preview: Preview?
        /// 译名：干员名 {en, zh-Hant}、时装 key → {en, zh-Hant}（publish.mjs 写的；老目录没有）。只给界面显示用
        let names: [String: String]?
        let outfits: [String: [String: String]]?
    }

    struct Preview: Codable, Equatable {
        let path: String
        let sha256: String
        let size: Int
    }

    struct Catalog: Codable {
        let schema: Int
        let kind: String
        let build: Int64
        let models: [Entry]
    }

    struct Installed: Codable {
        var id: String
        var version: String
    }

    private static var installedFile: URL { Paths.support.appendingPathComponent("models-installed.json") }
    private static var dismissedFile: URL { Paths.updates.appendingPathComponent("models-dismissed.json") }
    private static var requestedFile: URL { Paths.updates.appendingPathComponent("models-requested.json") }

    static func verify(_ data: Data) throws -> Catalog {
        let payload = try RemoteUpdater.openEnvelope(data)
        guard let c = try? JSONDecoder().decode(Catalog.self, from: payload), c.schema == 1, c.kind == "models" else {
            throw Oops(tr("模型目录格式不对", "模型目錄格式不正確", "Malformed model list"))
        }
        for m in c.models {
            guard m.path.hasPrefix("v1/models/"), !m.path.contains(".."), ModelLibrary.validName(m.name), ModelLibrary.validName(m.id),
                  m.preview.map({ $0.path.hasPrefix("v1/previews/") && !$0.path.contains("..") }) ?? true
            else {
                throw Oops(tr("模型目录里的路径不合法（\(m.id)）", "模型目錄裡的路徑不合法（\(m.id)）", "Invalid path in the model list (\(m.id))"))
            }
        }
        return c
    }

    /* ---------------------------------------------------------------- 本地记录 */

    /// 名字 → 已装的版本（目录被手动删掉的不算）
    static func installed() -> [String: Installed] {
        guard let data = try? Data(contentsOf: installedFile),
              let map = try? JSONDecoder().decode([String: Installed].self, from: data)
        else { return [:] }
        return map.filter { ModelLibrary.isUserModel($0.key) }
    }

    private static func setInstalled(_ name: String, _ v: Installed?) {
        var map = installed()
        map[name] = v
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: installedFile, options: .atomic) }
    }

    private static func readSet(_ f: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: f), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    private static func writeSet(_ s: Set<String>, _ f: URL) {
        if let data = try? JSONEncoder().encode(s.sorted()) { try? data.write(to: f, options: .atomic) }
    }

    static func dismissed() -> Set<String> { readSet(dismissedFile) }
    private static func setDismissed(_ s: Set<String>) { writeSet(s, dismissedFile) }

    /// 用户在设置页删了一个在线模型：不再自动下载它
    static func modelDeleted(_ name: String) {
        guard let rec = installed()[name] else { return }
        setInstalled(name, nil)
        setDismissed(dismissed().union([rec.id]))
        writeSet(readSet(requestedFile).subtracting([rec.id]), requestedFile)
    }

    static func isDismissed(name: String) -> Bool {
        guard let c = lastCatalog, let m = c.models.first(where: { $0.name == name }) else { return false }
        return dismissed().contains(m.id)
    }

    /// 最近一次验过签的目录（给不方便拿 updater 的地方用）
    static var lastCatalog: Catalog?

    static func requested(_ ids: [String]) {
        setDismissed(dismissed().subtracting(ids))
        writeSet(readSet(requestedFile).union(ids), requestedFile)
    }

    /// 这一轮要装 / 更新的模型：用户点过下载的，和已装模型的新版本。登录、桌宠配置都不会自己触发下载
    static func wanted(_ c: Catalog) -> [Entry] {
        let have = installed()
        let skip = dismissed()
        let asked = readSet(requestedFile)
        return c.models.filter { m in
            // 用户删过的不装回来；在模型库点「下载」会清掉这个记录
            guard !skip.contains(m.id) else { return false }
            // 已经装着的在线模型：出了新版本就更新
            if let h = have[m.name] { return h.version != m.version }
            guard asked.contains(m.id) else { return false }
            // 同名的导入模型：用户自己的东西，不覆盖
            return !ModelLibrary.isUserModel(m.name)
        }
    }


    /* ---------------------------------------------------------------- 安装 */

    /// 解压到 updates/model-<id>，确认里面正好是 `<name>/` 且有文件，再整个换进 models/
    static func install(_ archive: URL, _ m: Entry) throws {
        let fm = FileManager.default
        let work = Paths.updates.appendingPathComponent("model-\(m.id)", isDirectory: true)
        try untar(archive, into: work)
        defer { try? fm.removeItem(at: work) }
        let top = (try? fm.contentsOfDirectory(atPath: work.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard top == [m.name] else { throw Oops(tr("模型包内容不对（应只有「\(m.name)」一个文件夹）", "模型套件內容不正確（應只有「\(m.name)」一個檔案夾）", "Unexpected model package contents (should be a single \"\(m.name)\" folder)")) }
        let src = work.appendingPathComponent(m.name, isDirectory: true)
        guard !ModelLibrary.listFiles(src, prefix: m.name).isEmpty else { throw Oops(tr("模型包里没有模型文件", "模型套件裡沒有模型檔案", "The model package has no model files")) }
        let dest = Paths.userModels.appendingPathComponent(m.name, isDirectory: true)
        let old = Paths.updates.appendingPathComponent("model-\(m.id).old", isDirectory: true)
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: dest.path) { try fm.moveItem(at: dest, to: old) }
        do {
            try fm.moveItem(at: src, to: dest)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dest) }
            throw error
        }
        try? fm.removeItem(at: old)
        setInstalled(m.name, Installed(id: m.id, version: m.version))
        // 装上了就不再算「请求过」：以后在访达里手动删掉目录，不会被自动下回来
        writeSet(readSet(requestedFile).subtracting([m.id]), requestedFile)
    }

    /* ---------------------------------------------------------------- 预览 */

    /// 缓存里的预览：`previews/<id>/` 下的文件（相对 previews/，带 <id>/ 前缀）；版本不对就当没有
    static func cachedPreview(_ m: Entry) -> [String]? {
        let dir = Paths.previews.appendingPathComponent(m.id, isDirectory: true)
        guard (try? String(contentsOf: dir.appendingPathComponent(".version"), encoding: .utf8)) == m.version else { return nil }
        let files = ModelLibrary.listFiles(dir, prefix: m.id)
        return files.isEmpty ? nil : files
    }

    /// 预览包里只有一个顶层文件夹 `<name>/`，里面是默认时装的基建模型；解压后把它的内容放进 `previews/<id>/`
    static func installPreview(_ archive: URL, _ m: Entry) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.previews, withIntermediateDirectories: true)
        let work = Paths.previews.appendingPathComponent(".\(m.id).incoming", isDirectory: true)
        try untar(archive, into: work)
        defer { try? fm.removeItem(at: work) }
        let top = (try? fm.contentsOfDirectory(atPath: work.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard top == [m.name] else { throw Oops(tr("预览包内容不对", "預覽套件內容不正確", "Unexpected preview package contents")) }
        let src = work.appendingPathComponent(m.name, isDirectory: true)
        try m.version.write(to: src.appendingPathComponent(".version"), atomically: true, encoding: .utf8)
        let dest = Paths.previews.appendingPathComponent(m.id, isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: src, to: dest)
        guard let files = cachedPreview(m) else { throw Oops(tr("预览包里没有模型文件", "預覽套件裡沒有模型檔案", "The preview package has no model files")) }
        return files
    }

    /// 设置页 / 引导页用；点了下载、还在排队的是 queued
    static func status(_ c: Catalog?, downloading: String?, failed: [String: String]) -> [[String: Any]] {
        let have = installed()
        let asked = readSet(requestedFile)
        return (c?.models ?? []).map { m in
            let state: String
            if downloading == m.id { state = "downloading" }
            else if let h = have[m.name] { state = h.version == m.version ? "installed" : "outdated" }
            else if failed[m.id] != nil { state = "failed" }
            else if asked.contains(m.id) { state = "queued" }
            else { state = "available" }
            var d: [String: Any] = [
                "id": m.id, "name": m.name, "size": m.size, "default": m.default == true, "skins": m.skins ?? 0,
                "preview": m.preview != nil, "state": state, "error": failed[m.id] ?? NSNull(),
            ]
            if let n = m.names { d["names"] = n }
            if let o = m.outfits { d["outfits"] = o }
            return d
        }
    }
}
