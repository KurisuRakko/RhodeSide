/**
 * 发布到公网更新通道（rhodeside.rakko.cn，容器见 /opt/stacks/rhodeside）。
 *
 *   node macos/scripts/publish.mjs --dir macos/.build-web              前端
 *   node macos/scripts/publish.mjs --app Rhodeside.tar.gz --build N    App（build-app.sh --package 的产物）
 *   node macos/scripts/publish.mjs --models macos/models.json          在线模型（有授权的模型只放这里，登录后才能下载）
 *
 * 产物：
 *   <RELEASE_DIR>/v1/bundles/web-<build>.tar.gz + v1/manifest.json   前端包（不含 models/）与清单
 *   <RELEASE_DIR>/v1/apps/Rhodeside-<build>.tar.gz + v1/app.json      App 包与清单
 *   <RELEASE_DIR>/v1/models/<id>-<version>.tar.gz + v1/models.json   模型包与目录（version = 模型内容的哈希，没改就不重新打包）
 *   <RELEASE_DIR>/v1/previews/<id>-<version>.tar.gz                  模型库预览：只有默认时装的基建模型
 * 目录里每个模型另带译名 names {en, zh-Hant} 和 outfits {时装 key: {en, zh-Hant}}（英文来自 models-private/names.json，
 * 繁体是发布时简转繁（香港用词））；译名不进 version，改译名不会让已装的模型重新下载。
 * 自动的译名不对时（专有名被简转繁转错，如「余」→「餘」；PRTS 的英文名不是国际服的），在 models.json 那一条写
 * "names": {"en": "…", "zh-Hant": "…"} 覆盖。
 * 清单是签名信封 {key, payload, sig}：payload 是 JSON 的 base64（kind 区分 web / app），sig 是对 payload 原始字节的
 * Ed25519 签名；App 内置公钥，验不过就不用。私钥：~/.config/rhodeside/release-ed25519.pem（600，不进仓库）。
 */
import { execFileSync } from 'node:child_process'
import { createHash, createPrivateKey, sign } from 'node:crypto'
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, relative, resolve } from 'node:path'

/** 原生层 ↔ 网页的消息协议版本：改了协议就和 Sources/Rhodeside/RemoteUpdater.swift 一起 +1 */
const BRIDGE = 4
const KEEP = 10
const KEY_ID = 'rhodeside-2026-09'

const args = process.argv.slice(2)
const opt = (name, fallback) => {
  const i = args.indexOf(name)
  return i >= 0 ? args[i + 1] : fallback
}
const releaseDir = resolve(process.env.RHODESIDE_RELEASE_DIR ?? '/opt/stacks/rhodeside/data')
const keyPath = process.env.RHODESIDE_SIGNING_KEY ?? join(homedir(), '.config/rhodeside/release-ed25519.pem')

const fail = (msg) => {
  console.error(`[publish] ${msg}`)
  process.exit(1)
}

if (!existsSync(keyPath)) fail(`缺签名私钥 ${keyPath}`)
const key = createPrivateKey(readFileSync(keyPath))

/** 先放包再换清单：客户端看到新清单时包一定已经在了；旧包只留最近 keep 个 */
function release({ kind, build, bytes, sub, prefix, manifestName, keep }) {
  const bundlesDir = join(releaseDir, 'v1', sub)
  mkdirSync(bundlesDir, { recursive: true })
  const name = `${prefix}-${build}.tar.gz`
  writeFileSync(join(bundlesDir, `.${name}.tmp`), bytes)
  renameSync(join(bundlesDir, `.${name}.tmp`), join(bundlesDir, name))
  const payload = Buffer.from(
    JSON.stringify({
      schema: 1,
      kind,
      channel: 'dev',
      build,
      bridge: BRIDGE,
      created: new Date().toISOString(),
      bundle: { path: `v1/${sub}/${name}`, sha256: createHash('sha256').update(bytes).digest('hex'), size: bytes.length },
    }),
  )
  const envelope = { key: KEY_ID, payload: payload.toString('base64'), sig: sign(null, payload, key).toString('base64') }
  const manifest = join(releaseDir, 'v1', manifestName)
  writeFileSync(`${manifest}.tmp`, `${JSON.stringify(envelope)}\n`)
  renameSync(`${manifest}.tmp`, manifest)
  const re = new RegExp(`^${prefix}-(\\d+)\\.tar\\.gz$`)
  const old = readdirSync(bundlesDir)
    .filter((f) => re.test(f))
    .sort((a, b) => Number(b.match(re)[1]) - Number(a.match(re)[1]))
    .slice(keep)
  for (const f of old) rmSync(join(bundlesDir, f))
  console.log(`[publish] ${kind} build ${build} · ${(bytes.length / 1024).toFixed(0)} KB · ${statSync(manifest).size} B 清单`)
}

