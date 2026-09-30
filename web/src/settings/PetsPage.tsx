/**
 * 「桌宠」页：一只一只地管。上面选哪只，下面分「模型」「显示」「活动」「立即动作」四组（系统设置式：左边名字、右边控件）。
 * 换模型 / 时装 / 形态走整页的选模型界面（ModelPicker），和模型库一样左边列表、右边预览。
 * 战斗形态（正面 / 背面）不走动：「活动」换成循环播的动作下拉框，「立即动作」换成套组动作按钮。
 * 两种形态的「立即动作」里都有「转身」。
 */
import { useEffect, useMemo, useState } from 'react'
import { Button, FilterChip } from '@rakko/react'

import * as I from '../ui/icons.tsx'
import { native, send, type Activity, type Behavior, type CatalogModel, type ModelInfo, type NativeState, type PetConfig, type PetSummary } from './bridge.ts'
import { defaultGroup, ModelPicker } from './ModelPicker.tsx'
import { groupLabel, useSkinNames } from './skins.ts'
import { Choice, Group, nearest, Pick, Row, SwitchRow, useConfirm } from './ui.tsx'
import { modelSets } from './validate.ts'

const HEIGHTS: [string, string][] = [
  ['90', '小'],
  ['120', '中'],
  ['160', '大'],
  ['210', '特大'],
]
const OPACITY: [string, string][] = [
  ['1', '100%'],
  ['0.75', '75%'],
  ['0.5', '50%'],
  ['0.3', '30%'],
]
const STRIDES: [string, string][] = [
  ['0.7', '慢'],
  ['1', '正常'],
  ['1.4', '快'],
]
const ACTIVITIES: [Activity, string][] = [
  ['auto', '自由活动'],
  ['walk', '一直行走'],
  ['stay', '原地停留'],
]
const ACTIONS: [Behavior, string, keyof PetSummary['can'] | null][] = [
  ['interact', '互动', 'interact'],
  ['sit', '坐下', 'sit'],
  ['sleep', '睡眠', 'sleep'],
  ['idle', '站立', null],
]
const BEHAVIOR: Record<string, string> = {
  idle: '站着',
  walk: '在走路',
  sit: '坐着',
  sleep: '在睡觉',
  interact: '在做动作',
  held: '被拎着',
  fall: '在下落',
}
const DOWNLOAD: Partial<Record<CatalogModel['state'], string>> = {
  available: '还没下载',
  queued: '等待下载…',
  downloading: '正在下载…',
  failed: '下载失败',
}

export function PetsPage({ state }: { state: NativeState }) {
  const { config } = state
  const [selected, setSelected] = useState<string | null>(null)
  const [picking, setPicking] = useState(false)
  const pets = config.pets
  const pet = pets.find((p) => p.id === selected) ?? pets[0]
  const index = pet ? pets.indexOf(pet) : -1
  const full = pets.length >= state.maxPets
  const summary = pet ? state.pets.find((s) => s.id === pet.id) : undefined

  // 刚添加的那只自动选中
  const [count, setCount] = useState(pets.length)
  useEffect(() => {
    if (pets.length > count) setSelected(pets[pets.length - 1].id)
    setCount(pets.length)
  }, [pets, count])

  // 正在选模型的那只被移除了：回到列表
  const petId = pet?.id
  useEffect(() => setPicking(false), [petId])

  if (pet && picking) return <ModelPicker key={pet.id} index={index} pet={pet} summary={summary} state={state} onClose={() => setPicking(false)} />

  return (
    <div className="rs-page">
      <header className="rs-page__head">
        <h1 className="rs-title">桌宠</h1>
      </header>

      <div className="rs-pets" role="group" aria-label="选择桌宠">
        {pets.map((p, i) => (
          <FilterChip key={p.id} pressed={p.id === pet?.id} onPressedChange={() => setSelected(p.id)}>
            {i + 1} · {p.model}
          </FilterChip>
        ))}
        <Button variant="ghost" disabled={full} onClick={() => send({ type: 'addPet' })}>
          <I.IconPlus /> 添加
        </Button>
        {full && <span className="rs-hint">最多 {state.maxPets} 只</span>}
      </div>

      {pet ? (
        <PetEditor key={pet.id} pet={pet} summary={summary} models={state.models} catalog={state.catalog} onPick={() => setPicking(true)} />
      ) : (
        <p className="rs-empty">还没有桌宠，点「添加」。</p>
      )}
    </div>
  )
}

