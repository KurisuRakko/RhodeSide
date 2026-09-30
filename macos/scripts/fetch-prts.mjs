#!/usr/bin/env node
/**
 * 从 PRTS 拉六星干员的 Spine 模型到 models-private/<干员名>/，并把它们登记进 macos/models.json。
 *
 *   node macos/scripts/fetch-prts.mjs [--rarity 6] [--only 能天使,煌] [--dry]
 *
 * 流程：干员一览（data-rarity，0 起算）→ 干员页 wikitext 的「干员id」（char_xxx，缓存在
 * models-private/prts-index.json）→ torappu 的 meta.json（时装 × 正面/背面/基建）→ .skel/.atlas/贴图。
 * 目录布局和 PRTS 一样：<时装文件夹>/<front|back|build>/<文件>，前端 loader 直接认。
 * 已下载且大小对得上的文件不重下；新干员上线后重跑一遍就行。只收 Spine 3.8 的骨骼。
 * 不带 --only 时，除了该星级全员，models.json 里其他 source: 'prts' 的干员（用 --only 单独加进来的，比如五星谜图）也一起更新。
 */
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '../..')
const OUT = join(ROOT, 'models-private')
const LIST = join(ROOT, 'macos/models.json')
const INDEX = join(OUT, 'prts-index.json')
const WIKI = 'https://prts.wiki'
const ASSETS = 'https://torappu.prts.wiki/assets/char_spine'

const args = process.argv.slice(2)
const opt = (k, d) => (args.includes(k) ? args[args.indexOf(k) + 1] : d)
const rarity = Number(opt('--rarity', '6'))
const only = opt('--only', '')
  .split(',')
  .filter(Boolean)
const dry = args.includes('--dry')
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// PRTS 会拦浏览器样子的 UA，用一个说清来意的
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

