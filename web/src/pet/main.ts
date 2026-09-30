/**
 * Rhodeside 桌宠渲染页：原生层（Swift）管位置和行为，这一页只按命令画一只小人。
 *
 * 画布铺满整个透明窗口。窗口是横跨所在屏幕的一条带子，原生层每帧发 `pos`（脚在窗口里的横坐标 + 速度），
 * 这里在两次更新之间按速度外推；还没收到 `pos`（或窗口宽度对不上）时画在正中间。脚底高度固定是 layout.footY。
 * 尺寸单位一律是 CSS px（= macOS 的 pt），原点在画布左下角、y 向上，和 AppKit 的窗口坐标一致。
 *
 * 消息收发走 native/transport.ts（原生 → 页面 `window.rhodeside.receive(msg)`，页面 → 原生 `post(msg)`）。
 * 不在 Rhodeside 里（普通浏览器打开 pet.html）时是调试模式：消息打到 console，
 * 按 `?model=&outfit=&group=&height=` 自动从 models/ 载入。
 */
import { collectSets, fetchManifest, fetchSetImages, fetchSkeletons, type ModelSet } from '../stage/loader.ts'
import { boundsOf, loadModel, type Box, type LoadedModel } from '../stage/model.ts'
import { detectCombos } from '../stage/combos.ts'
import { listen, native, post as postNative } from '../native/transport.ts'
import { fetchVoice, pauseVoice, primeAudio, setVoice, useVoice, voiceTouch, type VoiceSettings } from './voice.ts'

type LoadMsg = {
  type: 'load'
  /** 相对 base 的文件路径（和 models/index.json 的 files 同一种写法） */
  base: string
  files: string[]
  outfit?: string
  group?: string
  pma?: boolean
  /** 待机姿势的高度（pt） */
  height?: number
  /** 模型名，原样放回 loaded 里 */
  model?: string
  /** 全局语音设置（开关 / 音量） */
  voice?: VoiceSettings
}

type Incoming =
  | LoadMsg
  | { type: 'play'; name: string; loop?: boolean }
  | { type: 'face'; dir: number }
  | { type: 'speed'; value: number }
  | { type: 'snapshot'; id: string }
  | { type: 'scale'; height: number }
  | { type: 'hit'; id: number; x: number; y: number }
  | { type: 'fps'; value: number }
  | { type: 'pause'; paused: boolean }
  | { type: 'pos'; x: number; vx: number; w: number }
  | { type: 'touch' }
  | ({ type: 'voice' } & VoiceSettings)

interface Layout {
  /** 窗口该有的大小：所有动画、两个朝向都装得下 */
  w: number
  h: number
  /** 脚底锚点在窗口里的位置（footX 恒为 w / 2） */
  footX: number
  footY: number
}

const PAD = 4
const DEFAULT_HEIGHT = 120

/* ------------------------------------------------------------------ 桥 */

function post(msg: Record<string, unknown>) {
  if (!postNative(msg) && msg.type !== 'bounds') console.debug('[rhodeside ←]', msg)
}

const fmt = (v: unknown): string => {
  if (v instanceof Error) return `${v.message}${v.stack ? `\n${v.stack}` : ''}`
  if (typeof v === 'string') return v
  try {
    return JSON.stringify(v)
  } catch {
    return String(v)
  }
}

if (native) {
  // console 转发给原生层写进日志文件（ssh 上只能看日志）
  for (const level of ['log', 'info', 'warn', 'error'] as const) {
    const orig = console[level].bind(console)
    console[level] = (...args: unknown[]) => {
      orig(...args)
      try {
        post({ type: 'log', level, text: args.map(fmt).join(' ') })
      } catch {
        /* 桥断了就算了 */
      }
    }
  }
}
window.addEventListener('error', (e) => post({ type: 'error', text: `${e.message} @ ${e.filename}:${e.lineno}` }))
window.addEventListener('unhandledrejection', (e) => post({ type: 'error', text: `未处理的 Promise 拒绝：${fmt(e.reason)}` }))

/* ------------------------------------------------------------------ 渲染 */

