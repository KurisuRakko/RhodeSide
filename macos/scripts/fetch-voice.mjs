#!/usr/bin/env node
/**
 * 从 PRTS 拉干员的基建语音到 models-private/<干员名>/voice/，跟着模型一起发布。
 *
 *   node macos/scripts/fetch-voice.mjs [--only 结城理,能天使] [--dry]
 *
 * 流程：干员名 → char id（models-private/prts-index.json，fetch-prts.mjs 维护）→「<名>/语音记录」的 wikitext
 * （VoiceTable 模板：标题N / 台词N / 语音N / 触发类型N，路径=各语种目录）→ torappu 上的 wav。
 * 只收基建里会播的三类（进驻设施 / 戳一下 / 信赖触摸）；语种优先中文普通话，其次日语，都没有（联动干员）就用第一个，
 * 韩语和英语不下。不带 --only 时跑 macos/models.json 里全部模型（目录用各条目的 dir）。已下载的不重下（换了语种会重下）。
 * 目录布局：voice/voice.json + voice/cn_0xx.wav（前端 web/src/pet/voice.ts 读 voice.json）。
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(process.env.RHODESIDE_ROOT ?? join(HERE, '../..'))
const OUT = join(ROOT, 'models-private')
const LIST = join(ROOT, 'macos/models.json')
const INDEX = join(OUT, 'prts-index.json')
const WIKI = 'https://prts.wiki'
const AUDIO = 'https://torappu.prts.wiki/assets/audio'
const TRIGGERS = ['BUILDING_PLACE', 'BUILDING_TOUCHING', 'BUILDING_FAVOR_BUBBLE']
const LANGS = ['中文-普通话', '日语']
const SKIP_LANGS = new Set(['韩语', '英语'])

const args = process.argv.slice(2)
const opt = (k, d) => (args.includes(k) ? args[args.indexOf(k) + 1] : d)
const only = opt('--only', '')
  .split(',')
  .filter(Boolean)
const dry = args.includes('--dry')
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// PRTS 会拦浏览器样子的 UA，用一个说清来意的（和 fetch-prts.mjs 一样）
const UA = 'rhodeside-model-fetch/1 (+https://rhodeside.rakko.cn)'
async function get(url, kind = 'text') {
  for (let i = 0; ; i++) {
    try {
      const res = await fetch(url, { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(60_000) })
      if (res.status === 404) return null
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      return kind === 'text' ? await res.text() : Buffer.from(await res.arrayBuffer())
    } catch (e) {
      if (i >= 3) throw new Error(`${url}: ${e.message}`)
      await sleep(2000 * (i + 1))
    }
  }
}

/** 原子写（被超时杀掉也不会留下半个文件）；临时文件以 . 开头，publish.mjs 的 walk 会跳过 */
function writeAtomic(file, data) {
  mkdirSync(dirname(file), { recursive: true })
  const tmp = join(dirname(file), `.${basename(file)}.tmp`)
  writeFileSync(tmp, data)
  renameSync(tmp, file)
}

/** 从 i 处的 `{{` 开始找配对的 `}}`，返回它后面的位置 */
function closeOf(s, i) {
  let depth = 0
  for (let p = i; p < s.length - 1; p++) {
    if (s[p] === '{' && s[p + 1] === '{') {
      depth++
      p++
    } else if (s[p] === '}' && s[p + 1] === '}') {
      depth--
      p++
      if (depth === 0) return p + 1
    }
  }
  return -1
}

/** 模板里的台词 → 纯文本：{{DrName}} → 博士，别的模板取最后一个参数，<br> → 换行 */
function plain(s) {
  let out = ''
  for (let i = 0; i < s.length; ) {
    if (s.startsWith('{{', i)) {
      const end = closeOf(s, i)
      if (end < 0) break
      const inner = s.slice(i + 2, end - 2)
      if (/^DrName\b/i.test(inner)) out += '博士'
      else {
        const parts = inner.split('|').filter((x) => !x.includes('='))
        out += parts.length > 1 ? plain(parts[parts.length - 1]) : ''
      }
      i = end
    } else out += s[i++]
  }
  return out
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    .trim()
}

/** 台词N 里某个语种的那段：{{VoiceData/word|中文|……}} */
function word(field, lang) {
  const at = field.indexOf(`{{VoiceData/word|${lang}|`)
  if (at < 0) return ''
  const end = closeOf(field, at)
  return end < 0 ? '' : plain(field.slice(at + `{{VoiceData/word|${lang}|`.length, end - 2))
}

/** VoiceTable 的顶层参数（按 `\n|` 切，台词里嵌的模板不会被切开：它们都在一行里） */
function params(wikitext) {
  const start = wikitext.indexOf('{{VoiceTable|')
  if (start < 0) return null
  const end = closeOf(wikitext, start)
  const body = wikitext.slice(start + '{{VoiceTable|'.length, end < 0 ? undefined : end - 2)
  const out = {}
  for (const line of body.split(/\n\|/)) {
    const eq = line.indexOf('=')
    if (eq > 0) out[line.slice(0, eq).trim()] = line.slice(eq + 1).trim()
  }
  return out
}