function PetEditor({
  pet,
  summary,
  models,
  catalog,
  onPick,
}: {
  pet: PetConfig
  summary?: PetSummary
  models: ModelInfo[]
  catalog: CatalogModel[]
  onPick: () => void
}) {
  const patch = (p: Partial<Record<keyof PetConfig, unknown>>) => send({ type: 'updatePet', id: pet.id, patch: p })
  const model = models.find((m) => m.name === pet.model)
  const skin = useSkinNames(model)
  const [armed, confirm] = useConfirm()
  const [sets, setSets] = useState<{ outfit: string; group: string }[]>(summary?.loaded?.sets ?? [])

  const modelKey = model ? `${model.name}\u0000${model.files.join('\u0000')}` : null
  useEffect(() => {
    if (!modelKey) return
    const [name, ...files] = modelKey.split('\u0000')
    let alive = true
    modelSets(name, files).then(
      (s) => alive && setSets(s),
      () => alive && setSets([]),
    )
    return () => {
      alive = false
    }
  }, [modelKey])

  const loaded = summary?.loaded
  // 刚换了模型、新的还没载入时，loaded 还是旧模型的，不能拿来当默认值
  const current = loaded && loaded.model === pet.model ? loaded : null
  const outfit = pet.outfit ?? current?.outfit ?? sets[0]?.outfit ?? null
  const group = pet.group ?? current?.group ?? defaultGroup(sets.filter((s) => s.outfit === outfit).map((s) => s.group))

  // 模型那一行的小字：没下载好就显示下载状态，否则是时装 · 形态
  const pending = model ? undefined : catalog.find((c) => c.name === pet.model)
  const modelHint = model
    ? [outfit && skin(outfit), group && groupLabel(group)].filter(Boolean).join(' · ')
    : pending
      ? (DOWNLOAD[pending.state] ?? '正在安装…')
      : '找不到这个模型'

  const status = summary?.error
    ? summary.error
    : current
      ? `现在${BEHAVIOR[summary?.behavior ?? ''] ?? summary?.behavior ?? ''}`
      : native
        ? '加载中…'
        : '浏览器预览'

  return (
    <>
      <p className="rs-status" data-error={summary?.error ? true : undefined}>
        {status}
      </p>

      <Group title="模型">
        <Row label={pet.model} hint={modelHint} error={!model && (!pending || pending.state === 'failed')}>
          <Button onClick={onPick}>更换…</Button>
        </Row>
      </Group>

      <Group title="显示">
        <Row label="大小">
          <Choice aria="大小" value={nearest(pet.height, HEIGHTS)} options={HEIGHTS} onChange={(v) => patch({ height: Number(v) })} />
        </Row>
        <Row label="不透明度">
          <Choice aria="不透明度" value={nearest(pet.opacity, OPACITY)} options={OPACITY} onChange={(v) => patch({ opacity: Number(v) })} />
        </Row>
        <SwitchRow label="悬停变淡" hint="鼠标移上去时变淡、点击穿透；按住 ⌥ 可以拖动" checked={pet.hoverFade} onChange={(v) => patch({ hoverFade: v })} />
        <SwitchRow label="预乘透明度（PMA）" hint="边缘有黑边或白边时切换" checked={pet.pma} onChange={(v) => patch({ pma: v })} />
      </Group>

      {summary?.battle ? <BattleControls pet={pet} summary={summary} /> : <BaseControls pet={pet} summary={summary} />}

      <footer className="rs-page__foot">
        <Button onClick={() => send({ type: 'summonPet', id: pet.id })}>召回</Button>
        <Button variant="danger" onClick={() => confirm() && send({ type: 'removePet', id: pet.id })}>
          <I.IconTrash /> {armed ? '确认移除' : '移除'}
        </Button>
      </footer>
    </>
  )
}

/** 基建形态：活动方式 + 步速；即时动作 */
function BaseControls({ pet, summary }: { pet: PetConfig; summary?: PetSummary }) {
  const canWalk = summary?.can.move !== false
  const patch = (p: Partial<Record<keyof PetConfig, unknown>>) => send({ type: 'updatePet', id: pet.id, patch: p })
  return (
    <>
      <Group title="活动">
        <Row label="方式" hint={canWalk ? undefined : '这个模型没有行走动画'}>
          <Choice aria="活动方式" value={pet.activity} options={ACTIVITIES} onChange={(v) => patch({ activity: v as Activity })} />
        </Row>
        <Row label="步速" hint="脚步和移动对不上时调整">
          <Choice aria="步速" value={nearest(pet.stride, STRIDES)} options={STRIDES} onChange={(v) => patch({ stride: Number(v) })} />
        </Row>
      </Group>
      <Group title="立即动作">
        <Row
          label="做一个动作"
          hint={!summary?.standing ? '站稳以后才能做动作' : pet.activity === 'stay' ? '原地停留时，坐下和睡眠会一直保持' : undefined}
        >
          {ACTIONS.map(([b, text, need]) => (
            <Button
              key={b}
              disabled={!summary?.standing || (need !== null && !summary.can[need])}
              onClick={() => send({ type: 'perform', id: pet.id, behavior: b })}
            >
              {text}
            </Button>
          ))}
          <TurnButton pet={pet} summary={summary} />
        </Row>
      </Group>
    </>
  )
}

/** 战斗形态：待机循环的动画（下拉框）+ 套组动作按钮；点一下桌宠会播攻击 */
function BattleControls({ pet, summary }: { pet: PetConfig; summary: PetSummary }) {
  const animations = summary.animations ?? []
  const combos = summary.combos ?? []
  const options = useMemo(() => animations.map((a): [string, string] => [a, a]), [animations])
  return (
    <>
      <Group title="活动">
        <Row label="循环动作" hint="战斗形态不会走动；点一下桌宠会播攻击">
          <Pick label="循环动作" value={summary.pose ?? null} options={options} onChange={(v) => send({ type: 'updatePet', id: pet.id, patch: { pose: v } })} />
        </Row>
      </Group>
      <Group title="立即动作">
        {combos.length > 0 ? (
          <Row label="套组动作" hint={summary.standing ? '按顺序播一遍，播完回到循环动作' : '站稳以后才能做动作'}>
            {combos.map((c) => (
              <Button key={c.id} disabled={!summary.standing} onClick={() => send({ type: 'playCombo', id: pet.id, combo: c.id })}>
                {c.label}
              </Button>
            ))}
            <TurnButton pet={pet} summary={summary} />
          </Row>
        ) : (
          <Row label="转身" hint={summary.standing ? undefined : '站稳以后才能转身'}>
            <TurnButton pet={pet} summary={summary} />
          </Row>
        )}
      </Group>
    </>
  )
}

/** 掉个头；走着路会先停下 */
function TurnButton({ pet, summary }: { pet: PetConfig; summary?: PetSummary }) {
  return (
    <Button disabled={!summary?.standing} onClick={() => send({ type: 'turn', id: pet.id })}>
      转身
    </Button>
  )
}