const canvas = document.getElementById('pet') as HTMLCanvasElement
const gl = canvas.getContext('webgl', {
  alpha: true,
  premultipliedAlpha: true,
  // 不开 MSAA：带子窗口的画布是整屏宽，多重采样白占显存；Spine 的边缘靠贴图 alpha，本来就不锯齿
  antialias: false,
  // 不保留帧缓冲（保留会让每帧多一次整屏拷贝）：点击判定和快照都排到渲染完的同一帧里读
  preserveDrawingBuffer: false,
})
if (!gl) {
  post({ type: 'error', text: '这个 WebView 不支持 WebGL' })
  throw new Error('WebGL 不可用')
}
const ctx = new spine.webgl.ManagedWebGLRenderingContext(gl)
const renderer = new spine.webgl.SceneRenderer(canvas, ctx, true)
const offset = new spine.Vector2()
const size = new spine.Vector2()
const temp: number[] = [0, 0]

let model: LoadedModel | null = null
let skeleton: any = null
let state: any = null
let layout: Layout | null = null
let scale = 1
let dir: 1 | -1 = 1
let speed = 1
let pendingFaced = false
let loadSeq = 0
let cssW = 1
let cssH = 1
let last = 0
let lastBounds = 0
let sentBounds = ''
let posX = 0
let posVX = 0
let posW = 0
let posAt = 0
let sizeKey = ''
/** 等下一帧渲染完再回答的点击判定 / 快照 */
const pendingHits: { id: number; x: number; y: number }[] = []
const pendingSnapshots: string[] = []
let paused = false
/** 限帧（毫秒，0 = 不限）：原生层在站着、坐着、睡觉时让它降到 30fps */
let minFrameMs = 0

function computeLayout(m: LoadedModel, s: number): Layout {
  const u = m.union
  // 翻转以根骨骼（x = 0）为轴镜像：宽度按两侧里更远的那边取，朝哪边都不会被窗口裁掉
  const half = Math.max(Math.abs(u.x), Math.abs(u.x + u.w)) * s
  const w = Math.ceil(2 * (half + PAD))
  const h = Math.ceil(u.h * s + 2 * PAD)
  return { w, h, footX: w / 2, footY: (m.rest.y - u.y) * s + PAD }
}

/** 骨骼单位的盒子 → pt，并以脚底锚点为原点 */
function toPt(b: Box, m: LoadedModel, s: number) {
  return { x: b.x * s, y: (b.y - m.rest.y) * s, w: b.w * s, h: b.h * s }
}

