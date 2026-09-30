#!/usr/bin/env node
/**
 * scripts/check-design.mjs —— Rakko Design 前端合规检查（Node 标准库，零依赖）。
 *
 * 检查对象与规则：
 *   - web/src/**\/*.css、web/*.html 的内联 <style> 与 style="" 属性、web/src/**\/*.tsx 的文本：
 *       裸 hex（#fff / #ffffff / #000 / #000000 例外）、font-family 非 var()/inherit、
 *       transition: all、backdrop-filter（材质只能来自 vendor 的 glass.css / data-glass）、
 *       Tailwind neutral-50…950、同一规则块内 backdrop-filter + opacity: 0、
 *       font-weight 数值 > 600 或 bold/bolder（CJK 禁伪粗）；
 *       tsx 里 SVG 图标必须用 currentColor：fill="#…" / stroke="#…" 报错。
 *   - 零外网：web/** 里出现 fonts.googleapis、cdn.、@import url(http 报错。
 *   - 平台无关：web/src 里只有 native/transport.ts 能写 webkit.messageHandlers / chrome.webview。
 *   - 样式入口顺序：web/src/styles/app.css 前两条非注释语句必须依次是
 *       @import '@rakko/design-system/tokens.css'; 与 @import '@rakko/react/styles.css';
 *   - vendor 完整性（给了 RAKKO_DESIGN_DIR 时）：vendor/rakko-design/design-system/src/*
 *       与 react/src/**（排除测试）跟上游逐字节一致，上游有的非测试文件 vendor 都有，
 *       vendor 里也不许多出文件；tokens.generated.css 的两段与 scaffold 原文一致。
 *
 * 输出：逐条 `文件:行号: 原因`；有问题 exit 1，否则一行 OK + 统计。
 */
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..')
const RAKKO_DIR = process.env.RAKKO_DESIGN_DIR || ''

const WEB = join(ROOT, 'web')
// 带界面的页面：首屏要外链主题脚本。pet.html 是透明画布页，没有主题，不在其列
const UI_PAGES = ['settings.html', 'welcome.html', 'auth-callback.html'].map((name) => join(WEB, name))
const THEME_BOOT = join(WEB, 'public', 'theme-boot.js')
const APP_CSS = join(WEB, 'src/styles/app.css')
const VENDOR = join(ROOT, 'vendor/rakko-design')

const ALLOWED_HEX = new Set(['#fff', '#ffffff', '#000', '#000000'])
const BANNED_NEUTRAL_STEP = /\bneutral-(?:50|100|200|300|400|500|600|700|800|900|950)\b/g
const BANNED_NEUTRAL_CLASS =
  /\b(?:text|bg|border|ring|fill|stroke|from|to|via)-neutral-(?:50|100|200|300|400|500|600|700|800|900|950)\b/g
const OFFLINE = [
  ['fonts.googleapis', '外部字体（零外网：字体只用 token 里的字体栈）'],
  ['cdn.', 'CDN 资源（零外网：不许引外部资源）'],
  ['@import url(http', '外部 CSS @import（零外网）'],
]

/** @type {string[]} */
const issues = []
const rel = (p) => relative(ROOT, p).split('\\').join('/')
const add = (file, line, why) => issues.push(`${file}:${line}: ${why}`)

function lineOf(text, index) {
  let n = 1
  for (let i = 0; i < index && i < text.length; i += 1) if (text[i] === '\n') n += 1
  return n
}

function readText(path, what) {
  if (!existsSync(path)) {
    add(rel(path), 1, `缺少文件（${what}）`)
    return null
  }
  const text = readFileSync(path, 'utf8')
  if (!text.trim()) add(rel(path), 1, `文件是空的（${what}）`)
  return text
}

function listFiles(dir, out = []) {
  if (!existsSync(dir)) return out
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) listFiles(p, out)
    else out.push(p)
  }
  return out
}

const isTestFile = (name) =>
  /\.test\.tsx?$/.test(name) || name === 'vitest.setup.ts' || name.endsWith(`${sep}vitest.setup.ts`)

