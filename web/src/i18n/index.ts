/**
 * 界面语言：简体中文 / 繁體中文（香港）/ English。
 * 当前语言是模块级的：页面收到原生层的状态时 adoptState() 一下（在 setState 之前），之后各处直接 t() 取表。
 * 语言设置在 config.language（'system' = 跟随系统）；老版本 App 没有这个字段，就按系统语言。
 *
 * 干员名、时装名：数据里只有中文（它也是模型文件夹名 / 配置 key，不能改），
 * 译名在在线模型目录的 names / outfits 里，按中文名对上后只在显示时换。
 */
import { en } from './en.ts'
import { zhHans, type Messages } from './zh-Hans.ts'
import { zhHant } from './zh-Hant.ts'

export type Lang = 'zh-Hans' | 'zh-Hant' | 'en'
export type LangPref = 'system' | Lang
export const LANGS: Lang[] = ['zh-Hans', 'zh-Hant', 'en']
/** 语言名永远用它自己的语言写 */
export const LANG_NAMES: Record<Lang, string> = { 'zh-Hans': '简体中文', 'zh-Hant': '繁體中文', en: 'English' }

/** 语言下拉框的选项：跟随系统 + 三种语言 */
export const languageOptions = (): [string, string][] => [['system', t().lang.system], ...LANGS.map((l): [string, string] => [l, LANG_NAMES[l]])]

const TABLES: Record<Lang, Messages> = { 'zh-Hans': zhHans, 'zh-Hant': zhHant, en }
/** <html lang>：繁体按香港（字形跟着走） */
const HTML_LANG: Record<Lang, string> = { 'zh-Hans': 'zh-Hans', 'zh-Hant': 'zh-HK', en: 'en' }

/**
 * 系统首选语言 → 界面语言。只看第一首选（中文排在英文后面的人要的是英文）：
 * 写明 Hans / Hant 的按文字（zh-Hans-HK 是简体），没写的按地区（台港澳繁体）；粤语按繁体；其他一律英文
 */
export function systemLang(prefs: readonly string[]): Lang {
  const p = prefs[0]?.toLowerCase()
  if (!p) return 'zh-Hans'
  if (/^yue\b/.test(p)) return 'zh-Hant'
  if (!/^zh\b/.test(p)) return 'en'
  if (/-hans\b/.test(p)) return 'zh-Hans'
  return /-hant\b|-(tw|hk|mo)\b/.test(p) ? 'zh-Hant' : 'zh-Hans'
}

export function resolveLang(pref: string | undefined, system: readonly string[]): Lang {
  return (LANGS as string[]).includes(pref ?? '') ? (pref as Lang) : systemLang(system)
}

const browserLangs = (): readonly string[] => (typeof navigator !== 'undefined' && navigator.languages?.length ? navigator.languages : [])

let current: Lang = systemLang(browserLangs())
let title: ((m: Messages) => string) | null = null
if (typeof document !== 'undefined') document.documentElement.lang = HTML_LANG[current]

export function getLang(): Lang {
  return current
}

/** 当前语言的文案表 */
export function t(): Messages {
  return TABLES[current]
}

export function setLang(lang: Lang) {
  current = lang
  if (typeof document === 'undefined') return
  document.documentElement.lang = HTML_LANG[lang]
  if (title) document.title = title(TABLES[lang])
}

/** 页面标题跟着语言换 */
export function setTitle(fn: (m: Messages) => string) {
  title = fn
  if (typeof document !== 'undefined') document.title = fn(t())
}

/** 日期时间按界面语言排版 */
export const dateTime = (d: Date) => d.toLocaleString(HTML_LANG[current])
export const time = (d: Date) => d.toLocaleTimeString(HTML_LANG[current])

/* ------------------------------------------------------------------ 干员名 / 时装名 */

type Translated = Partial<Record<Exclude<Lang, 'zh-Hans'>, string>>
export interface CatalogNames {
  name: string
  names?: Translated
  outfits?: Record<string, Translated>
}

const NAMES_KEY = 'rhodeside.catalogNames'
// 目录要登录后才拿得到：上次的译名存一份，没登录 / 离线时已装的模型照样显示译名
let byName = new Map<string, CatalogNames>(readCachedNames())

function readCachedNames(): [string, CatalogNames][] {
  try {
    const raw = JSON.parse(localStorage.getItem(NAMES_KEY) ?? '[]') as CatalogNames[]
    return Array.isArray(raw) ? raw.map((c) => [c.name, c]) : []
  } catch {
    return []
  }
}

let lastSaved = ''

function adoptCatalog(catalog: CatalogNames[]) {
  const withNames = catalog.filter((c) => c.names || c.outfits).map(({ name, names, outfits }) => ({ name, names, outfits }))
  // 老版本 App 不转发译名；目录还没到手时也是空的：都保留上次的
  if (withNames.length === 0) return
  // 桌宠一动原生层就推一次状态：译名没变就不重建、不写 localStorage
  const json = JSON.stringify(withNames)
  if (json === lastSaved) return
  lastSaved = json
  byName = new Map(withNames.map((c) => [c.name, c]))
  try {
    localStorage.setItem(NAMES_KEY, json)
  } catch {
    // 存不了就只在这次用
  }
}

/** 模型显示名：目录里有译名就用，没有（导入的、国服独有没译名的）原样 */
export function modelName(name: string): string {
  if (current === 'zh-Hans') return name
  return byName.get(name)?.names?.[current] || name
}

/** 时装显示名：译名 > skins.json 里的中文名 > key */
export function outfitName(model: string, key: string, zh: string | undefined): string {
  if (current !== 'zh-Hans') {
    const n = byName.get(model)?.outfits?.[key]?.[current]
    if (n) return n
  }
  return zh ?? key
}

/** 搜索：中文原名和当前语言的名字都算 */
export function nameMatches(name: string, q: string): boolean {
  if (!q) return true
  return name.toLowerCase().includes(q) || modelName(name).toLowerCase().includes(q)
}

/** 原生层推来的状态：先定语言和译名，再交给 React 渲染 */
export function adoptState(s: { config: { language?: string }; systemLanguages?: string[]; catalog: CatalogNames[] }) {
  adoptCatalog(s.catalog)
  // 老版本 App（没有 language）：界面上也没有语言选项可改，保持它原来的简体
  setLang(s.config.language === undefined ? 'zh-Hans' : resolveLang(s.config.language, s.systemLanguages?.length ? s.systemLanguages : browserLangs()))
}
