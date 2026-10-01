/**
 * 模型文件整理：把一堆 { path, blob }（从壳的 models/、previews/、导入目录 fetch 到的）
 * 按骨骼文件分成若干「模型套」，再按 PRTS 的习惯归到「时装组 × 模型组」：
 *   - 骨骼：.skel / .skel.bytes（二进制）或 .json（含 skeleton + bones 的才算）
 *   - 图集：同目录同名的 .atlas / .atlas.txt；找不到就用同目录唯一的那个
 *   - 贴图：按 atlas 里写的页名找；另有 `名字[alpha].png` / `名字_alpha.png` 时当作分离的透明通道合并
 * 时装 key = 文件名去掉 build_ 前缀；模型组：build_ → 基建，路径里有 back/背面 → 背面，其余 → 正面。
 */

import { t } from '../i18n/index.ts'

export interface SourceFile {
  /** 相对 base 的路径，用 / 分隔 */
  path: string
  blob: Blob
}

export interface ModelSet {
  id: string
  outfit: string
  group: string
  skeleton: SourceFile
  atlas: SourceFile
  files: SourceFile[]
}

const SKEL_RE = /\.(skel(\.bytes)?|json)$/i
const ATLAS_RE = /\.atlas(\.txt)?$/i

const dirOf = (p: string) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/') + 1) : '')
const baseOf = (p: string) => p.slice(p.lastIndexOf('/') + 1)
const stemOf = (p: string) => baseOf(p).replace(SKEL_RE, '').replace(ATLAS_RE, '')

function groupOf(path: string, stem: string): string {
  if (/^build_/i.test(stem) || /(^|\/)(build|基建)(\/|$)/i.test(path)) return '基建'
  if (/(^|[/_\-.])(back|背面)([/_\-.]|$)/i.test(path)) return '背面'
  return '正面'
}

async function isSkeletonJson(file: SourceFile): Promise<boolean> {
  if (!/\.json$/i.test(file.path)) return true
  try {
    const head = await file.blob.slice(0, 4096).text()
    return /"skeleton"\s*:/.test(head) || /"bones"\s*:/.test(head)
  } catch {
    return false
  }
}

/** 把一堆文件整理成模型套；一个都凑不齐时抛出可读的错误。 */
export async function collectSets(files: SourceFile[]): Promise<ModelSet[]> {
  const skels: SourceFile[] = []
  for (const f of files) if (SKEL_RE.test(f.path) && (await isSkeletonJson(f))) skels.push(f)
  const atlases = files.filter((f) => ATLAS_RE.test(f.path))
  if (skels.length === 0) throw new Error(t().stage.noSkeleton)
  if (atlases.length === 0) throw new Error(t().stage.noAtlas)

  const sets: ModelSet[] = []
  const seen = new Map<string, number>()
  for (const skel of skels) {
    const dir = dirOf(skel.path)
    const stem = stemOf(skel.path)
    const sameDir = atlases.filter((a) => dirOf(a.path) === dir)
    const atlas =
      sameDir.find((a) => stemOf(a.path) === stem) ??
      (sameDir.length === 1 ? sameDir[0] : undefined) ??
      atlases.find((a) => stemOf(a.path) === stem)
    if (!atlas) continue

    const outfit = stem.replace(/^build_/i, '')
    let group = groupOf(skel.path, stem)
    const key = `${outfit}\u0000${group}`
    const n = (seen.get(key) ?? 0) + 1
    seen.set(key, n)
    if (n > 1) group = `${group} ${n}`
    sets.push({ id: `${skel.path}|${atlas.path}`, outfit, group, skeleton: skel, atlas, files })
  }
  if (sets.length === 0) throw new Error(t().stage.mismatch)

  const order = ['正面', '背面', '基建']
  const rank = (g: string) => {
    const i = order.indexOf(g.split(' ')[0])
    return i < 0 ? order.length : i
  }
  return sets.sort((a, b) => a.outfit.localeCompare(b.outfit) || rank(a.group) - rank(b.group))
}

/** atlas（libgdx 格式）的页名：空行之后的第一行。 */
export function atlasPages(text: string): string[] {
  const lines = text.split(/\r?\n/)
  const pages: string[] = []
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim()
    if (line && (i === 0 || lines[i - 1].trim() === '') && !line.includes(':')) pages.push(line)
  }
  return pages
}

