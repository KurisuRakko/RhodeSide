#!/usr/bin/env node
/**
 * Rhodeside 热更新：盯着源码，改了就自动推到 Mac。
 *   - 只改了前端（web/src、pet.html、settings.html、spine 运行时）→ deploy.sh web：
 *     发布到公网通道，App 几秒内拉取并原地重载（位置、行为在原生层，不受影响；不需要 Tailscale）
 *   - 改了 Swift / Info.plist / 打包脚本 → deploy.sh（全量，需要能 ssh 到 Mac）：重新编译、重启 App，桌宠回到退出前的位置
 * 用法：node macos/scripts/dev.mjs      （Ctrl-C 退出）
 */
import { spawn } from 'node:child_process'
import { watch } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const MACOS = join(dirname(fileURLToPath(import.meta.url)), '..')
const ROOT = join(MACOS, '..')
const DEPLOY = join(MACOS, 'scripts/deploy.sh')

const WATCH = [
  ['web', join(ROOT, 'web/src')],
  ['web', join(ROOT, 'web/pet.html')],
  ['web', join(ROOT, 'web/settings.html')],
  ['web', join(ROOT, 'web/welcome.html')],
  ['web', join(ROOT, 'web/auth-callback.html')],
  ['web', join(ROOT, 'web/public/rhodeside-tuning.json')],
  ['web', join(ROOT, 'web/public/lib')],
  ['web', join(ROOT, 'web/public/theme-boot.js')],
  ['full', join(MACOS, 'Sources')],
  ['full', join(MACOS, 'Resources')],
  ['full', join(MACOS, 'Package.swift')],
  ['full', join(MACOS, 'scripts/build-app.sh')],
]
const SKIP = [/(^|\/)\.[^/]*$/, /~$/, /\.swp$/, /^4913$/]

let pending = null
let running = false
let timer = null

const stamp = () => new Date().toTimeString().slice(0, 8)
const log = (s) => console.log(`\x1b[35m[dev ${stamp()}]\x1b[0m ${s}`)

function schedule(kind, file) {
  pending = pending === 'full' || kind === 'full' ? 'full' : 'web'
  log(`${file} 变了 → 待推：${pending === 'full' ? '全量（会重启 App）' : '网页热更新'}`)
  clearTimeout(timer)
  timer = setTimeout(run, 500)
}

function run() {
  if (running || !pending) return
  const kind = pending
  pending = null
  running = true
  const t0 = Date.now()
  const child = spawn('bash', [DEPLOY, kind], { stdio: 'inherit' })
  child.on('exit', (code) => {
    running = false
    log(code === 0 ? `✓ ${kind === 'web' ? '网页已热更新' : '已重新安装'}（${((Date.now() - t0) / 1000).toFixed(1)}s）` : `✗ deploy.sh ${kind} 失败（exit ${code}）`)
    if (pending) run()
  })
}

for (const [kind, path] of WATCH) {
  try {
    watch(path, { recursive: true }, (_event, file) => {
      const name = String(file ?? '')
      if (SKIP.some((re) => re.test(name))) return
      schedule(kind, name || path)
    })
  } catch (err) {
    log(`监听不了 ${path}：${err.message}`)
  }
}
log('在盯 web/ 和 macos/ 的源码；改了网页 → 热更新，改了 Swift → 重装。Ctrl-C 退出')
