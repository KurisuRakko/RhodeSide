/**
 * Spine 3.8 舞台：一块 WebGL 画布，上面放一个或多个角色。现在只有模型库预览（Library.tsx）在用，固定 view 模式；
 * roam 是原网页版的漫步逻辑（Swift 的 PetCore/Brain.swift 由它移植），留作别的壳移植行为时参考。
 *
 *   - 漫步（roam）：像基建小人一样在地面上自己走来走去、坐下、睡觉；点一下播互动动画，
 *     按住能拎起来，松手掉回地面。动画名按常见命名自动认（Relax/Move/Interact/Sit/Sleep 等）。
 *   - 查看（view）：像 PRTS 的模型查看器，角色居中，手动选动画、循环、速度。
 *
 * 世界坐标 = CSS 像素，原点在画布左下角、y 向上。贴图一律在上传时转成预乘 alpha，
 * 渲染固定走 PMA 管线：透明背景上的半透明边缘才不会发黑/发白。
 */
import { boundsOf, loadModel, type LoadedModel } from './model.ts'
import type { ModelSet } from './loader.ts'

export type { Box, LoadedModel, Roles } from './model.ts'
export { detectRoles } from './model.ts'

export type Mode = 'roam' | 'view'
export type Behavior = 'idle' | 'walk' | 'sit' | 'sleep' | 'interact' | 'held' | 'fall'

export interface StageStatus {
  animation: string | null
  behavior: Behavior | null
  actors: number
}

const rand = (a: number, b: number) => a + Math.random() * (b - a)

class Actor {
  skeleton: any
  state: any
  x = 0
  y = 0
  vy = 0
  dir: 1 | -1 = 1
  behavior: Behavior = 'idle'
  timer = 0
  targetX = 0
  grabDX = 0
  grabDY = 0
  current: string | null = null

  constructor(model: LoadedModel, skin: string | null) {
    this.skeleton = new spine.Skeleton(model.data)
    if (skin) this.skeleton.setSkinByName(skin)
    this.skeleton.setToSetupPose()
    const stateData = new spine.AnimationStateData(model.data)
    stateData.defaultMix = 0.2
    this.state = new spine.AnimationState(stateData)
  }

  play(name: string | null, loop: boolean, force = false) {
    if (!name) return
    if (!force && loop && this.current === name) return
    this.state.setAnimation(0, name, loop)
    this.current = name
  }
}

export class Stage {
  readonly canvas: HTMLCanvasElement
  private readonly ctx: any
  private readonly renderer: any
  private readonly onStatus: (s: StageStatus) => void
  private raf = 0
  private last = 0
  private cssW = 1
  private cssH = 1
  private lastStatus = ''
  private readonly offset = new spine.Vector2()
  private readonly size = new spine.Vector2()
  private readonly temp: number[] = [0, 0]
  private pointer: { id: number; actor: Actor; sx: number; sy: number; moved: boolean } | null = null

  model: LoadedModel | null = null
  actors: Actor[] = []
  mode: Mode = 'roam'
  /** 播放速度（同时作用于动画与走路） */
  speed = 1
  loop = true
  /** 漫步时角色（待机姿势）高度占舞台高度的比例 */
  scale = 0.42
  /** 步速倍率：动画步子和位移对不上（脚打滑）时调 */
  stride = 1
  /** 模型默认朝左（大多数模型朝右） */
  flip = false
  viewAnim: string | null = null
  skin: string | null = null

  constructor(canvas: HTMLCanvasElement, onStatus: (s: StageStatus) => void = () => {}) {
    this.canvas = canvas
    const gl = canvas.getContext('webgl', {
      alpha: true,
      premultipliedAlpha: true,
      antialias: true,
      preserveDrawingBuffer: true, // 截图要读回帧缓冲
    })
    if (!gl) throw new Error('浏览器不支持 WebGL')
    this.ctx = new spine.webgl.ManagedWebGLRenderingContext(gl)
    this.renderer = new spine.webgl.SceneRenderer(canvas, this.ctx, true)
    this.onStatus = onStatus
    canvas.addEventListener('pointerdown', this.onDown)
    canvas.addEventListener('pointermove', this.onMove)
    canvas.addEventListener('pointerup', this.onUp)
    canvas.addEventListener('pointercancel', this.onUp)
    this.raf = requestAnimationFrame(this.frame)
  }