function pickSet(sets: ModelSet[], outfit?: string, group?: string): ModelSet {
  const byOutfit = sets.filter((x) => x.outfit === outfit)
  // 没指定（或不认识）时装：先挑默认时装（PRTS 的 defaultskin/ 目录），没有再全部里挑
  const fallback = sets.filter((x) => /(^|\/)defaultskin\//i.test(x.skeleton.path))
  const pool = byOutfit.length ? byOutfit : fallback.length ? fallback : sets
  return (
    pool.find((x) => x.group === group) ??
    pool.find((x) => x.group === '基建') ??
    pool.find((x) => x.group === '正面') ??
    pool[0]
  )
}

async function load(msg: LoadMsg) {
  const seq = ++loadSeq
  const voice = fetchVoice(msg.base, msg.files)
  try {
    const sets = await collectSets(await fetchSkeletons(msg.base, msg.files))
    const chosen = pickSet(sets, msg.outfit, msg.group)
    const next = await loadModel(ctx, await fetchSetImages(msg.base, chosen), !!msg.pma)
    if (seq !== loadSeq) {
      for (const t of next.textures) t.dispose()
      return
    }
    const old = model
    model = next
    skeleton = new spine.Skeleton(next.data)
    const skin = next.skins.includes('default') ? 'default' : next.skins[0]
    if (skin) skeleton.setSkinByName(skin)
    skeleton.setToSetupPose()
    const stateData = new spine.AnimationStateData(next.data)
    stateData.defaultMix = 0.2
    state = new spine.AnimationState(stateData)
    state.addListener({
      complete: (entry: any) => {
        // 只报当前那条：被新动画打断、正在淡出的旧条目播到头也会发 complete，别让它提前结束新的一步
        if (!entry.loop && entry === state.getCurrent(0)) post({ type: 'animDone', name: entry.animation.name })
      },
    })
    // 先放待机，别露出绑定姿势；原生层收到 loaded 后再按行为发 play
    if (next.roles.idle) state.setAnimation(0, next.roles.idle, true)
    if (old) for (const t of old.textures) t.dispose()

    const height = msg.height && msg.height > 0 ? msg.height : DEFAULT_HEIGHT
    scale = height / next.rest.h
    layout = computeLayout(next, scale)
    sentBounds = '' // 原生层收到 loaded 会清掉 bounds，要重新报
    post({
      type: 'loaded',
      model: msg.model ?? null,
      outfit: chosen.outfit,
      group: chosen.group,
      sets: sets.map((x) => ({ outfit: x.outfit, group: x.group })),
      roles: next.roles,
      animations: next.animations,
      // 战斗模型的套组动作（控制面板按钮）；基建模型一般是空的，用不用由原生层按模型组决定
      combos: detectCombos(next.animations),
      skins: next.skins,
      version: next.version,
      scale,
      layout,
      rest: toPt(next.rest, next, scale),
      union: toPt(next.union, next, scale),
    })
    const voiceSet = await voice
    if (seq === loadSeq) void useVoice(voiceSet, msg.model ?? msg.files[0]?.split('/')[0] ?? '', chosen.group)
  } catch (err) {
    if (seq === loadSeq) post({ type: 'error', stage: 'load', text: fmt(err) })
  }
}

/** 只在窗口尺寸或缩放变了时重设画布（innerWidth 不触发排版，clientWidth 可能会） */
function resize() {
  const dpr = Math.min(window.devicePixelRatio || 1, 3)
  const w = Math.max(1, window.innerWidth)
  const h = Math.max(1, window.innerHeight)
  const key = `${w}x${h}@${dpr}`
  if (key === sizeKey) return
  sizeKey = key
  const pw = Math.round(w * dpr)
  const ph = Math.round(h * dpr)
  canvas.width = pw
  canvas.height = ph
  cssW = w
  cssH = h
  ctx.gl.viewport(0, 0, pw, ph)
  renderer.camera.setViewport(w, h)
  renderer.camera.position.x = w / 2
  renderer.camera.position.y = h / 2
}

function frame(now: number) {
  requestAnimationFrame(frame)
  if (paused) {
    last = 0
    return
  }
  if (minFrameMs && last && now - last < minFrameMs) return
  const dt = last ? Math.min(0.05, (now - last) / 1000) * speed : 0
  last = now
  resize()
  ctx.gl.clearColor(0, 0, 0, 0)
  ctx.gl.clear(ctx.gl.COLOR_BUFFER_BIT)
  if (!model || !skeleton || !layout) {
    flushReads()
    return
  }

  state.update(dt)
  state.apply(skeleton)
  skeleton.scaleX = scale * dir
  skeleton.scaleY = scale
  const placed = posW > 0 && Math.abs(posW - cssW) < 0.5
  // 在 App 里：还没收到对得上当前窗口宽度的位置就先不画，免得在带子正中间闪一帧
  if (native && !placed) {
    flushReads()
    return
  }
  // 原生层和这里的帧不同步：用最后一次位置 + 速度外推（最多外推 20ms，停下时不会冲过头太多）
  skeleton.x = placed ? posX + posVX * Math.min(Math.max(now - posAt, 0) / 1000, 0.02) : cssW / 2
  skeleton.y = layout.footY - model.rest.y * scale
  skeleton.updateWorldTransform()
  renderer.begin()
  renderer.drawSkeleton(skeleton, true)
  renderer.end()
  flushReads()

  if (pendingFaced) {
    pendingFaced = false
    post({ type: 'faced', dir })
  }
  if (native && now - lastBounds >= 100) {
    lastBounds = now
    const b = boundsOf(skeleton, offset, size, temp)
    // 包围盒没变（待机、坐着）就不发，省掉无用的跨进程消息
    const key = b ? `${Math.round(b.x)},${Math.round(b.y)},${Math.round(b.w)},${Math.round(b.h)}|${cssW}|${placed}` : ''
    if (b && key !== sentBounds) {
      sentBounds = key
      post({ type: 'bounds', x: b.x, y: b.y, w: b.w, h: b.h, frameW: cssW, placed, sx: skeleton.x })
    }
  }
}

/** 帧缓冲不保留，只有刚画完的这一刻能读：在这里统一回答 */
function flushReads() {
  for (const q of pendingHits.splice(0)) hit(q.id, q.x, q.y)
  for (const id of pendingSnapshots.splice(0)) snapshot(id)
}

function snapshot(id: string) {
  canvas.toBlob((blob) => {
    if (!blob) {
      post({ type: 'error', stage: 'snapshot', text: '画布 toBlob 返回空' })
      return
    }
    const reader = new FileReader()
    reader.onload = () => {
      const url = String(reader.result)
      post({
        type: 'snapshot',
        id,
        png: url.slice(url.indexOf(',') + 1),
        width: canvas.width,
        height: canvas.height,
        css: { w: cssW, h: cssH },
        animation: state?.getCurrent(0)?.animation?.name ?? null,
        dir,
        bounds: skeleton ? boundsOf(skeleton, offset, size, temp) : null,
      })
    }
    reader.readAsDataURL(blob)
  }, 'image/png')
}

/** 改大小：重算布局，原生层按新 layout 改窗口 */
function rescale(height: number) {
  if (!model || !(height > 0)) return
  scale = height / model.rest.h
  layout = computeLayout(model, scale)
  sentBounds = ''
  post({ type: 'layout', scale, layout, rest: toPt(model.rest, model, scale), union: toPt(model.union, model, scale) })
}

/** 像素级点击判定：(x, y) 附近几个像素里有不透明的就算点到了小人 */
function hit(id: number, x: number, y: number) {
  const g = ctx.gl as WebGLRenderingContext
  const dpr = canvas.width / cssW
  const r = Math.max(1, Math.round(3 * dpr))
  const px = Math.round(x * dpr)
  const py = Math.round(y * dpr) // readPixels 的原点也在左下角
  const x0 = Math.max(0, px - r)
  const y0 = Math.max(0, py - r)
  const w = Math.min(canvas.width, px + r + 1) - x0
  const h = Math.min(canvas.height, py + r + 1) - y0
  let inside = false
  if (w > 0 && h > 0) {
    const buf = new Uint8Array(w * h * 4)
    g.readPixels(x0, y0, w, h, g.RGBA, g.UNSIGNED_BYTE, buf)
    for (let i = 3; i < buf.length; i += 4) {
      if (buf[i] > 24) {
        inside = true
        break
      }
    }
  }
  post({ type: 'hit', id, x, y, inside })
}

function receive(msg: Incoming) {
  switch (msg.type) {
    case 'load':
      setVoice(msg.voice)
      primeAudio()
      void load(msg)
      break
    case 'play':
      if (!model || !state) break
      if (!model.animations.some((a) => a.name === msg.name)) {
        post({ type: 'error', stage: 'play', text: `没有这个动画：${msg.name}` })
        break
      }
      state.setAnimation(0, msg.name, msg.loop ?? true)
      break
    case 'face':
      dir = msg.dir < 0 ? -1 : 1
      pendingFaced = true
      break
    case 'speed':
      speed = Number.isFinite(msg.value) ? Math.min(Math.max(msg.value, 0), 4) : 1
      break
    case 'snapshot':
      pendingSnapshots.push(msg.id)
      break
    case 'scale':
      rescale(msg.height)
      break
    case 'hit':
      // 同一时刻只留最新的一个（原生层按 id 认最后一次）
      pendingHits.length = 0
      pendingHits.push({ id: msg.id, x: msg.x, y: msg.y })
      break
    case 'fps':
      minFrameMs = msg.value > 0 ? 1000 / msg.value - 2 : 0
      break
    case 'pos':
      posX = msg.x
      posVX = Number.isFinite(msg.vx) ? msg.vx : 0
      posW = msg.w
      posAt = performance.now()
      break
    case 'touch':
      primeAudio()
      voiceTouch()
      break
    case 'voice':
      setVoice(msg)
      primeAudio()
      break
    case 'pause':
      paused = !!msg.paused
      pauseVoice(paused)
      if (paused) {
        for (const id of pendingSnapshots.splice(0)) post({ type: 'error', stage: 'snapshot', text: `桌宠已暂停（隐藏或息屏），没有快照 ${id}` })
        for (const q of pendingHits.splice(0)) post({ type: 'hit', id: q.id, x: q.x, y: q.y, inside: false })
      }
      break
  }
}

listen(receive)
requestAnimationFrame(frame)
post({ type: 'ready', dpr: window.devicePixelRatio })

if (!native) {
  // 调试模式：普通浏览器里直接看效果（vite dev：/pet.html?model=荒芜拉普兰德&group=基建）
  const q = new URLSearchParams(location.search)
  const list = await fetchManifest('./models/')
  const entry = list.find((e) => e.name === (q.get('model') ?? '荒芜拉普兰德')) ?? list[0]
  if (entry) {
    void load({
      type: 'load',
      base: './models/',
      files: entry.files,
      outfit: q.get('outfit') ?? undefined,
      group: q.get('group') ?? '基建',
      height: Number(q.get('height')) || 240,
    })
  }
  ;(window as unknown as { __pet: unknown }).__pet = { receive, get layout() { return layout }, get model() { return model } }
}
