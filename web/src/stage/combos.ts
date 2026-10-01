/**
 * 战斗模型（正面 / 背面）的连招：按动画名认出成套的，给桌宠页做按钮。
 * 在网页里算（各平台共用），pet 页面随 `loaded` 一起发给原生层，原生层只管按顺序播。
 *
 *   `P_Begin`（或 `P_Start`）→ `P_Loop`（没有就 `P_Idle`；有 `P_Attack` 就在中间穿插两次）→ `P_End`；
 *   没有开头、但有 `P_Loop` + `P_End` 的也算。另外单独的 `Start`（登场）、`Attack`（没有攻击连招时）各一个按钮。
 */

import { t } from '../i18n/index.ts'

export interface ComboStep {
  name: string
  /** true：循环 seconds 秒；false：播一次（seconds = 动画时长，animDone 没来时兜底） */
  loop: boolean
  seconds: number
}

export interface Combo {
  /** 动画名前缀（`Skill_3`），也是按钮 id */
  id: string
  label: string
  steps: ComboStep[]
}

/** 循环段播多久（秒） */
export const LOOP_SECONDS = 3

export function detectCombos(animations: { name: string; duration: number }[]): Combo[] {
  const dur = new Map(animations.map((a) => [a.name, a.duration]))
  const byLower = new Map(animations.map((a) => [a.name.toLowerCase(), a.name]))
  const find = (p: string, suffix: string) => byLower.get(`${p}_${suffix}`.toLowerCase()) ?? null
  const once = (n: string): ComboStep => ({ name: n, loop: false, seconds: dur.get(n) || 1 })
  const loop = (n: string, s: number): ComboStep => ({ name: n, loop: true, seconds: s })

  const prefixes = new Set<string>()
  for (const { name } of animations) {
    const m = /^(.+)_(begin|start|loop|end)$/i.exec(name)
    if (m) prefixes.add(m[1])
  }
  const out: Combo[] = []
  for (const p of prefixes) {
    const begin = find(p, 'Begin') ?? find(p, 'Start')
    const mid = find(p, 'Loop') ?? find(p, 'Idle')
    const end = find(p, 'End')
    const attack = find(p, 'Attack')
    // 至少要有「开头 + 后续」或「循环 + 结尾」：单个 Xxx_End 之类的不算连招
    if (!((begin && (mid || end)) || (find(p, 'Loop') && end))) continue
    const steps: ComboStep[] = []
    if (begin) steps.push(once(begin))
    if (mid) steps.push(...(attack ? [loop(mid, 1), once(attack), once(attack), loop(mid, 1)] : [loop(mid, LOOP_SECONDS)]))
    if (end) steps.push(once(end))
    out.push({ id: p, label: comboLabel(p), steps })
  }
  const start = byLower.get('start')
  if (start) out.push({ id: start, label: comboLabel(start), steps: [once(start)] })
  const single = byLower.get('attack')
  if (single && !out.some((c) => c.id.toLowerCase() === 'attack')) out.push({ id: single, label: comboLabel(single), steps: [once(single)] })
  const rank = (id: string) => {
    const l = id.toLowerCase()
    return l === 'start' ? 0 : l.startsWith('attack') ? 1 : l.startsWith('skill') ? 2 : 3
  }
  return out.sort((a, b) => rank(a.id) - rank(b.id) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
}

/** 点一下战斗形态的桌宠播哪个：攻击连招，没有就单个攻击动画 */
export function attackCombo(combos: Combo[]): Combo | null {
  return combos.find((c) => c.id.toLowerCase() === 'attack') ?? null
}

/** `Skill_3` → 技能 3，`Skill_Down_2` → 技能 2 · Down，`Attack` → 攻击（按当前界面语言） */
export function comboLabel(prefix: string): string {
  const words: string[] = []
  let number: string | null = null
  const names = t().combo as Record<string, string>
  prefix.split('_').forEach((w, i) => {
    if (/^\d+$/.test(w)) number = String(Number(w))
    else if (i === 0) words.push(names[w.toLowerCase()] ?? w)
    else words.push(w)
  })
  if (words.length === 0) return prefix
  const head = number ? `${words[0]} ${number}` : words[0]
  return [head, ...words.slice(1)].join(' · ')
}