/* ------------------------------------------------------------------ 通用文本规则 */
/** 把注释内容换成等长空白（保留换行）：规则只查生效的代码，不在注释里报错。 */
function stripComments(text, { slash = false, html = false } = {}) {
  const blank = (m) => m.replace(/[^\n]/g, ' ')
  let out = text.replace(/\/\*[\s\S]*?\*\//g, blank)
  if (html) out = out.replace(/<!--[\s\S]*?-->/g, blank)
  if (slash) {
    // 行注释；前缀守卫避免吃掉 https:// 里的双斜杠
    out = out.replace(/(^|[^:\w])\/\/[^\n]*/g, (m, p1) => p1 + blank(m.slice(p1.length)))
  }
  return out
}

/* 规则集 A：声明式规则（hex / font-family / transition:all / backdrop-filter / font-weight） */
function lintDeclarations(
  rawText,
  file,
  baseLine = 1,
  { svg = false, slash = false, html = false } = {},
) {
  const text = stripComments(rawText, { slash, html })
  const at = (index) => baseLine + lineOf(text, index) - 1

  for (const m of text.matchAll(/#[\da-f]{3,8}\b/gi)) {
    if (!ALLOWED_HEX.has(m[0].toLowerCase())) {
      add(file, at(m.index), `裸 hex ${m[0]}（改用 var(--color-…) 或 color-mix）`)
    }
  }

  for (const m of text.matchAll(/font-family\s*:\s*([^;}]+)/gi)) {
    const value = m[1].trim()
    if (!value.startsWith('var(') && value !== 'inherit') {
      add(file, at(m.index), `硬编码 font-family "${value}"（改用 var(--font-…)）`)
    }
  }

  for (const m of text.matchAll(/transition\s*:\s*all\b/gi)) {
    add(file, at(m.index), '"transition: all" 会动画到无关属性')
  }

  for (const m of text.matchAll(/-?[a-z-]*backdrop-filter\s*:/gi)) {
    add(file, at(m.index), '不许写 backdrop-filter（材质只能来自 data-glass / vendor glass.css）')
  }

  for (const m of text.matchAll(/font-weight\s*:\s*([^;}]+)/gi)) {
    const value = m[1].trim().toLowerCase()
    const numeric = /^(\d{3,4})\b/.exec(value)
    if ((numeric && Number(numeric[1]) > 600) || value === 'bold' || value === 'bolder') {
      add(file, at(m.index), `font-weight ${value} > 600（中文最多 500）`)
    }
  }

  if (svg) {
    // 图标必须继承 currentColor：写死颜色的 fill / stroke 一律报错
    for (const m of text.matchAll(/\b(?:fill|stroke)\s*=\s*"#[^"]*"/g)) {
      add(file, at(m.index), `SVG 写死了颜色 ${m[0]}（图标必须用 currentColor）`)
    }
  }
}

/* 规则集 B：Tailwind neutral-50…950（步进值 + 工具类名）。整份文件只查一次。 */
function lintNeutral(rawText, file, baseLine = 1, { slash = false, html = false } = {}) {
  const text = stripComments(rawText, { slash, html })
  const at = (index) => baseLine + lineOf(text, index) - 1

  for (const m of text.matchAll(BANNED_NEUTRAL_STEP)) {
    add(file, at(m.index), `禁用的 Tailwind neutral 色阶 "${m[0]}"（只认 neutral-1…10）`)
  }
  for (const m of text.matchAll(BANNED_NEUTRAL_CLASS)) {
    add(file, at(m.index), `禁用的 Tailwind 类 "${m[0]}"（只认 --color-neutral-1…10）`)
  }
}

/* 规则集 C：零外网。整份文件只查一次。 */
function lintOffline(rawText, file, baseLine = 1, { slash = false, html = false } = {}) {
  const text = stripComments(rawText, { slash, html })
  const at = (index) => baseLine + lineOf(text, index) - 1

  for (const [needle, why] of OFFLINE) {
    let index = text.indexOf(needle)
    while (index !== -1) {
      add(file, at(index), why)
      index = text.indexOf(needle, index + 1)
    }
  }
}

