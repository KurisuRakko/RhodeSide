/**
 * 模型载入与测量：模型库预览（engine.ts）、桌宠页（pet/main.ts）和导入检查（settings/validate.ts）共用。
 *
 *   - loadModel：一套 ModelSet → 贴图（统一转成预乘 alpha 上传）+ SkeletonData + 动画角色 + 包围盒
 *   - detectRoles：按常见命名认出待机 / 走 / 互动 / 坐 / 睡
 *   - boundsOf / unite：包围盒工具（骨骼单位，y 向上）
 */
import { t } from '../i18n/index.ts'
import { alphaCompanion, atlasPages, atlasPageSizes, dirOf, findFile, skeletonVersion, type ModelSet } from './loader.ts'

export interface Roles {
  idle: string | null
  move: string | null
  interact: string | null
  sit: string | null
  sleep: string | null
}

export interface Box {
  x: number
  y: number
  w: number
  h: number
}

export interface LoadedModel {
  set: ModelSet
  data: any
  textures: any[]
  animations: { name: string; duration: number }[]
  skins: string[]
  roles: Roles
  version: string | null
  /** 待机姿势的包围盒（骨骼单位） */
  rest: Box
  /** 全部动画采样后的并集包围盒（查看模式取景用） */
  union: Box
}

const ROLE_NAMES: Record<keyof Roles, string[]> = {
  idle: ['relax', 'idle', 'default', 'stand', 'wait'],
  move: ['move', 'move_loop', 'walk', 'run'],
  interact: ['interact', 'special', 'touch', 'jump'],
  sit: ['sit'],
  sleep: ['sleep'],
}

export function detectRoles(names: string[]): Roles {
  const lower = names.map((n) => n.toLowerCase())
  const pick = (keys: string[], fuzzy: boolean) => {
    for (const k of keys) {
      const i = lower.indexOf(k)
      if (i >= 0) return names[i]
    }
    if (!fuzzy) return null
    for (const k of keys) {
      const i = lower.findIndex((n) => n.includes(k))
      if (i >= 0) return names[i]
    }
    return null
  }
  return {
    idle: pick(ROLE_NAMES.idle, true) ?? names[0] ?? null,
    move: pick(ROLE_NAMES.move, true),
    interact: pick(ROLE_NAMES.interact, false),
    sit: pick(ROLE_NAMES.sit, false),
    sleep: pick(ROLE_NAMES.sleep, false),
  }
}

type Size = { w: number; h: number }

// 解码一张贴图；给了 size（atlas 声明的页面尺寸）且对不上时拉回声明尺寸。
// 3.8 运行时拿贴图真实宽高去除 atlas 坐标（region 和 mesh 都是），贴图被缩放过（比如 PRTS 发的是缩小版）
// 时 UV 全错、模型碎成一片片。先试 createImageBitmap 的 resize 选项，浏览器不认（会静默忽略）就用 canvas 拉伸。
async function decode(blob: Blob, premultiplyAlpha: PremultiplyAlpha, size?: Size): Promise<ImageBitmap> {
  const mode: ImageBitmapOptions = { colorSpaceConversion: 'none', premultiplyAlpha }
  const fits = (b: ImageBitmap) => !size || (b.width === size.w && b.height === size.h)
  const bmp = await createImageBitmap(blob, mode)
  if (fits(bmp) || !size) return bmp
  bmp.close()
  const resized = await createImageBitmap(blob, { ...mode, resizeWidth: size.w, resizeHeight: size.h, resizeQuality: 'high' })
  if (fits(resized)) return resized
  const canvas = document.createElement('canvas')
  canvas.width = size.w
  canvas.height = size.h
  const g = canvas.getContext('2d')
  if (!g) throw new Error(t().stage.no2dScale)
  g.imageSmoothingQuality = 'high'
  g.drawImage(resized, 0, 0, size.w, size.h)
  resized.close()
  return createImageBitmap(canvas, mode)
}

async function textureSource(blob: Blob, alpha: Blob | undefined, pma: boolean, size?: Size): Promise<ImageBitmap> {
  // ImageBitmap 上传到 WebGL 时忽略 UNPACK_PREMULTIPLY_ALPHA，按位图自己的 premultiplyAlpha 来：
  // 直通 alpha 的图让浏览器预乘，本来就是 PMA 的图原样上传。
  if (!alpha) return decode(blob, pma ? 'none' : 'premultiply', size)

  // 分离的透明通道（名字[alpha].png）：RGB 取主图、A 取透明图的 R，合成一张直通 alpha 的图
  const [rgb, a] = await Promise.all([decode(blob, 'none', size), decode(alpha, 'none', size)])
  const canvas = document.createElement('canvas')
  canvas.width = rgb.width
  canvas.height = rgb.height
  const g = canvas.getContext('2d', { willReadFrequently: true })
  if (!g) throw new Error(t().stage.no2dAlpha)
  g.drawImage(rgb, 0, 0)
  const base = g.getImageData(0, 0, canvas.width, canvas.height)
  g.clearRect(0, 0, canvas.width, canvas.height)
  g.drawImage(a, 0, 0, canvas.width, canvas.height)
  const mask = g.getImageData(0, 0, canvas.width, canvas.height).data
  for (let i = 0; i < base.data.length; i += 4) base.data[i + 3] = mask[i]
  rgb.close()
  a.close()
  return createImageBitmap(base, { colorSpaceConversion: 'none', premultiplyAlpha: 'premultiply' })
}