function signEnvelope(obj) {
  const payload = Buffer.from(JSON.stringify(obj))
  return { key: KEY_ID, payload: payload.toString('base64'), sig: sign(null, payload, key).toString('base64') }
}

function walk(dir, base = dir) {
  return readdirSync(dir, { withFileTypes: true })
    .filter((e) => !e.name.startsWith('.'))
    .flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name), base) : [relative(base, join(dir, e.name))]))
    .sort()
}

/** 把 files（相对 src）打成只有一个顶层文件夹 <name>/ 的 tar.gz */
function tarModel(src, name, files, out, tag) {
  const stage = join(releaseDir, `.${tag}`)
  rmSync(stage, { recursive: true, force: true })
  for (const f of files) {
    mkdirSync(dirname(join(stage, name, f)), { recursive: true })
    cpSync(join(src, f), join(stage, name, f))
  }
  execFileSync('tar', ['-czf', `${out}.tmp`, '--owner=0', '--group=0', '--numeric-owner', '-C', stage, name])
  renameSync(`${out}.tmp`, out)
  rmSync(stage, { recursive: true, force: true })
}

/**
 * 预览用的那套：默认时装的基建模型（skins.json 里叫「默认」的，没有就 defaultskin/ 目录、再没有就第一套基建），
 * 只要骨骼 + 同名图集 + 图集里用到的贴图（含分离的 [alpha] 透明通道）
 */