/* ------------------------------------------------------------------ CSS 规则 */
function lintCss(rawCss, file, baseLine = 1) {
  lintDeclarations(rawCss, file, baseLine)
  lintNeutral(rawCss, file, baseLine)
  lintOffline(rawCss, file, baseLine)

  const css = stripComments(rawCss)

  // 毛玻璃出生规则：backdrop-filter 与 opacity: 0 同处一个规则块 = 从透明淡入
  for (const m of css.matchAll(/\{[^{}]*\}/g)) {
    const block = m[0]
    const bd = block.match(/backdrop-filter\s*:/)
    if (bd && /(^|[;{\s])opacity\s*:\s*0(?:\.0+)?%?(?![.\d])/.test(block)) {
      add(file, baseLine + lineOf(css, m.index + bd.index) - 1,
        'backdrop-filter 表面从 opacity: 0 淡入（必须从首帧起绘制）')
    }
  }
}

/* ------------------------------------------------------------------ HTML 规则 */
function lintHtml(rawHtml, file) {
  const html = stripComments(rawHtml, { html: true })

  // <style> 块按 CSS 查；neutral / 外网留给下面整份查，避免同一处报两遍
  for (const m of html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)) {
    const baseLine = lineOf(html, m.index + m[0].indexOf('>') + 1)
    lintCss(m[1], file, baseLine)
  }

  // style="" 内联属性：只看这一小段声明，别让 [^;}]+ 顺着正文吃飞
  for (const m of html.matchAll(/\sstyle\s*=\s*"([^"]*)"/gi)) {
    lintDeclarations(m[1], file, lineOf(html, m.index))
  }

  lintNeutral(html, file)
  lintOffline(html, file)
}

/* ------------------------------------------------------------------ 平台无关 */
const TRANSPORT = join(WEB, 'src/native/transport.ts')
const WEBVIEW_API = /\bmessageHandlers\b|\bchrome\s*\??\.\s*webview\b/g

function checkPlatformNeutral() {
  for (const abs of listFiles(join(WEB, 'src'))) {
    if (abs === TRANSPORT || !/\.tsx?$/.test(abs)) continue
    const text = stripComments(readFileSync(abs, 'utf8'), { slash: true })
    for (const m of text.matchAll(WEBVIEW_API)) {
      add(rel(abs), lineOf(text, m.index), `直接用了 WebView 接口 "${m[0]}"（只许在 web/src/native/transport.ts 里）`)
    }
  }
}