export function boundsOf(skeleton: any, offset: any, size: any, temp: number[]): Box | null {
  skeleton.getBounds(offset, size, temp)
  if (!Number.isFinite(offset.x) || !Number.isFinite(size.x) || size.x <= 0 || size.y <= 0) return null
  return { x: offset.x, y: offset.y, w: size.x, h: size.y }
}

export function unite(a: Box | null, b: Box | null): Box | null {
  if (!a) return b
  if (!b) return a
  const x = Math.min(a.x, b.x)
  const y = Math.min(a.y, b.y)
  return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y }
}

/** 载入一套模型：`ctx` 是 spine.webgl.ManagedWebGLRenderingContext。失败时已上传的贴图会释放。 */
export async function loadModel(ctx: any, set: ModelSet, pma: boolean): Promise<LoadedModel> {
  const version = await skeletonVersion(set.skeleton)
  if (version && !version.startsWith('3.8')) {
    throw new Error(t().stage.wrongVersion(version))
  }
  const atlasText = await set.atlas.blob.text()
  const dir = dirOf(set.atlas.path)
  const byPage = new Map<string, any>()
  const textures: any[] = []
  try {
    const sizes = atlasPageSizes(atlasText)
    // atlas 写的尺寸超出显卡上限时不拉伸（上传也会失败），宁可照原图画
    const max = ctx.gl.getParameter(ctx.gl.MAX_TEXTURE_SIZE) as number
    const fitSize = (sz?: Size) => (sz && sz.w <= max && sz.h <= max ? sz : undefined)
    for (const page of atlasPages(atlasText)) {
      const file = findFile(set.files, dir, page)
      if (!file) throw new Error(t().stage.missingPage(page))
      const alpha = alphaCompanion(set.files, dir, page)
      const tex = new spine.webgl.GLTexture(ctx, await textureSource(file.blob, alpha?.blob, pma, fitSize(sizes.get(page))))
      textures.push(tex)
      byPage.set(page, tex)
    }
    const atlas = new spine.TextureAtlas(atlasText, (page: string) => {
      const tex = byPage.get(page)
      if (!tex) throw new Error(t().stage.missingTexture(page))
      return tex
    })
    const loader = new spine.AtlasAttachmentLoader(atlas)
    const data = /\.json$/i.test(set.skeleton.path)
      ? new spine.SkeletonJson(loader).readSkeletonData(await set.skeleton.blob.text())
      : new spine.SkeletonBinary(loader).readSkeletonData(new Uint8Array(await set.skeleton.blob.arrayBuffer()))

    const animations = (data.animations as any[]).map((a) => ({ name: a.name as string, duration: a.duration as number }))
    const roles = detectRoles(animations.map((a) => a.name))
    const { rest, union } = measure(data, roles, animations)
    return {
      set,
      data,
      textures,
      animations,
      skins: (data.skins as any[]).map((s) => s.name as string),
      roles,
      version,
      rest,
      union,
    }
  } catch (err) {
    for (const t of textures) t.dispose()
    throw err instanceof Error ? err : new Error(String(err))
  }
}

/** 待机姿势的包围盒 + 所有动画采样后的并集（骨骼单位，朝右、根骨骼在原点）。 */
function measure(data: any, roles: Roles, animations: { name: string; duration: number }[]) {
  const offset = new spine.Vector2()
  const size = new spine.Vector2()
  const temp: number[] = [0, 0]
  const skeleton = new spine.Skeleton(data)
  const state = new spine.AnimationState(new spine.AnimationStateData(data))
  const sample = (name: string | null, steps: number): Box | null => {
    skeleton.setToSetupPose()
    state.clearTracks()
    if (!name) {
      skeleton.updateWorldTransform()
      return boundsOf(skeleton, offset, size, temp)
    }
    const entry = state.setAnimation(0, name, true)
    const duration = entry.animation.duration || 0
    let box: Box | null = null
    for (let i = 0; i < steps; i += 1) {
      state.update(i === 0 ? 0 : duration / steps)
      state.apply(skeleton)
      skeleton.updateWorldTransform()
      box = unite(box, boundsOf(skeleton, offset, size, temp))
      if (duration === 0) break
    }
    return box
  }
  const rest = sample(roles.idle, 1) ?? sample(null, 1) ?? { x: -50, y: 0, w: 100, h: 100 }
  const steps = animations.length > 24 ? 4 : 8
  let union: Box | null = rest
  for (const a of animations) union = unite(union, sample(a.name, steps))
  return { rest, union: union ?? rest }
}