  /* ---------------------------------------------------------------- 载入 */

  load(set: ModelSet, pma: boolean): Promise<LoadedModel> {
    return loadModel(this.ctx, set, pma)
  }

  /* ---------------------------------------------------------------- 控制 */

  setModel(model: LoadedModel | null) {
    const old = this.model
    // 同一套模型重载（比如切了预乘 alpha）：保留几只、站在哪
    const keep = old && model && old.set.id === model.set.id ? this.actors.map((a) => ({ x: a.x, dir: a.dir })) : []
    this.model = model
    this.actors = []
    this.pointer = null
    if (!keep.length || !model?.skins.includes(this.skin ?? '')) {
      this.skin = model?.skins.includes('default') ? 'default' : (model?.skins[0] ?? null)
    }
    if (!keep.length || !model?.animations.some((a) => a.name === this.viewAnim)) this.viewAnim = model?.roles.idle ?? null
    if (model) {
      if (keep.length === 0) this.addActor(true)
      for (const k of keep) {
        this.addActor()
        const a = this.actors[this.actors.length - 1]
        a.x = k.x
        a.dir = k.dir
      }
    }
    if (old && old !== model) for (const t of old.textures) t.dispose()
  }

  addActor(center = false) {
    if (!this.model) return
    const a = new Actor(this.model, this.skin)
    const half = this.halfWidth()
    a.x = center ? this.cssW / 2 : rand(half, Math.max(half, this.cssW - half))
    a.y = this.ground()
    a.dir = Math.random() < 0.5 ? 1 : -1
    this.actors.push(a)
    this.enter(a, this.mode === 'view' && this.actors.length === 1 ? 'view' : 'idle')
  }

  removeExtras() {
    this.actors.length = Math.min(this.actors.length, 1)
  }

  setMode(mode: Mode) {
    this.mode = mode
    for (const a of this.actors) {
      a.y = this.ground()
      a.vy = 0
      this.enter(a, mode === 'view' ? 'view' : 'idle')
    }
  }

  setSkin(name: string) {
    this.skin = name
    for (const a of this.actors) {
      a.skeleton.setSkinByName(name)
      a.skeleton.setSlotsToSetupPose()
    }
  }

  setViewAnimation(name: string) {
    this.viewAnim = name
    const a = this.actors[0]
    if (a && this.mode === 'view') a.play(name, this.loop, true)
  }

  setLoop(loop: boolean) {
    this.loop = loop
    const a = this.actors[0]
    if (a && this.mode === 'view') a.play(this.viewAnim, loop, true)
  }

  /** 查看模式：从头重播当前动画 */
  replay() {
    const a = this.actors[0]
    if (a && this.mode === 'view') a.play(this.viewAnim, this.loop, true)
  }

  async screenshot(): Promise<Blob | null> {
    return new Promise((ok) => this.canvas.toBlob((b) => ok(b), 'image/png'))
  }

  dispose() {
    cancelAnimationFrame(this.raf)
    this.canvas.removeEventListener('pointerdown', this.onDown)
    this.canvas.removeEventListener('pointermove', this.onMove)
    this.canvas.removeEventListener('pointerup', this.onUp)
    this.canvas.removeEventListener('pointercancel', this.onUp)
    this.setModel(null)
    this.renderer.dispose()
  }

  /* ---------------------------------------------------------------- 漫步行为 */

  private ground() {
    return Math.max(12, Math.round(this.cssH * 0.08))
  }

  private actorScale() {
    const m = this.model
    if (!m) return 1
    if (this.mode === 'view') {
      const u = m.union
      return Math.min((this.cssW * 0.86) / u.w, (this.cssH * 0.86) / u.h)
    }
    return Math.min((this.cssH * this.scale) / m.rest.h, (this.cssW * 0.9) / m.rest.w)
  }