const unescape = (s) =>
  s.replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n))).replace(/&(amp|quot|lt|gt|#039);/g, (m) => ({ '&amp;': '&', '&quot;': '"', '&lt;': '<', '&gt;': '>', '&#039;': "'" })[m])

async function operators() {
  const html = await get(`${WIKI}/w/${encodeURIComponent('干员一览')}`)
  const out = []
  // 每个干员一个带 data-rarity、data-zh… 的标签
  for (const m of html.matchAll(/<[a-z]+ ([^>]*data-rarity="[^"]*"[^>]*)>/g)) {
    const a = Object.fromEntries([...m[1].matchAll(/data-([a-z]+)="([^"]*)"/g)].map((x) => [x[1], unescape(x[2])]))
    if (a.zh && Number(a.rarity) + 1 === rarity && !out.includes(a.zh)) out.push(a.zh)
  }
  if (out.length === 0) throw new Error('干员一览里一个都没找到（页面结构变了？）')
  return out
}

/** 干员页 wikitext 里的「干员id=char_xxx」，用 API 一次查 40 个（逐页抓 HTML 太慢） */
async function charIds(names, index) {
  const todo = names.filter((n) => !index[n])
  for (let i = 0; i < todo.length; i += 40) {
    const titles = encodeURIComponent(todo.slice(i, i + 40).join('|'))
    const d = JSON.parse(await get(`${WIKI}/api.php?action=query&prop=revisions&rvprop=content&rvslots=main&format=json&formatversion=2&titles=${titles}`))
    const from = Object.fromEntries((d.query.normalized ?? []).map((n) => [n.to, n.from]))
    for (const p of d.query.pages) {
      const id = /\|干员id=(char_\w+)/.exec(p.revisions?.[0]?.slots?.main?.content ?? '')?.[1]
      if (id) index[from[p.title] ?? p.title] = id
    }
    await sleep(1000)
  }
}

/** Spine 二进制骨骼头：hash 字符串 + 版本字符串（长度是 varint，值 = 字节数 + 1） */
function skelVersion(buf) {
  let p = 0
  const str = () => {
    let n = 0
    for (let shift = 0; ; shift += 7) {
      const b = buf[p++]
      n |= (b & 0x7f) << shift
      if (!(b & 0x80)) break
    }
    if (n === 0) return null
    const s = buf.subarray(p, p + n - 1).toString('utf8')
    p += n - 1
    return s
  }
  str()
  return str()
}

function atlasPages(text) {
  const lines = text.split(/\r?\n/)
  return lines.filter((l, i) => /\.(png|webp)$/i.test(l.trim()) && /^size:/.test(lines[i + 1]?.trim() ?? '')).map((l) => l.trim())
}

async function save(url, file) {
  const data = await get(url, 'bin')
  if (!data) throw new Error(`缺文件 ${url}`)
  mkdirSync(dirname(file), { recursive: true })
  // 临时文件以 . 开头：万一留下来，publish.mjs 的 walk 也会跳过
  const tmp = join(dirname(file), `.${basename(file)}.tmp`)
  writeFileSync(tmp, data)
  renameSync(tmp, file)
  return data
}

/** 原子写 JSON（被超时杀掉也不会留下半个文件） */
function writeJSON(file, value, indent = 2) {
  const tmp = join(dirname(file), `.${basename(file)}.tmp`)
  writeFileSync(tmp, `${JSON.stringify(value, null, indent)}\n`)
  renameSync(tmp, file)
}

/** 一套时装里有一个模型组不能用（不是 3.8、读不懂）：整套跳过，别的时装照收 */
class SkinSkip extends Error {}

const skelFile = (local) => (existsSync(`${local}.json`) ? `${local}.json` : existsSync(`${local}.skel`) ? `${local}.skel` : null)

/** 本地已经齐了：每组的骨骼、图集、图集里的贴图都在 */
function complete(dir, groups) {
  for (const file of groups) {
    const local = join(dir, file)
    if (!skelFile(local) || !existsSync(`${local}.atlas`)) return false
    for (const page of atlasPages(readFileSync(`${local}.atlas`, 'utf8'))) if (!existsSync(join(dirname(local), page))) return false
  }
  return true
}

/**
 * 一个干员：全部时装 × 基建 / 正面 / 背面（或 spine/ 单套战斗模型）。
 * 本地已经齐了只更新 skins.json；否则在 models-private/.work-<id>/ 里补齐（先拷一份已有的），成功了才整个换进去，
 * 网络出错时正式目录原封不动（不会把半成品发布出去）。
 */
async function fetchModel(name, id) {
  const meta = JSON.parse((await get(`${ASSETS}/${id}/meta.json`)) ?? 'null')
  if (!meta?.skin) return { skip: 'PRTS 没有 Spine 数据' }
  const skinsIn = Object.entries(meta.skin).map(([skinName, groups]) => ({
    skinName,
    groups: Object.entries(groups).map(([group, { file }]) => ({ group, file })),
  }))
  for (const { groups } of skinsIn) {
    // spine/：只有一套战斗模型（不分正面背面）的干员，比如浊心斯卡蒂
    for (const { file } of groups) if (!/^[\w-]+\/(front|back|build|spine)\/[\w-]+$/.test(file)) return { skip: `路径不认识：${file}` }
  }
  const final = join(OUT, name)
  const allFiles = skinsIn.flatMap((s) => s.groups.map((g) => g.file))
  if (existsSync(join(final, 'skins.json')) && complete(final, allFiles)) {
    const skins = {}
    for (const { skinName, groups } of skinsIn) for (const { file } of groups) skins[file.split('/').pop().replace(/^build_/, '')] ??= skinName
    if (readFileSync(join(final, 'skins.json'), 'utf8') !== `${JSON.stringify(skins, null, 2)}\n`) writeJSON(join(final, 'skins.json'), skins)
    return { files: 0, skins: skinsIn.length, cached: true }
  }

  const work = join(OUT, `.work-${id}`)
  rmSync(work, { recursive: true, force: true })
  if (existsSync(final)) cpSync(final, work, { recursive: true })
  else mkdirSync(work, { recursive: true })
  try {
    let files = 0
    const skins = {}
    const bad = []
    // voice/ 是 fetch-voice.mjs 拉的基建语音，不归这里管
    const keep = new Set(['skins.json', 'voice'])
    for (const { skinName, groups } of skinsIn) {
      const folders = new Set(groups.map((g) => g.file.split('/')[0]))
      try {
        for (const { group, file } of groups) {
          const base = `${ASSETS}/${id}/${file}`
          const local = join(work, file)
          // 有些 .skel 其实是 Spine JSON：存成 .json（前端按扩展名选解析器，.json 里带 skeleton 才当骨骼）
          const have = skelFile(local)
          const skel = have ? readFileSync(have) : await save(`${base}.skel`, `${local}.skel`)
          let v
          if (skel[0] === 0x7b) {
            try {
              v = JSON.parse(skel.toString('utf8')).skeleton?.spine
            } catch {
              throw new SkinSkip(`${skinName}/${group} 的骨骼文件读不懂`)
            }
            if (existsSync(`${local}.skel`)) renameSync(`${local}.skel`, `${local}.json`)
          } else {
            v = skelVersion(skel)
          }
          if (!v?.startsWith('3.8')) throw new SkinSkip(`${skinName}/${group} 是 Spine ${String(v ?? '？').slice(0, 12)}，不是 3.8`)
          const atlas = (existsSync(`${local}.atlas`) ? readFileSync(`${local}.atlas`) : await save(`${base}.atlas`, `${local}.atlas`)).toString('utf8')
          files += 2
          for (const page of atlasPages(atlas)) {
            if (page.includes('/')) throw new SkinSkip(`${skinName}/${group} 的贴图名不认识：${page}`)
            const f = join(dirname(local), page)
            if (!existsSync(f) || statSync(f).size === 0) await save(`${dirname(base)}/${page}`, f)
            files++
          }
        }
      } catch (e) {
        if (!(e instanceof SkinSkip)) throw e
        bad.push(e.message)
        for (const f of folders) rmSync(join(work, f), { recursive: true, force: true })
        continue
      }
      for (const f of folders) keep.add(f)
      for (const { file } of groups) skins[file.split('/').pop().replace(/^build_/, '')] ??= skinName
    }
    if (Object.keys(skins).length === 0) return { skip: bad.join('；') || '没有可用的时装' }
    // PRTS 上已经没有的时装、上次跳过的残留：清掉
    for (const e of readdirSync(work)) if (!keep.has(e)) rmSync(join(work, e), { recursive: true, force: true })
    // 时装 key（骨骼文件名去掉 build_，和前端 loader 的 outfit 一致）→ PRTS 上的时装名（「默认」「午夜邮差」…），设置页用来显示
    writeJSON(join(work, 'skins.json'), skins)
    const old = join(OUT, `.old-${id}`)
    rmSync(old, { recursive: true, force: true })
    if (existsSync(final)) renameSync(final, old)
    renameSync(work, final)
    rmSync(old, { recursive: true, force: true })
    return { files, skins: Object.keys(skins).length, bad }
  } finally {
    rmSync(work, { recursive: true, force: true })
  }
}

const index = existsSync(INDEX) ? JSON.parse(readFileSync(INDEX, 'utf8')) : {}
const list = JSON.parse(readFileSync(LIST, 'utf8'))
const names = only.length ? only : await operators()
if (!only.length) for (const m of list) if (m.source === 'prts' && !names.includes(m.name)) names.push(m.name)
console.log(only.length ? `[prts] 指定 ${names.length} 名` : `[prts] ${rarity} 星 + 单独加入的 共 ${names.length} 名`)
await charIds(names, index)
writeJSON(INDEX, index, 1)
const skipped = []
for (const name of names) {
  try {
    if (name.includes('/') || name.startsWith('.')) throw new Error('名字不能当文件夹名')
    const id = index[name]
    if (!id) {
      skipped.push(`${name}：页面上没有干员 id`)
      continue
    }
    const known = list.find((m) => m.name === name)
    if (known && known.source !== 'prts') {
      console.log(`[prts] ${name} 已在 models.json（${known.id}），跳过`)
      continue
    }
    if (dry) {
      console.log(`[prts] ${name} ${id}`)
      continue
    }
    const r = await fetchModel(name, id)
    if (r.skip) {
      skipped.push(`${name}：${r.skip}`)
      continue
    }
    if (!known) {
      list.push({ id: id.replace(/_/g, '-'), name, dir: `models-private/${name}`, source: 'prts' })
      writeJSON(LIST, list)
    }
    if (!r.cached) console.log(`[prts] ${name} ${id} · ${r.skins} 套时装 · 下载 / 检查了 ${r.files} 个文件`)
    for (const b of r.bad ?? []) skipped.push(`${name}：跳过时装 ${b}`)
  } catch (e) {
    skipped.push(`${name}：${e.message}`)
  }
}
if (skipped.length) console.log(`[prts] 跳过 ${skipped.length} 个：\n  ${skipped.join('\n  ')}`)