async function voiceTable(name) {
  const url = `${WIKI}/api.php?action=parse&format=json&prop=wikitext&page=${encodeURIComponent(`${name}/语音记录`)}`
  const d = JSON.parse((await get(url)) ?? 'null')
  const text = d?.parse?.wikitext?.['*']
  return text ? params(text) : null
}

/** 路径=日语:voice/char_x,中文-普通话:voice_cn/char_x,…  → 选一个语种 */
function pickLang(path) {
  const all = (path ?? '')
    .split(',')
    .map((x) => x.split(':'))
    .filter((x) => x.length === 2 && x[1].trim())
    .map(([lang, dir]) => ({ lang: lang.trim(), dir: dir.trim() }))
  for (const l of LANGS) {
    const hit = all.find((x) => x.lang === l)
    if (hit) return hit
  }
  return all.find((x) => !SKIP_LANGS.has(x.lang)) ?? null
}

/** 不在 prts-index.json 里的（比如授权的荒芜拉普兰德）：查干员页 wikitext 的「干员id」，和 fetch-prts.mjs 同一种办法 */
async function charId(name) {
  const d = JSON.parse(await get(`${WIKI}/api.php?action=query&prop=revisions&rvprop=content&rvslots=main&format=json&formatversion=2&titles=${encodeURIComponent(name)}`))
  return /\|干员id=(char_\w+)/.exec(d.query?.pages?.[0]?.revisions?.[0]?.slots?.main?.content ?? '')?.[1] ?? null
}

async function fetchVoice(name, id, modelDir) {
  const p = await voiceTable(name)
  if (!p) return { skip: 'PRTS 上没有语音记录' }
  const lang = pickLang(p['路径'])
  if (!lang) return { skip: `语种不认识：${p['路径'] ?? '（没有路径）'}` }
  const items = []
  for (const k of Object.keys(p)) {
    const n = /^触发类型(\d+)$/.exec(k)?.[1]
    if (!n || !TRIGGERS.includes(p[k])) continue
    const file = (p[`语音${n}`] ?? '').toLowerCase()
    if (!/^[\w-]+\.wav$/.test(file)) continue
    items.push({ key: file.replace(/\.wav$/, ''), title: plain(p[`标题${n}`] ?? ''), trigger: p[k], file, text: word(p[`台词${n}`] ?? '', '中文') })
  }
  if (items.length === 0) return { skip: '没有基建语音' }
  if (dry) return { items, lang, files: 0 }

  const dir = join(modelDir, 'voice')
  let before = null
  try {
    before = JSON.parse(readFileSync(join(dir, 'voice.json'), 'utf8')).lang
  } catch {}
  let files = 0
  for (const it of items) {
    const local = join(dir, it.file)
    // 同名文件不同语种（联动干员后来补了中文配音）：语种变了就重下
    if (before === lang.lang && existsSync(local) && statSync(local).size > 0) continue
    const data = await get(`${AUDIO}/${lang.dir}/${it.file}`, 'bin')
    if (!data) throw new Error(`缺文件 ${AUDIO}/${lang.dir}/${it.file}`)
    writeAtomic(local, data)
    files++
    await sleep(300)
  }
  writeAtomic(join(dir, 'voice.json'), `${JSON.stringify({ charId: id, lang: lang.lang, items }, null, 2)}\n`)
  // PRTS 上已经没有的旧语音：清掉
  const keep = new Set(['voice.json', ...items.map((x) => x.file)])
  for (const f of readdirSync(dir)) if (!keep.has(f) && !f.startsWith('.')) rmSync(join(dir, f), { force: true })
  return { items, lang, files }
}

if (!existsSync(INDEX)) throw new Error(`缺 ${INDEX}（先跑 fetch-prts.mjs）`)
const index = JSON.parse(readFileSync(INDEX, 'utf8'))
const list = JSON.parse(readFileSync(LIST, 'utf8'))
const names = only.length ? only : list.map((m) => m.name)
const skipped = []
for (const name of names) {
  try {
    if (name.includes('/') || name.startsWith('.')) throw new Error('名字不能当文件夹名')
    const id = index[name] ?? (await charId(name))
    if (!id) {
      skipped.push(`${name}：PRTS 上查不到干员 id`)
      continue
    }
    const modelDir = resolve(ROOT, list.find((m) => m.name === name)?.dir ?? join('models-private', name))
    if (!existsSync(modelDir)) {
      skipped.push(`${name}：还没有模型目录 ${modelDir}`)
      continue
    }
    const r = await fetchVoice(name, id, modelDir)
    if (r.skip) {
      skipped.push(`${name}：${r.skip}`)
      continue
    }
    console.log(`[voice] ${name} ${id} · ${r.lang.lang} · ${r.items.map((x) => `${x.title}(${x.file})`).join(' ')}${dry ? '' : ` · 新下载 ${r.files} 个`}`)
    await sleep(1000)
  } catch (e) {
    skipped.push(`${name}：${e.message}`)
  }
}
if (skipped.length) console.log(`[voice] 跳过 ${skipped.length} 个：\n  ${skipped.join('\n  ')}`)