/** atlas 里每页声明的 `size: w,h`（没写就不在表里）。 */
export function atlasPageSizes(text: string): Map<string, { w: number; h: number }> {
  const lines = text.split(/\r?\n/)
  const sizes = new Map<string, { w: number; h: number }>()
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim()
    if (!line || !(i === 0 || lines[i - 1].trim() === '') || line.includes(':')) continue
    // 页头是页名下面连续的 `key: value` 行，size 不一定排第一
    for (let j = i + 1; j < lines.length && lines[j].includes(':'); j += 1) {
      const m = /^size:\s*(\d+)\s*,\s*(\d+)/.exec(lines[j].trim())
      if (m) {
        sizes.set(line, { w: Number(m[1]), h: Number(m[2]) })
        break
      }
    }
  }
  return sizes
}

/** 在文件堆里按「相对 atlas 目录的路径 → 同名文件」的顺序找贴图。 */
export function findFile(files: SourceFile[], fromDir: string, name: string): SourceFile | undefined {
  const want = (fromDir + name).replace(/\/\.\//g, '/')
  return (
    files.find((f) => f.path === want) ??
    files.find((f) => f.path.toLowerCase() === want.toLowerCase()) ??
    files.find((f) => baseOf(f.path).toLowerCase() === baseOf(name).toLowerCase())
  )
}

export function alphaCompanion(files: SourceFile[], fromDir: string, page: string): SourceFile | undefined {
  const dot = page.lastIndexOf('.')
  const stem = dot > 0 ? page.slice(0, dot) : page
  const ext = dot > 0 ? page.slice(dot) : '.png'
  for (const name of [`${stem}[alpha]${ext}`, `${stem}_alpha${ext}`, `${stem}.alpha${ext}`]) {
    const hit = findFile(files, fromDir, name)
    if (hit) return hit
  }
  return undefined
}

export { dirOf, baseOf }

/** 读骨骼文件头里的 Spine 版本号（JSON 的 skeleton.spine；二进制在前 64 字节里按 x.y.z 找）。 */
export async function skeletonVersion(file: SourceFile): Promise<string | null> {
  if (/\.json$/i.test(file.path)) {
    const head = await file.blob.slice(0, 4096).text()
    return head.match(/"spine"\s*:\s*"([^"]+)"/)?.[1] ?? null
  }
  const bytes = new Uint8Array(await file.blob.slice(0, 64).arrayBuffer())
  const text = Array.from(bytes, (b) => (b >= 32 && b < 127 ? String.fromCharCode(b) : ' ')).join('')
  return text.match(/\b(\d\.\d{1,2}\.\d{1,3})\b/)?.[1] ?? null
}

/* ------------------------------------------------------------------ models/ 目录（清单） */

export interface ManifestEntry {
  name: string
  /** 相对 models/ 的文件路径列表 */
  files: string[]
}

export async function fetchManifest(base: string): Promise<ManifestEntry[]> {
  try {
    const res = await fetch(`${base}index.json`, { cache: 'no-cache' })
    if (!res.ok) return []
    const data: unknown = await res.json()
    if (!Array.isArray(data)) return []
    return data.filter(
      (e): e is ManifestEntry =>
        !!e && typeof e.name === 'string' && Array.isArray(e.files) && e.files.every((f: unknown) => typeof f === 'string'),
    )
  } catch {
    return []
  }
}

/* ------------------------------------------------------------------ 按需下载（桌宠：只拉要显示的那套的贴图） */

const fetchBlob = async (base: string, path: string): Promise<Blob> => {
  const res = await fetch(base + path.split('/').map(encodeURIComponent).join('/'))
  if (!res.ok) throw new Error(t().stage.readFailed(path, res.status))
  return res.blob()
}

/** 只下载骨骼和图集（都很小），贴图先放空 Blob 占位；够 collectSets 分组用。 */
export async function fetchSkeletons(base: string, paths: string[]): Promise<SourceFile[]> {
  return Promise.all(
    paths.map(async (path) => ({
      path,
      blob: SKEL_RE.test(path) || ATLAS_RE.test(path) ? await fetchBlob(base, path) : new Blob(),
    })),
  )
}

/** 给选中的那套补上它 atlas 里用到的贴图（含分离的透明通道）。 */
export async function fetchSetImages(base: string, set: ModelSet): Promise<ModelSet> {
  const text = await set.atlas.blob.text()
  const dir = dirOf(set.atlas.path)
  const need = new Set<SourceFile>()
  for (const page of atlasPages(text)) {
    for (const f of [findFile(set.files, dir, page), alphaCompanion(set.files, dir, page)]) if (f) need.add(f)
  }
  const fetched = new Map<SourceFile, Blob>()
  await Promise.all([...need].map(async (f) => fetched.set(f, await fetchBlob(base, f.path))))
  const files = set.files.map((f) => (fetched.has(f) ? { path: f.path, blob: fetched.get(f)! } : f))
  const swap = (f: SourceFile) => files[set.files.indexOf(f)] ?? f
  return { ...set, files, skeleton: swap(set.skeleton), atlas: swap(set.atlas) }
}
