/**
 * 看各台 Rhodeside 自动上传的日志（服务器 /opt/stacks/rhodeside/logs，见那里的 auth/server.mjs）。
 *
 *   node macos/scripts/remote-logs.mjs                    列出所有设备：账号、电脑名、用户、版本、最后上传、崩溃报告数
 *   node macos/scripts/remote-logs.mjs <关键词> [行数]     看一台设备日志的最后几行（默认 120）
 *   node macos/scripts/remote-logs.mjs --crash <关键词>    看这台设备最新的系统崩溃报告
 *
 * 关键词匹配账号 / 设备 id 前缀 / 电脑名 / 用户名的一部分（不分大小写），或者写成 `<账号>/<设备 id 前缀>`；要刚好匹配到一台
 * （同一台设备登录前后分在 _anon 和账号两个目录时算一台，日志按时间接起来）。
 * 日志是别人传上来的任意字节：输出前把控制字符换成可见的 \xNN，免得终端转义序列被执行。
 * 目录：<账号 sub 或 _anon>/<设备 UUID>/{rhodeside.log, rhodeside.1.log, crash/*.ips, meta.json}
 */
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'

const DIR = process.env.RHODESIDE_LOG_DIR ?? '/opt/stacks/rhodeside/logs'
const args = process.argv.slice(2)
const crash = args.includes('--crash')
const [needle, count] = args.filter((a) => a !== '--crash')

/** 保留换行和制表符，其余控制字符（含 ESC、C1）换成 \xNN */
const safe = (text) => text.replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, (c) => `\\x${c.charCodeAt(0).toString(16).padStart(2, '0')}`)
const dirs = (p) => (existsSync(p) ? readdirSync(p, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name) : [])
const read = (p) => {
  try {
    return JSON.parse(readFileSync(p, 'utf8'))
  } catch {
    return {}
  }
}
const when = (iso) => (iso ? new Date(iso).toLocaleString('zh-CN', { hour12: false }) : '-')
const build = (b) => (Number(b) > 0 ? new Date(Number(b)).toLocaleString('zh-CN', { hour12: false }) : '-')

const devices = dirs(DIR).flatMap((owner) =>
  dirs(join(DIR, owner)).map((device) => {
    const path = join(DIR, owner, device)
    return { owner, device, path, meta: read(join(path, 'meta.json')), crashes: existsSync(join(path, 'crash')) ? readdirSync(join(path, 'crash')).sort() : [] }
  }),
)
devices.sort((a, b) => String(b.meta.last ?? '').localeCompare(String(a.meta.last ?? '')))

const list = (ds) => {
  if (ds.length === 0) return console.log(`（${DIR} 里还没有日志）`)
  for (const d of ds) {
    const m = d.meta
    console.log(
      safe([
        d.device.slice(0, 8),
        d.owner,
        m.host || '-',
        m.user || '-',
        `App ${build(m.build)}`,
        `最后 ${when(m.last)}（${m.lastReason ?? '-'}）`,
        d.crashes.length ? `崩溃报告 ${d.crashes.length}` : '',
      ]
        .filter(Boolean)
        .join('  ')),
    )
  }
}

if (!needle) {
  list(devices)
  process.exit(0)
}

const k = needle.toLowerCase()
const hits = devices.filter((d) =>
  k.includes('/')
    ? `${d.owner}/${d.device}`.toLowerCase().startsWith(k)
    : [d.owner, d.meta.host, d.meta.user].some((v) => String(v ?? '').toLowerCase().includes(k)) || d.device.startsWith(k),
)
const sameDevice = hits.length > 1 && hits.every((d) => d.device === hits[0].device)
if (hits.length !== 1 && !sameDevice) {
  console.error(hits.length ? `「${needle}」匹配到 ${hits.length} 台，说得再具体点：` : `没有匹配「${needle}」的设备：`)
  list(hits.length ? hits : devices)
  process.exit(1)
}

// 同一台设备的几个目录：按最后上传时间从旧到新
const parts = [...hits].sort((a, b) => String(a.meta.last ?? '').localeCompare(String(b.meta.last ?? '')))
for (const d of parts) console.error(safe(`# ${d.owner}/${d.device}  ${d.meta.host ?? ''}  ${d.meta.user ?? ''}  最后上传 ${when(d.meta.last)}`))
if (crash) {
  const last = parts
    .flatMap((d) => d.crashes.map((f) => join(d.path, 'crash', f)))
    .sort((a, b) => statSync(a).mtimeMs - statSync(b).mtimeMs)
    .at(-1)
  if (!last) {
    console.error('这台设备没有上传过崩溃报告')
    process.exit(1)
  }
  console.error(`# ${last}`)
  console.log(safe(readFileSync(last, 'utf8')))
} else {
  const n = Number(count) > 0 ? Number(count) : 120
  const text = parts
    .flatMap((d) => ['rhodeside.1.log', 'rhodeside.log'].map((f) => join(d.path, f)))
    .filter(existsSync)
    .map((f) => readFileSync(f, 'utf8'))
    .join('')
  console.log(safe(text.trimEnd().split('\n').slice(-n).join('\n')))
}