  private halfWidth() {
    return this.model ? (this.model.rest.w * this.actorScale()) / 2 : 0
  }

  private enter(a: Actor, what: Behavior | 'view') {
    const roles = this.model!.roles
    if (what === 'view') {
      a.behavior = 'idle'
      a.play(this.viewAnim, this.loop, true)
      return
    }
    a.behavior = what
    switch (what) {
      case 'idle':
        a.timer = rand(2.5, 6)
        a.play(roles.idle, true)
        break
      case 'walk': {
        const half = this.halfWidth()
        const lo = half
        const hi = Math.max(lo, this.cssW - half)
        const minDist = Math.min((hi - lo) / 2, this.cssW * 0.2)
        let target = rand(lo, hi)
        for (let i = 0; i < 6 && Math.abs(target - a.x) < minDist; i += 1) target = rand(lo, hi)
        a.targetX = target
        a.dir = target >= a.x ? 1 : -1
        a.play(roles.move, true)
        break
      }
      case 'sit':
        a.timer = rand(5, 10)
        a.play(roles.sit, true)
        break
      case 'sleep':
        a.timer = rand(8, 16)
        a.play(roles.sleep, true)
        break
      case 'interact': {
        const dur = this.model!.animations.find((x) => x.name === roles.interact)?.duration ?? 1
        a.timer = Math.max(0.3, dur)
        a.play(roles.interact, false, true)
        break
      }
      case 'held':
        a.play(roles.idle, true)
        break
      case 'fall':
        a.vy = 0
        break
    }
  }

  private decide(a: Actor) {
    const roles = this.model!.roles
    const r = Math.random()
    if (roles.move && r < 0.6) this.enter(a, 'walk')
    else if (roles.sit && r < 0.75) this.enter(a, 'sit')
    else if (roles.sleep && r < 0.85) this.enter(a, 'sleep')
    else this.enter(a, 'idle')
  }

  private tick(a: Actor, dt: number, s: number) {
    const ground = this.ground()
    switch (a.behavior) {
      case 'idle':
      case 'sit':
      case 'sleep':
      case 'interact':
        a.timer -= dt
        if (a.timer <= 0) {
          if (a.behavior === 'idle') this.decide(a)
          else this.enter(a, 'idle')
        }
        break
      case 'walk': {
        const step = this.model!.rest.h * s * 0.42 * this.stride * dt
        const dx = a.targetX - a.x
        if (Math.abs(dx) <= step) {
          a.x = a.targetX
          this.enter(a, 'idle')
        } else a.x += Math.sign(dx) * step
        break
      }
      case 'fall':
        a.vy -= this.cssH * 3.2 * dt
        a.y += a.vy * dt
        if (a.y <= ground) {
          a.y = ground
          a.vy = 0
          this.enter(a, 'idle')
        }
        break
      case 'held':
        break
    }
    if (a.behavior !== 'held' && a.behavior !== 'fall') a.y = ground
    const half = this.halfWidth()
    if (a.behavior !== 'held') a.x = Math.min(Math.max(a.x, half), Math.max(half, this.cssW - half))
  }

  /* ---------------------------------------------------------------- 渲染循环 */

