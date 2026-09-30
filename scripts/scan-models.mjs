#!/usr/bin/env node
// scripts/scan-models.mjs —— 扫 web/public/models/ 下的子目录，生成 index.json 清单。
// 静态服务器列不了目录，所以页面靠这份清单知道有哪些模型。每个一级子目录算一个角色。
import { existsSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(fileURLToPath(new URL('.', import.meta.url)), '..')
const MODELS = join(ROOT, 'web/public/models')
const EXT = /\.(skel(\.bytes)?|json|atlas(\.txt)?|png|webp)$/i

function walk(dir, out = []) {
  for (const name of readdirSync(dir).sort()) {
    const abs = join(dir, name)
    if (statSync(abs).isDirectory()) walk(abs, out)
    else if (EXT.test(name)) out.push(relative(MODELS, abs).split('\\').join('/'))
  }
  return out
}

if (!existsSync(MODELS)) process.exit(0)
const entries = []
for (const name of readdirSync(MODELS).sort()) {
  const abs = join(MODELS, name)
  if (!statSync(abs).isDirectory()) continue
  const files = walk(abs)
  const hasSkel = files.some((f) => /\.(skel(\.bytes)?|json)$/i.test(f))
  const hasAtlas = files.some((f) => /\.atlas(\.txt)?$/i.test(f))
  if (hasSkel && hasAtlas) entries.push({ name, files })
  else console.warn(`[scan-models] 跳过 ${name}/：缺 ${hasSkel ? '.atlas' : '.skel/.json'}`)
}
writeFileSync(join(MODELS, 'index.json'), JSON.stringify(entries, null, 2) + '\n')
console.log(`[scan-models] ${entries.length} 个模型 → web/public/models/index.json`)
