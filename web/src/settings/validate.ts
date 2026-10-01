/**
 * 导入检查：用 stage/ 的 loader 把每套模型真载一遍（骨骼版本、图集、贴图都要对得上），
 * 全过了才让原生层把文件夹挪进 models/。
 */
import { t } from '../i18n/index.ts'
import { collectSets, fetchSetImages, fetchSkeletons } from '../stage/loader.ts'
import { loadModel } from '../stage/model.ts'
import { groupLabel } from './skins.ts'

export type Verdict = { ok: true; sets: { outfit: string; group: string }[] } | { ok: false; reason: string }

export async function validateImport(base: string, files: string[]): Promise<Verdict> {
  const canvas = document.createElement('canvas')
  canvas.width = 1
  canvas.height = 1
  const gl = canvas.getContext('webgl', { alpha: true, premultipliedAlpha: true })
  if (!gl) return { ok: false, reason: t().stage.noWebGLCheck }
  try {
    const sets = await collectSets(await fetchSkeletons(base, files))
    const ctx = new spine.webgl.ManagedWebGLRenderingContext(gl)
    for (const set of sets) {
      try {
        const m = await loadModel(ctx, await fetchSetImages(base, set), false)
        for (const t of m.textures) t.dispose()
      } catch (err) {
        return { ok: false, reason: t().stage.setFailed(`${set.outfit} · ${groupLabel(set.group)}`, err instanceof Error ? err.message : String(err)) }
      }
    }
    return { ok: true, sets: sets.map((s) => ({ outfit: s.outfit, group: s.group })) }
  } catch (err) {
    return { ok: false, reason: err instanceof Error ? err.message : String(err) }
  } finally {
    gl.getExtension('WEBGL_lose_context')?.loseContext()
  }
}

/** 一个模型有哪些时装组 / 模型组（只下载骨骼和图集，便宜）；按文件列表缓存 */
const cache = new Map<string, Promise<{ outfit: string; group: string }[]>>()

export function modelSets(name: string, files: string[]): Promise<{ outfit: string; group: string }[]> {
  const key = `${name}\u0000${files.join('\u0000')}`
  let p = cache.get(key)
  if (!p) {
    p = fetchSkeletons('./models/', files)
      .then(collectSets)
      .then((sets) => sets.map((s) => ({ outfit: s.outfit, group: s.group })))
    p.catch(() => cache.delete(key))
    cache.set(key, p)
  }
  return p
}