  private resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const w = Math.max(1, this.canvas.clientWidth)
    const h = Math.max(1, this.canvas.clientHeight)
    const pw = Math.round(w * dpr)
    const ph = Math.round(h * dpr)
    if (this.canvas.width !== pw || this.canvas.height !== ph) {
      this.canvas.width = pw
      this.canvas.height = ph
    }
    this.cssW = w
    this.cssH = h
    this.ctx.gl.viewport(0, 0, pw, ph)
    this.renderer.camera.setViewport(w, h)
    this.renderer.camera.position.x = w / 2
    this.renderer.camera.position.y = h / 2
  }

  private place(a: Actor, s: number) {
    const m = this.model!
    const sk = a.skeleton
    const face = this.flip ? -1 : 1
    if (this.mode === 'view') {
      const u = m.union
      sk.scaleX = s * face
      sk.scaleY = s
      sk.x = this.cssW / 2 - (u.x + u.w / 2) * s * face
      sk.y = this.cssH / 2 - (u.y + u.h / 2) * s
      return
    }
    sk.scaleX = s * a.dir * face
    sk.scaleY = s
    sk.x = a.x
    sk.y = a.y - m.rest.y * s
  }

  private frame = (now: number) => {
    this.raf = requestAnimationFrame(this.frame)
    const dt = this.last ? Math.min(0.05, (now - this.last) / 1000) * this.speed : 0
    this.last = now
    this.resize()

    const gl = this.ctx.gl
    gl.clearColor(0, 0, 0, 0)
    gl.clear(gl.COLOR_BUFFER_BIT)
    if (!this.model || this.actors.length === 0) return

    const s = this.actorScale()
    const shown = this.mode === 'view' ? this.actors.slice(0, 1) : this.actors
    this.renderer.begin()
    for (const a of shown) {
      if (this.mode === 'roam') this.tick(a, dt, s)
      a.state.update(dt)
      a.state.apply(a.skeleton)
      this.place(a, s)
      a.skeleton.updateWorldTransform()
      this.renderer.drawSkeleton(a.skeleton, true)
    }
    this.renderer.end()
    this.report()
  }

  private report() {
    const a = this.actors[0]
    const status: StageStatus = {
      animation: a?.state.getCurrent(0)?.animation?.name ?? null,
      behavior: this.mode === 'roam' ? (a?.behavior ?? null) : null,
      actors: this.actors.length,
    }
    const key = JSON.stringify(status)
    if (key !== this.lastStatus) {
      this.lastStatus = key
      this.onStatus(status)
    }
  }

  /* ---------------------------------------------------------------- 指针：点一下互动，按住拎起来 */

  private toWorld(e: PointerEvent) {
    const r = this.canvas.getBoundingClientRect()
    return { x: e.clientX - r.left, y: this.cssH - (e.clientY - r.top) }
  }

  private hit(x: number, y: number): Actor | null {
    for (let i = this.actors.length - 1; i >= 0; i -= 1) {
      const b = boundsOf(this.actors[i].skeleton, this.offset, this.size, this.temp)
      if (b && x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h) return this.actors[i]
    }
    return null
  }

  private onDown = (e: PointerEvent) => {
    if (this.mode !== 'roam' || !this.model || e.button !== 0) return
    const p = this.toWorld(e)
    const actor = this.hit(p.x, p.y)
    if (!actor) return
    e.preventDefault()
    this.canvas.setPointerCapture(e.pointerId)
    this.pointer = { id: e.pointerId, actor, sx: p.x, sy: p.y, moved: false }
    actor.grabDX = p.x - actor.x
    actor.grabDY = p.y - actor.y
  }

  private onMove = (e: PointerEvent) => {
    const p = this.toWorld(e)
    const ptr = this.pointer
    if (!ptr || ptr.id !== e.pointerId) {
      if (this.mode === 'roam') this.canvas.style.cursor = this.hit(p.x, p.y) ? 'grab' : ''
      return
    }
    if (!ptr.moved && Math.hypot(p.x - ptr.sx, p.y - ptr.sy) > 6) {
      ptr.moved = true
      this.enter(ptr.actor, 'held')
      // 拎起来的放到最上层画
      this.actors = [...this.actors.filter((a) => a !== ptr.actor), ptr.actor]
      this.canvas.style.cursor = 'grabbing'
    }
    if (ptr.moved) {
      ptr.actor.x = Math.min(Math.max(p.x - ptr.actor.grabDX, 0), this.cssW)
      ptr.actor.y = Math.max(this.ground(), Math.min(p.y - ptr.actor.grabDY, this.cssH))
    }
  }

  private onUp = (e: PointerEvent) => {
    const ptr = this.pointer
    if (!ptr || ptr.id !== e.pointerId) return
    this.pointer = null
    this.canvas.style.cursor = ''
    if (ptr.moved) this.enter(ptr.actor, ptr.actor.y > this.ground() + 1 ? 'fall' : 'idle')
    else if (this.model?.roles.interact) this.enter(ptr.actor, 'interact')
  }
}