/* ------------------------------------------------------------------ 样式入口顺序 */
function checkStyleEntry() {
  const css = readText(APP_CSS, '应用样式入口')
  if (css === null) return

  const want = ["'@rakko/design-system/tokens.css'", "'@rakko/react/styles.css'"]
  const imports = [...css.matchAll(/@import\s+([^;]+);/g)].map((m) =>
    m[1].trim().replace(/\s+/g, ' '),
  )
  if (imports.length < 2 || imports[0] !== want[0] || imports[1] !== want[1]) {
    add(
      rel(APP_CSS),
      1,
      `样式入口顺序错：前两条 @import 必须依次是 ${want.join(' → ')}（现在是 ${imports.slice(0, 2).join(' → ') || '空'}）`,
    )
  }

  const stripped = css.replace(/\/\*[\s\S]*?\*\//g, '').trimStart()
  if (!stripped.startsWith('@import')) {
    add(rel(APP_CSS), 1, '第一条非注释语句必须是 @import（样式顺序契约）')
  }
}

/* ------------------------------------------------------------------ 页面脚本与首屏主题 */
function checkPageScripts() {
  // 019：CSP 是 script-src 'self' ⇒ 所有页面都不许有内联脚本（不许运行时算 hash）
  for (const abs of listFiles(WEB)) {
    if (!abs.endsWith('.html') || relative(WEB, abs).split(sep)[0] === 'dist') continue
    const html = stripComments(readFileSync(abs, 'utf8'), { html: true })
    if (/<script(?![^>]*\bsrc=)[^>]*>[\s\S]*?<\/script>/i.test(html)) {
      add(rel(abs), 1, "有内联 <script>：CSP 是 script-src 'self'，脚本必须外链（不许运行时算 hash）")
    }
  }
  // 界面页的首屏主题脚本必须外链到 web/public/theme-boot.js；页面用相对 base，所以接受 ./theme-boot.js
  for (const page of UI_PAGES) {
    const raw = readText(page, '界面页')
    if (raw === null) continue
    const html = stripComments(raw, { html: true })
    if (!/<script[^>]*\bsrc=["'](?:\.?\/)?theme-boot\.js["'][^>]*>/i.test(html)) {
      add(rel(page), 1, '缺 <script src="./theme-boot.js">：首屏主题脚本必须外链')
    }
  }
  const boot = readText(THEME_BOOT, '首屏主题脚本')
  if (boot === null) return
  if (!boot.includes('localStorage')) {
    add(rel(THEME_BOOT), 1, '缺首屏主题逻辑：没读到 localStorage.rakkoTheme')
  }
  if (!boot.includes('prefers-color-scheme')) {
    add(rel(THEME_BOOT), 1, '缺首屏主题逻辑：没读到 prefers-color-scheme')
  }
}

/* ------------------------------------------------------------------ vendor 完整性 */
function extractScaffoldTokens(html) {
  const styleBlocks = [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map((m) => m[1])
  if (styleBlocks.length === 0) throw new Error('scaffold.html 里找不到任何 <style> 块')
  const first = styleBlocks[0]
  const root = first.match(/:root\s*\{([^{}]*)\}/)
  const dark = first.match(/\[data-theme\s*=\s*['"]dark['"]\]\s*\{([^{}]*)\}/)
  if (!root || !root[1].trim()) throw new Error('scaffold.html 第一个 <style> 里没有非空 :root 块')
  if (!dark || !dark[1].trim()) {
    throw new Error("scaffold.html 第一个 <style> 里没有非空 [data-theme='dark'] 块")
  }
  return { root: root[1].trim(), dark: dark[1].trim() }
}

function checkVendor() {
  const required = [
    'design-system/src/glass.css',
    'design-system/src/state-layer.css',
    'design-system/src/tokens.css',
    'design-system/src/ripple.js',
    'design-system/src/ripple-geometry.js',
    'design-system/src/ripple.d.ts',
    'react/src/index.ts',
    'react/src/styles.css',
    'tokens.generated.css',
    'VERSION',
    'README.md',
  ]
  for (const name of required) {
    if (!existsSync(join(VENDOR, name))) {
      add(`vendor/rakko-design/${name}`, 1, '缺少设计系统外来件（先跑 pnpm sync-design）')
    }
  }

  const versionPath = join(VENDOR, 'VERSION')
  if (existsSync(versionPath)) {
    const version = readFileSync(versionPath, 'utf8')
    for (const key of ['commit=', 'synced=', 'source=', 'resolved_from=', 'ref=']) {
      if (!version.includes(key)) add('vendor/rakko-design/VERSION', 1, `VERSION 里缺少 ${key}`)
    }
  }

  const tokensPath = join(VENDOR, 'tokens.generated.css')
  const stats = { compared: 0, note: '' }

  if (!RAKKO_DIR) {
    stats.note = '未给 RAKKO_DESIGN_DIR：跳过与上游的逐字比对'
    return stats
  }
  if (!existsSync(RAKKO_DIR)) {
    add('vendor/rakko-design', 1, `RAKKO_DESIGN_DIR=${RAKKO_DIR} 不存在`)
    return stats
  }

  const upstream = []
  const dsSrc = join(RAKKO_DIR, 'design-system/src')
  for (const abs of listFiles(dsSrc)) {
    upstream.push({ rel: `design-system/src/${relative(dsSrc, abs)}`, abs })
  }
  const reactSrc = join(RAKKO_DIR, 'react/src')
  for (const abs of listFiles(reactSrc)) {
    const inner = relative(reactSrc, abs)
    if (isTestFile(inner)) continue
    upstream.push({ rel: `react/src/${inner}`, abs })
  }

  for (const { rel: name, abs } of upstream) {
    const local = join(VENDOR, name)
    if (!existsSync(local)) {
      add(`vendor/rakko-design/${name}`, 1, '上游有但 vendor 没有（跑 pnpm sync-design）')
      continue
    }
    if (!readFileSync(local).equals(readFileSync(abs))) {
      add(`vendor/rakko-design/${name}`, 1, `与上游 ${name} 不是逐字节一致（重跑 pnpm sync-design）`)
      continue
    }
    stats.compared += 1
  }

  const known = new Set(upstream.map((u) => u.rel))
  for (const sub of ['design-system/src', 'react/src']) {
    for (const abs of listFiles(join(VENDOR, sub))) {
      const name = `${sub}/${relative(join(VENDOR, sub), abs)}`
      if (!known.has(name)) {
        add(`vendor/rakko-design/${name}`, 1, 'vendor 里多出来的文件（上游没有；外来件不许手加）')
      }
    }
  }

  // tokens.generated.css 必须与 scaffold 两段原文一致（生成物，不是拷贝）
  const scaffoldPath = join(RAKKO_DIR, 'design-system/templates/scaffold.html')
  if (!existsSync(scaffoldPath)) {
    add('vendor/rakko-design/tokens.generated.css', 1, `上游 scaffold.html 不存在：${scaffoldPath}`)
  } else if (existsSync(tokensPath)) {
    try {
      const { root, dark } = extractScaffoldTokens(readFileSync(scaffoldPath, 'utf8'))
      const tokens = readFileSync(tokensPath, 'utf8')
      const rootBody = tokens.match(/:root\s*\{([^{}]*)\}/)
      const darkBody = tokens.match(/\[data-theme\s*=\s*['"]dark['"]\]\s*\{([^{}]*)\}/)
      if (!rootBody || rootBody[1].trim() !== root) {
        add('vendor/rakko-design/tokens.generated.css', 1, '生成的 :root 块与 scaffold.html 原文不一致')
      }
      if (!darkBody || darkBody[1].trim() !== dark) {
        add('vendor/rakko-design/tokens.generated.css', 1,
          "生成的 [data-theme='dark'] 块与 scaffold.html 原文不一致")
      }
      if (!/generated by scripts\/sync-design\.sh/.test(tokens)) {
        add('vendor/rakko-design/tokens.generated.css', 1, '缺少「generated by」文件头（不许手改）')
      }
    } catch (err) {
      add('vendor/rakko-design/tokens.generated.css', 1, `scaffold 结构变了：${err.message}`)
    }
  }

  return stats
}

/* ------------------------------------------------------------------ main */
let checked = 0

for (const abs of listFiles(WEB)) {
  const inner = relative(WEB, abs)
  if (inner === 'dist' || inner.startsWith(`dist${sep}`)) continue // 构建产物不查

  const name = rel(abs)
  const text = readFileSync(abs, 'utf8')
  checked += 1

  if (abs.endsWith('.css')) {
    lintCss(text, name)
  } else if (abs.endsWith('.tsx') || abs.endsWith('.ts')) {
    lintDeclarations(text, name, 1, { svg: abs.endsWith('.tsx'), slash: true })
    lintNeutral(text, name, 1, { slash: true })
    lintOffline(text, name, 1, { slash: true })
  } else if (abs.endsWith('.html')) {
    lintHtml(text, name)
  }
}

checkPageScripts()
checkPlatformNeutral()
checkStyleEntry()
const parity = checkVendor()

if (issues.length > 0) {
  console.error('check-design 未通过：')
  for (const issue of issues) console.error(`  - ${issue}`)
  console.error(`共 ${issues.length} 条问题。`)
  process.exit(1)
}

const suffix = parity.note
  ? `（${parity.note}）`
  : `（与上游逐字一致的 vendor 文件：${parity.compared} 个）`
console.log(`OK: web/ 与 vendor/ 全部合规：查了 ${checked} 个 web 文件${suffix}`)
