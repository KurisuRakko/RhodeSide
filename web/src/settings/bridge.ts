/**
 * 设置页 ↔ Rhodeside 原生层。
 * 不在 App 里（普通浏览器打开 settings.html）时用一个内存里的假原生层，方便调界面。
 */
import { fetchManifest } from '../stage/loader.ts'
import { listen, native, post } from '../native/transport.ts'

export { native }

export interface PetConfig {
  id: string
  model: string
  outfit?: string
  group?: string
  height: number
  stride: number
  pma: boolean
  /** 全自动 / 一直走 / 原地不动 */
  activity: Activity
  /** 鼠标移到小人身上时变淡并穿透（按住 ⌥ 恢复） */
  hoverFade: boolean
  /** 0.2–1 */
  opacity: number
  /** 战斗形态待机时循环的动画（null = 模型自己的待机） */
  pose?: string | null
}

export type Activity = 'auto' | 'walk' | 'stay'
export type Behavior = 'idle' | 'walk' | 'sit' | 'sleep' | 'interact' | 'held' | 'fall'

export interface AppConfig {
  version: number
  pets: PetConfig[]
  hideInFullscreen: boolean
  walkOnWindows: boolean
  ignoredApps: string[]
  updates: { enabled: boolean; url: string; interval: number }
  auth: { enabled: boolean; api: string; appID: string }
  onboarded: boolean
}

export interface UpdateStatus {
  enabled: boolean
  url: string
  /** 当前前端的构建号（毫秒时间戳，0 = 未知） */
  current: number
  remote: number | null
  lastCheck: string | null
  error: string | null
  app: { current: number; remote: number | null; state: 'waiting' | 'downloading' | 'installing' | 'restarting' | 'failed' | null }
}

export interface AuthStatus {
  enabled: boolean
  phase: 'disabled' | 'signedOut' | 'signingIn' | 'signedIn' | 'denied'
  user: string | null
  error: string | null
}

export interface CatalogModel {
  id: string
  name: string
  size: number
  /** 模型库里默认勾上 */
  default: boolean
  /** 时装套数 */
  skins: number
  /** 有预览包（默认时装的基建模型） */
  preview: boolean
  state: 'installed' | 'outdated' | 'available' | 'queued' | 'downloading' | 'failed'
  error: string | null
}

export interface ModelInfo {
  name: string
  builtin: boolean
  /** 相对 models/ 的路径 */
  files: string[]
}

export interface PetSummary {
  id: string
  behavior: Behavior
  /** 站在平台上（能做动作） */
  standing: boolean
  can: { interact: boolean; sit: boolean; sleep: boolean; move: boolean }
  loaded: { model: string; outfit: string; group: string; sets: { outfit: string; group: string }[] } | null
  error: string | null
  /** 战斗形态（正面 / 背面）：不走动，待机循环 pose */
  battle?: boolean
  animations?: string[]
  /** 套组动作按钮 */
  combos?: { id: string; label: string }[]
  pose?: string | null
}

export interface NativeState {
  version: string
  webDev: boolean
  maxPets: number
  builtinModel: string
  defaultIgnoredApps: string[]
  config: AppConfig
  models: ModelInfo[]
  pets: PetSummary[]
  loginItem: { enabled: boolean; detail: string }
  hidden: boolean
  updates: UpdateStatus
  auth: AuthStatus
  appBuild: number
  /** 服务器上的在线模型（登录后才拿得到目录） */
  catalog: CatalogModel[]
}

export interface StagedImport {
  token: string
  name: string
  base: string
  files: string[]
}

export type Incoming =
  | ({ type: 'state' } & NativeState)
  | { type: 'toast'; text: string }
  | ({ type: 'importStaged' } & StagedImport)
  | { type: 'dropHover'; on: boolean }
  | { type: 'preview'; id: string; base?: string; files?: string[]; error?: string }
  | { type: 'navigate'; tab: string }

export type Outgoing =
  | { type: 'ready' }
  | { type: 'updatePet'; id: string; patch: Partial<Record<keyof PetConfig, unknown>> }
  | { type: 'addPet'; model?: string }
  | { type: 'removePet'; id: string }
  | { type: 'summonPet'; id?: string }
  | { type: 'updateGlobal'; patch: Partial<Omit<AppConfig, 'pets' | 'version'>> }
  | { type: 'setHidden'; hidden: boolean }
  | { type: 'setLoginItem'; enabled: boolean }
  | { type: 'openLoginItemSettings' }
  | { type: 'importPick' }
  | { type: 'importResult'; token: string; ok: boolean; reason?: string }
  | { type: 'deleteModel'; name: string }
  | { type: 'reveal'; what: 'models' | 'logs' | 'config' }
  | { type: 'snapshot' }
  | { type: 'reloadWeb' }
  | { type: 'checkUpdates' }
  | { type: 'perform'; id?: string; behavior: Behavior }
  | { type: 'playCombo'; id: string; combo: string }
  | { type: 'openPage'; page: 'pets' | 'models' | 'settings' }
  | { type: 'downloadModels'; ids: string[] }
  | { type: 'previewModel'; id: string }
  | { type: 'finishOnboarding'; ids?: string[] }
  | { type: 'authLogin' }
  | { type: 'authLogout' }
  | { type: 'log'; text: string }
  | { type: 'error'; text: string }

const listeners = new Set<(m: Incoming) => void>()

export function onMessage(fn: (m: Incoming) => void): () => void {
  listeners.add(fn)
  return () => {
    listeners.delete(fn)
  }
}

function emit(m: Incoming) {
  for (const fn of listeners) fn(m)
}

listen(emit)

export function send(msg: Outgoing) {
  if (!post(msg)) void mock(msg)
}

