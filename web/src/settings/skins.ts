/**
 * 显示用的名字：时装 key → PRTS 时装名（模型文件夹里的 skins.json，fetch-prts.mjs 写的；其他语言的译名在在线目录里），
 * 模型组 → 基建 / 战斗 · 正面 / 战斗 · 背面。组名本身（基建 / 正面 / 背面 + 重名时的「 2」）是配置里存的 key，不翻。
 */
import { useEffect, useState } from 'react'

import { outfitName, t } from '../i18n/index.ts'

const cache = new Map<string, Promise<Record<string, string>>>()

function load(name: string, files: string[]): Promise<Record<string, string>> {
  const file = `${name}/skins.json`
  if (!files.includes(file)) return Promise.resolve({})
  const key = `${name}\u0000${files.length}`
  let p = cache.get(key)
  if (!p) {
    p = fetch(`./models/${file.split('/').map(encodeURIComponent).join('/')}`)
      .then((r) => (r.ok ? r.json() : {}))
      .then((d: unknown) => (d && typeof d === 'object' ? (d as Record<string, string>) : {}))
      .catch(() => ({}))
    cache.set(key, p)
  }
  return p
}

/** 时装 key → 显示名；没有 skins.json 的模型原样显示 key */
export function useSkinNames(model: { name: string; files: string[] } | undefined) {
  const [names, setNames] = useState<Record<string, string>>({})
  useEffect(() => {
    if (!model) return
    let alive = true
    void load(model.name, model.files).then((n) => alive && setNames(n))
    return () => {
      alive = false
    }
  }, [model])
  return (outfit: string) => (model ? outfitName(model.name, outfit, names[outfit]) : outfit)
}

export function groupLabel(group: string) {
  const g = t().group
  const m = /^(基建|正面|背面)(.*)$/.exec(group)
  if (!m) return group
  return ({ 基建: g.build, 正面: g.front, 背面: g.back } as Record<string, string>)[m[1]] + m[2]
}