function previewFiles(src, files) {
  const skel = /\.skel(\.bytes)?$|\.json$/i
  const builds = files.filter((f) => skel.test(f) && /(^|\/)build_[^/]+$/i.test(f))
  if (builds.length === 0) return null
  let names = {}
  try {
    names = JSON.parse(readFileSync(join(src, 'skins.json'), 'utf8'))
  } catch {}
  const stemOf = (f) => f.split('/').pop().replace(skel, '').replace(/^build_/i, '')
  const pick =
    builds.find((f) => names[stemOf(f)] === '默认') ?? builds.find((f) => /(^|\/)defaultskin\//i.test(f)) ?? builds[0]
  const dir = pick.includes('/') ? pick.slice(0, pick.lastIndexOf('/') + 1) : ''
  const base = pick.split('/').pop().replace(skel, '')
  const atlas = files.find((f) => f === `${dir}${base}.atlas` || f === `${dir}${base}.atlas.txt`)
  if (!atlas) return null
  const lines = readFileSync(join(src, atlas), 'utf8').split(/\r?\n/)
  const pages = lines.filter((l, i) => /\.(png|webp)$/i.test(l.trim()) && /^size:/.test(lines[i + 1]?.trim() ?? '')).map((l) => l.trim())
  const out = [pick, atlas]
  for (const page of pages) {
    const stem = page.replace(/\.(png|webp)$/i, '')
    for (const f of [`${dir}${page}`, `${dir}${stem}[alpha].png`, `${dir}${stem}_alpha.png`]) if (files.includes(f)) out.push(f)
  }
  return out
}

/**
 * 译名：干员名 {en?, zh-Hant} + 每套时装 {en?, zh-Hant}。默认时装统一叫 Default / 預設。
 * 没有 skins.json（导入的 / 自己打包的）只翻干员名。
 */
function translations(src, zh, en, hk, override) {
  const names = { ...(en?.en ? { en: en.en } : {}), 'zh-Hant': hk(zh), ...override }
  let skins = {}
  try {
    skins = JSON.parse(readFileSync(join(src, 'skins.json'), 'utf8'))
  } catch {}
  const outfits = {}
  for (const [key, name] of Object.entries(skins)) {
    if (name === '默认') outfits[key] = { en: 'Default', 'zh-Hant': '預設' }
    else outfits[key] = { ...(en?.skins?.[key] ? { en: en.skins[key] } : {}), 'zh-Hant': hk(name) }
  }
  return Object.keys(outfits).length ? { names, outfits } : { names }
}

/** 时装套数：skins.json 有就数它，没有就数不同的骨骼名（去掉 build_） */
function skinCount(src, files) {
  try {
    return Object.keys(JSON.parse(readFileSync(join(src, 'skins.json'), 'utf8'))).length
  } catch {
    return new Set(files.filter((f) => /\.skel(\.bytes)?$/i.test(f)).map((f) => f.split('/').pop().replace(/\.skel(\.bytes)?$/i, '').replace(/^build_/i, ''))).size
  }
}

async function publishModels(listFile) {
  const root = resolve(dirname(listFile), '..')
  const list = JSON.parse(readFileSync(listFile, 'utf8'))
  // fetch-prts.mjs 写的英文名；没有就只有繁体
  const namesFile = join(root, 'models-private/names.json')
  let english = {}
  try {
    if (existsSync(namesFile)) english = JSON.parse(readFileSync(namesFile, 'utf8'))
  } catch (e) {
    console.warn(`[publish] ${namesFile} 读不懂，这次没有英文名：${e.message}`)
  }
  // 服务器上还没 pnpm install 过新依赖时不要让每天的同步失败：繁体译名先原样用中文
  let hk = (s) => s
  try {
    const { Converter } = await import('opencc-js')
    hk = Converter({ from: 'cn', to: 'hk' })
  } catch (e) {
    console.warn(`[publish] 没装 opencc-js（corepack pnpm install），这次繁体译名用简体原文：${e.message}`)
  }
  const dir = join(releaseDir, 'v1/models')
  const previewDir = join(releaseDir, 'v1/previews')
  mkdirSync(dir, { recursive: true })
  mkdirSync(previewDir, { recursive: true })
  const models = []
  for (const m of list) {
    if (!/^[a-z0-9-]+$/.test(m.id)) fail(`模型 id 只能用小写字母、数字、-：${m.id}`)
    const src = resolve(root, m.dir)
    if (!existsSync(src)) fail(`找不到模型目录 ${src}`)
    if (m.name.includes('/') || m.name.startsWith('.')) fail(`模型名不合法：${m.name}`)
    const files = walk(src)
    if (files.length === 0) fail(`模型目录是空的：${src}`)
    const h = createHash('sha256')
    h.update(`${m.name}\n`) // 改名也算新版本：包里的顶层文件夹名就是模型名
    for (const f of files) h.update(`${f}\0${createHash('sha256').update(readFileSync(join(src, f))).digest('hex')}\n`)
    const version = h.digest('hex').slice(0, 16)
    const name = `${m.id}-${version}.tar.gz`
    const file = join(dir, name)
    // 包里只有一个顶层文件夹 <模型名>/，App 解压后整个挪进 models/
    if (!existsSync(file)) tarModel(src, m.name, files, file, `model-${m.id}`)
    const bytes = readFileSync(file)
    let preview = null
    const pf = previewFiles(src, files)
    if (pf) {
      const pfile = join(previewDir, `${m.id}-${version}.tar.gz`)
      if (!existsSync(pfile)) tarModel(src, m.name, pf, pfile, `preview-${m.id}`)
      const pbytes = readFileSync(pfile)
      preview = { path: `v1/previews/${m.id}-${version}.tar.gz`, sha256: createHash('sha256').update(pbytes).digest('hex'), size: pbytes.length }
    }
    models.push({
      id: m.id,
      name: m.name,
      version,
      path: `v1/models/${name}`,
      sha256: createHash('sha256').update(bytes).digest('hex'),
      size: bytes.length,
      default: !!m.default,
      skins: skinCount(src, files),
      preview,
      ...translations(src, m.name, english[m.name], hk, m.names),
    })
    console.log(`[publish] model ${m.id} ${version} · ${(bytes.length / 1024).toFixed(0)} KB · ${files.length} 个文件${preview ? ` · 预览 ${(preview.size / 1024).toFixed(0)} KB` : ' · 没有预览'}`)
  }
  const catalog = join(releaseDir, 'v1/models.json')
  writeFileSync(`${catalog}.tmp`, `${JSON.stringify(signEnvelope({ schema: 1, kind: 'models', build: Date.now(), models }))}\n`)
  renameSync(`${catalog}.tmp`, catalog)
  // 目录里不再引用的旧版本包删掉
  const live = new Set(models.map((m) => m.path.split('/').pop()))
  for (const f of readdirSync(dir)) if (f.endsWith('.tar.gz') && !live.has(f)) rmSync(join(dir, f))
  const livePreviews = new Set(models.flatMap((m) => (m.preview ? [m.preview.path.split('/').pop()] : [])))
  for (const f of readdirSync(previewDir)) if (f.endsWith('.tar.gz') && !livePreviews.has(f)) rmSync(join(previewDir, f))
}

const modelsFile = opt('--models', '')
const appFile = opt('--app', '')
if (modelsFile) {
  await publishModels(resolve(modelsFile))
} else if (appFile) {
  const build = Number(opt('--build', ''))
  if (!Number.isSafeInteger(build) || build <= 0) fail(`--build 不对：${build}`)
  if (!existsSync(appFile)) fail(`找不到 App 包 ${appFile}`)
  release({ kind: 'app', build, bytes: readFileSync(appFile), sub: 'apps', prefix: 'Rhodeside', manifestName: 'app.json', keep: 5 })
} else {
  const dir = resolve(opt('--dir', ''))
  if (!existsSync(join(dir, 'pet.html'))) fail(`--dir 不是编好的前端目录（缺 pet.html）：${dir}`)
  const buildFile = join(dir, '.rhodeside-build')
  if (!existsSync(buildFile)) fail(`缺 ${buildFile}（由 deploy.sh 的 build_web 写入）`)
  const build = Number(readFileSync(buildFile, 'utf8').trim())
  if (!Number.isSafeInteger(build) || build <= 0) fail(`.rhodeside-build 内容不对：${build}`)
  const tmp = join(releaseDir, `.web-${build}.tar.gz.tmp`)
  mkdirSync(releaseDir, { recursive: true })
  execFileSync('tar', ['-czf', tmp, '--exclude=./models', '-C', dir, '.'])
  const bytes = readFileSync(tmp)
  rmSync(tmp)
  release({ kind: 'web', build, bytes, sub: 'bundles', prefix: 'web', manifestName: 'manifest.json', keep: KEEP })
  publishCallback(dir)
}

/** Priestess 登录回跳页 /auth/callback：和前端一起编，整目录替换 <RELEASE_DIR>/auth */
function publishCallback(dir) {
  if (!existsSync(join(dir, 'auth-callback.html'))) fail('前端里缺 auth-callback.html')
  const next = join(releaseDir, '.auth.new')
  const live = join(releaseDir, 'auth')
  const prev = join(releaseDir, '.auth.old')
  rmSync(next, { recursive: true, force: true })
  rmSync(prev, { recursive: true, force: true })
  mkdirSync(next, { recursive: true })
  cpSync(join(dir, 'auth-callback.html'), join(next, 'callback.html'))
  cpSync(join(dir, 'theme-boot.js'), join(next, 'theme-boot.js'))
  // 只放回跳页真正引用到的资源（从 html 出发顺着 import 找），不把整个前端公开出去
  mkdirSync(join(next, 'assets'))
  const todo = [...readFileSync(join(dir, 'auth-callback.html'), 'utf8').matchAll(/\.\/assets\/([\w.-]+)/g)].map((m) => m[1])
  const done = new Set()
  while (todo.length) {
    const f = todo.pop()
    if (done.has(f)) continue
    done.add(f)
    cpSync(join(dir, 'assets', f), join(next, 'assets', f))
    if (f.endsWith('.js')) for (const m of readFileSync(join(dir, 'assets', f), 'utf8').matchAll(/["'`]\.\/([\w.-]+\.(?:js|css))["'`]/g)) todo.push(m[1])
  }
  if (existsSync(live)) renameSync(live, prev)
  renameSync(next, live)
  rmSync(prev, { recursive: true, force: true })
}