window.addEventListener('error', (e) => send({ type: 'error', text: `${e.message} @ ${e.filename}:${e.lineno}` }))
window.addEventListener('unhandledrejection', (e) => send({ type: 'error', text: `未处理的 Promise 拒绝：${String(e.reason)}` }))

/* ------------------------------------------------------------------ 浏览器里的假原生层 */

let fake: NativeState | null = null
const PREVIEW_CAN = { interact: true, sit: true, sleep: true, move: true }

async function fakeState(): Promise<NativeState> {
  if (fake) return fake
  const list = await fetchManifest('./models/')
  fake = {
    version: '0.0.0 (preview)',
    webDev: false,
    maxPets: 8,
    builtinModel: '荒芜拉普兰德',
    defaultIgnoredApps: ['Snipaste', 'PixPin', 'CleanShot X'],
    config: {
      version: 1,
      pets: [
        {
          id: 'preview-1',
          model: '荒芜拉普兰德',
          outfit: 'char_1038_whitw2',
          group: '基建',
          height: 120,
          stride: 1,
          pma: false,
          activity: 'auto',
          hoverFade: false,
          opacity: 1,
        },
      ],
      hideInFullscreen: true,
      walkOnWindows: true,
      ignoredApps: ['Snipaste', 'PixPin', 'CleanShot X'],
      updates: { enabled: true, url: 'https://rhodeside.rakko.cn', interval: 5 },
      auth: { enabled: true, api: 'https://api.rakko.cn', appID: 'rhodeside' },
      onboarded: false,
    },
    models: list.map((e) => ({ name: e.name, builtin: e.name === '荒芜拉普兰德', files: e.files })),
    pets: [{ id: 'preview-1', behavior: 'idle', standing: true, can: PREVIEW_CAN, loaded: null, error: null }],
    loginItem: { enabled: false, detail: '没开' },
    hidden: false,
    updates: {
      enabled: true,
      url: 'https://rhodeside.rakko.cn',
      current: 0,
      remote: null,
      lastCheck: null,
      error: null,
      app: { current: 0, remote: null, state: null },
    },
    auth: { enabled: true, phase: 'signedOut', user: null, error: null },
    appBuild: 0,
    catalog: [],
  }
  return fake
}

const MOCK_CATALOG: CatalogModel[] = ['荒芜拉普兰德', '能天使', '艾雅法拉', '史尔特尔', '令', '夕', '年', '棘刺', '凯尔希', '银灰'].map((name, i) => ({
  id: `mock-${i}`,
  name,
  size: 2_000_000 + i * 310_000,
  default: i === 0,
  skins: 1 + (i % 4),
  preview: true,
  state: 'available',
  error: null,
}))

async function mock(msg: Outgoing) {
  const s = await fakeState()
  const pushState = () => emit({ type: 'state', ...structuredClone(s) })
  const toast = (text: string) => emit({ type: 'toast', text })
  switch (msg.type) {
    case 'ready':
      break
    case 'updatePet': {
      const p = s.config.pets.find((x) => x.id === msg.id)
      if (p) Object.assign(p, Object.fromEntries(Object.entries(msg.patch).map(([k, v]) => [k, v ?? undefined])))
      break
    }
    case 'addPet': {
      const id = `preview-${Date.now()}`
      s.config.pets.push({ id, model: msg.model ?? s.builtinModel, height: 120, stride: 1, pma: false, activity: 'auto', hoverFade: false, opacity: 1 })
      s.pets.push({ id, behavior: 'fall', standing: false, can: PREVIEW_CAN, loaded: null, error: null })
      break
    }
    case 'removePet':
      s.config.pets = s.config.pets.filter((p) => p.id !== msg.id)
      s.pets = s.pets.filter((p) => p.id !== msg.id)
      break
    case 'updateGlobal':
      Object.assign(s.config, msg.patch)
      break
    case 'setHidden':
      s.hidden = msg.hidden
      break
    case 'perform':
      for (const p of s.pets) if (!msg.id || p.id === msg.id) p.behavior = msg.behavior
      break
    case 'authLogin':
      s.auth = { ...s.auth, phase: 'signedIn', user: 'Rakko（预览）', error: null }
      s.catalog = MOCK_CATALOG.map((m) => ({ ...m }))
      break
    case 'downloadModels':
      s.catalog = s.catalog.map((m) => (msg.ids.includes(m.id) ? { ...m, state: 'downloading' } : m))
      setTimeout(() => {
        s.catalog = s.catalog.map((m) => (m.state === 'downloading' ? { ...m, state: 'installed' } : m))
        pushState()
      }, 1500)
      break
    case 'previewModel': {
      // 浏览器预览：拿 public/models 里的测试模型冒充
      const e = (await fetchManifest('./models/'))[0]
      setTimeout(() => emit(e ? { type: 'preview', id: msg.id, base: './models/', files: e.files } : { type: 'preview', id: msg.id, error: '没有测试模型' }), 400)
      return
    }
    case 'playCombo':
      toast(`播放套组 ${msg.combo}`)
      return
    case 'finishOnboarding':
      s.config.onboarded = true
      if (msg.ids?.length) void mock({ type: 'downloadModels', ids: msg.ids })
      toast('引导已完成')
      break
    case 'authLogout':
      s.auth = { ...s.auth, phase: 'signedOut', user: null }
      break
    case 'openPage':
      location.hash = msg.page
      return
    case 'setLoginItem':
      s.loginItem = { enabled: msg.enabled, detail: msg.enabled ? '（预览）已开' : '没开' }
      break
    default:
      toast(`浏览器预览里没有这个功能（${msg.type}）`)
      return
  }
  pushState()
}
