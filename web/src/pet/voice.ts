/**
 * 基建语音：模型目录里有 voice/voice.json（macos/scripts/fetch-voice.mjs 拉的）才会出声。
 *   - 基建形态载入完：播一次「进驻设施」（同一个 WebView 里同一个模型只播一次，热更新重载页面不重复播）
 *   - 原生层发 touch（被点了一下）：基建形态下从「戳一下 / 信赖触摸」里随机挑一条；正在说话就不打断
 *   - 隐藏 / 暂停时停掉，不对着看不见的桌宠说话
 * 用 Web Audio（fetch → decodeAudioData）播，不走 <audio>，资源协议不用支持 Range。
 * 原生层的 load 消息不带 voice（老版本 App）就当关着：老 App 没有开关，不能自己响。
 */

type VoiceItem = { key: string; title: string; trigger: string; file: string }
export type VoiceSettings = { enabled: boolean; volume: number }
export type VoiceSet = { dir: string; items: VoiceItem[] }

const PLACE = 'BUILDING_PLACE'
const TOUCH = ['BUILDING_TOUCHING', 'BUILDING_FAVOR_BUBBLE']
const PLACED_KEY = 'rhodeside-voice-placed'

let settings: VoiceSettings = { enabled: false, volume: 0.7 }
let current: VoiceSet = { dir: '', items: [] }
let base = false
let paused = false
/** 换模型 / 暂停 / 关掉时 +1：还在解码、等 resume 的那条作废 */
let seq = 0
let audio: AudioContext | null = null
let gain: GainNode | null = null
let playing: AudioBufferSourceNode | null = null
/** 在解码 / 等 resume：连点时第二下也算「正在说话」 */
let starting = false
let last = ''
const buffers = new Map<string, Promise<AudioBuffer | null>>()

const url = (path: string) => path.split('/').map(encodeURIComponent).join('/')

/** 在原生消息的处理里同步调用：callAsyncJavaScript 带着用户手势，这时建 / 唤醒 AudioContext 不会被自动播放策略拦 */
export function primeAudio() {
  if (!settings.enabled || paused) return
  if (!audio) {
    audio = new AudioContext()
    gain = audio.createGain()
    gain.connect(audio.destination)
  }
  gain!.gain.value = settings.volume
  if (audio.state === 'suspended') void audio.resume().catch(() => {})
}

function buffer(item: VoiceItem) {
  const key = current.dir + item.file
  let p = buffers.get(key)
  if (!p) {
    p = fetch(url(key))
      .then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((b) => audio!.decodeAudioData(b))
      .catch((e) => {
        console.warn(`语音 ${item.file} 读不了：${e instanceof Error ? e.message : e}`)
        buffers.delete(key)
        return null
      })
    buffers.set(key, p)
  }
  return p
}

/** 真的开始出声了返回 true */
async function play(item: VoiceItem): Promise<boolean> {
  if (starting || playing || !settings.enabled || paused) return false
  primeAudio()
  if (!audio) return false
  const mine = seq
  starting = true
  try {
    const buf = await buffer(item)
    if (!buf || mine !== seq) return false
    if (audio.state === 'suspended') await audio.resume().catch(() => {})
    if (mine !== seq || audio.state !== 'running') return false
    const src = audio.createBufferSource()
    src.buffer = buf
    src.connect(gain!)
    src.onended = () => {
      if (playing !== src) return
      playing = null
      // 不说话时让音频线程歇着（桌宠一挂就是一整天）
      void audio?.suspend().catch(() => {})
    }
    playing = src
    last = item.key
    src.start()
    return true
  } finally {
    if (mine === seq) starting = false
  }
}

function stop() {
  seq++
  starting = false
  const p = playing
  playing = null
  p?.stop()
  void audio?.suspend().catch(() => {})
}

/** load 消息：读新模型的 voice.json（还不换上，模型载入成功后再 useVoice） */
export async function fetchVoice(root: string, files: string[]): Promise<VoiceSet> {
  const manifest = files.find((f) => /^[^/]+\/voice\/voice\.json$/.test(f))
  if (!manifest) return { dir: '', items: [] }
  try {
    const res = await fetch(url(root + manifest))
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const data = (await res.json()) as { items?: VoiceItem[] }
    const items = (data.items ?? []).filter((x) => x && typeof x.file === 'string' && /^[\w-]+\.(wav|mp3)$/i.test(x.file))
    return { dir: root + manifest.replace(/voice\.json$/, ''), items }
  } catch (e) {
    console.warn(`voice.json 读不了：${e instanceof Error ? e.message : e}`)
    return { dir: '', items: [] }
  }
}

/** 模型载入成功：换上它的语音；基建形态播一次进驻（同一个 WebView 里同一个模型只播一次） */
export async function useVoice(set: VoiceSet, model: string, group: string) {
  if (set.dir !== current.dir) {
    stop()
    buffers.clear()
  }
  current = set
  base = group.startsWith('基建')
  let placed: string | null = null
  try {
    placed = sessionStorage.getItem(PLACED_KEY)
    if (!base) sessionStorage.removeItem(PLACED_KEY)
  } catch {}
  if (!base || placed === model) return
  const item = set.items.find((x) => x.trigger === PLACE)
  // 播出来了才记下（被关着 / 暂停 / 拦住时下次还会播）
  if (item && (await play(item))) {
    try {
      sessionStorage.setItem(PLACED_KEY, model)
    } catch {}
  }
}

/** 被点了一下 */
export function voiceTouch() {
  if (!base || !settings.enabled || paused || playing || starting) return
  const pool = current.items.filter((x) => TOUCH.includes(x.trigger))
  if (pool.length === 0) return
  const fresh = pool.length > 1 ? pool.filter((x) => x.key !== last) : pool
  void play(fresh[Math.floor(Math.random() * fresh.length)])
}

/** load 消息里的 / 设置页改的开关和音量；undefined = 老版本 App，当关着 */
export function setVoice(v: Partial<VoiceSettings> | undefined) {
  settings = {
    enabled: v?.enabled === true,
    volume: Number.isFinite(v?.volume) ? Math.min(Math.max(v!.volume!, 0), 1) : settings.volume,
  }
  if (gain) gain.gain.value = settings.volume
  if (!settings.enabled) stop()
}

export function pauseVoice(p: boolean) {
  paused = p
  if (p) stop()
}
