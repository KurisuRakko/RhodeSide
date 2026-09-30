/**
 * 桌宠页的「选模型」整页：左边列表（已下载的在上、没下载的在线模型在下），右边预览 + 时装 / 形态。
 * 版式和模型库一样；已下载的模型能预览每一套时装和形态，没下载的只能预览默认时装的基建模型。
 */
import { useEffect, useMemo, useState } from 'react'
import { Button, Field } from '@rakko/react'

import * as I from '../ui/icons.tsx'
import { mb, ModelPreview, type PreviewSource } from '../library/Library.tsx'
import { send, type CatalogModel, type ModelInfo, type NativeState, type PetConfig, type PetSummary } from './bridge.ts'
import { groupLabel, useSkinNames } from './skins.ts'
import { Choice, Pick, Row } from './ui.tsx'
import { modelSets } from './validate.ts'

type Focus = { kind: 'local'; name: string } | { kind: 'online'; id: string }
type OutfitSet = { outfit: string; group: string }

const ONLINE_STATE: Record<CatalogModel['state'], string> = {
  installed: '已下载',
  outdated: '已下载',
  available: '',
  queued: '等待下载',
  downloading: '下载中…',
  failed: '下载失败',
}

/** 没指定形态时桌宠页优先挑基建，没有就正面：这里按同样的规则 */
export function defaultGroup(groups: string[]): string | null {
  return groups.includes('基建') ? '基建' : groups.includes('正面') ? '正面' : (groups[0] ?? null)
}

export function ModelPicker({
  index,
  pet,
  summary,
  state,
  onClose,
}: {
  index: number
  pet: PetConfig
  summary?: PetSummary
  state: NativeState
  onClose: () => void
}) {
  const signedIn = state.auth.phase === 'signedIn'
  const [query, setQuery] = useState('')
  const q = query.trim().toLowerCase()
  const match = (name: string) => !q || name.toLowerCase().includes(q)

  const local = state.models.filter((m) => match(m.name))
  const online = state.catalog.filter((c) => !state.models.some((m) => m.name === c.name) && match(c.name))

  const [focus, setFocus] = useState<Focus | null>(() => {
    if (state.models.some((m) => m.name === pet.model)) return { kind: 'local', name: pet.model }
    const c = state.catalog.find((x) => x.name === pet.model)
    if (c) return { kind: 'online', id: c.id }
    return state.models[0] ? { kind: 'local', name: state.models[0].name } : null
  })
  // 在线模型下载完会变成本地模型：焦点跟着换过去
  const focusOnline = focus?.kind === 'online' ? state.catalog.find((c) => c.id === focus.id) : undefined
  const focusModel: ModelInfo | undefined =
    focus?.kind === 'local' ? state.models.find((m) => m.name === focus.name) : focusOnline && state.models.find((m) => m.name === focusOnline.name)

  // 本地模型：有哪些时装 / 形态
  // 每次原生层推状态 models 都是新对象：按名字 + 文件列表判断是不是换了模型
  const modelKey = focusModel ? `${focusModel.name}\u0000${focusModel.files.join('\u0000')}` : null
  const [sets, setSets] = useState<OutfitSet[] | null>(null)
  useEffect(() => {
    setSets(null)
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
  const skin = useSkinNames(focusModel)

  // 选中的时装 / 形态（null = 还没挑，按模型默认）；换模型时清掉，焦点在桌宠当前模型时用它现在的配置
  const [picked, setPicked] = useState<{ outfit: string | null; group: string | null }>({ outfit: null, group: null })
  const isCurrent = focusModel?.name === pet.model
  const loaded = summary?.loaded && summary.loaded.model === pet.model ? summary.loaded : null
  const outfits = useMemo(() => [...new Set((sets ?? []).map((s) => s.outfit))], [sets])
  const nowOutfit: string | null = isCurrent ? (pet.outfit ?? loaded?.outfit ?? null) : null
  const nowGroup: string | null = isCurrent ? (pet.group ?? loaded?.group ?? null) : null
  const wantOutfit = picked.outfit ?? nowOutfit
  // 配置里的时装这个模型没有（手改过、模型换了版本）：退回第一套
  const outfit = wantOutfit !== null && (sets === null || outfits.includes(wantOutfit)) ? wantOutfit : (outfits[0] ?? null)
  const groups = (sets ?? []).filter((s) => s.outfit === outfit).map((s) => s.group)
  const wantGroup = picked.group ?? nowGroup
  const group = wantGroup !== null && groups.includes(wantGroup) ? wantGroup : defaultGroup(groups)

  const choose = (f: Focus) => {
    setFocus(f)
    setPicked({ outfit: null, group: null })
  }

  const source: PreviewSource | null = focusModel
    ? sets === null
      ? null
      : { kind: 'local', name: focusModel.name, files: focusModel.files, outfit, group, pma: pet.pma }
    : focusOnline
      ? { kind: 'online', id: focusOnline.id, name: focusOnline.name, preview: focusOnline.preview }
      : null

  const use = () => {
    if (focusModel) {
      const changed = !isCurrent || outfit !== nowOutfit || group !== nowGroup
      if (changed) send({ type: 'updatePet', id: pet.id, patch: { model: focusModel.name, outfit, group, pose: null } })
    } else if (focusOnline) {
      if (focusOnline.state === 'available' || focusOnline.state === 'failed') send({ type: 'downloadModels', ids: [focusOnline.id] })
      send({ type: 'updatePet', id: pet.id, patch: { model: focusOnline.name, outfit: null, group: null, pose: null } })
    }
    onClose()
  }

  const localMeta = (m: ModelInfo) =>
    [m.name === pet.model ? '在用' : null, m.builtin ? '内置' : state.catalog.some((c) => c.name === m.name) ? null : '导入'].filter(Boolean).join(' · ')

  return (
    <div className="rs-page rs-page--fill rs-picker">
      <header className="rs-page__head rs-picker__head">
        <Button variant="ghost" onClick={onClose}>
          <I.IconBack /> 返回
        </Button>
        <h1 className="rs-title">给桌宠 {index + 1} 选模型</h1>
      </header>

      <div className="rl-lib">
        <div className="rl-side">
          <Field.Root className="rl-search">
            <Field.Control placeholder="搜索模型" value={query} onChange={(e) => setQuery((e.target as HTMLInputElement).value)} />
          </Field.Root>
          <ul className="rl-list" role="listbox" aria-label="模型">
            <li className="rl-heading" role="presentation">
              已下载
            </li>
            {local.map((m) => {
              const on = focus?.kind === 'local' && focus.name === m.name
              return (
                <li key={m.name} className="rl-row" role="option" aria-selected={on} data-current={on || undefined} onClick={() => choose({ kind: 'local', name: m.name })}>
                  <span className="rl-row__name">{m.name}</span>
                  <span className="rl-row__meta">{localMeta(m)}</span>
                </li>
              )
            })}
            {local.length === 0 && <li className="rs-empty rl-none">{q ? `没有匹配「${query}」的模型` : '还没有下载模型'}</li>}

            <li className="rl-heading" role="presentation">
              在线模型
            </li>
            {signedIn ? (
              <>
                {online.map((c) => {
                  const on = focus?.kind === 'online' && focus.id === c.id
                  return (
                    <li key={c.id} className="rl-row" role="option" aria-selected={on} data-current={on || undefined} onClick={() => choose({ kind: 'online', id: c.id })}>
                      <span className="rl-row__name">{c.name}</span>
                      <span className="rl-row__meta" data-error={c.state === 'failed' || undefined}>
                        {ONLINE_STATE[c.state] || mb(c.size)}
                      </span>
                    </li>
                  )
                })}
                {online.length === 0 && (
                  <li className="rs-empty rl-none">{state.catalog.length === 0 ? (state.updates.error ? `暂时拿不到列表：${state.updates.error}` : '正在获取列表…') : q ? '没有匹配的在线模型' : '全部都下载了'}</li>
                )}
              </>
            ) : (
              <li className="rl-login" role="presentation">
                <span className="rs-hint">登录后可以浏览在线模型</span>
                <Button onClick={() => send({ type: 'authLogin' })}>{state.auth.phase === 'signingIn' ? '重新打开登录页' : '登录'}</Button>
              </li>
            )}
          </ul>
        </div>

        <div className="rs-picker__right">
          <ModelPreview
            source={source}
            caption={focusModel?.name ?? focusOnline?.name}
            note={focusModel && group && group !== '基建' ? '战斗形态不会走动；桌面上点它会播攻击' : undefined}
          />
          <div className="rs-group__body">
            {focusModel ? (
              <>
                {sets !== null && sets.length === 0 && <Row label="读不到这个模型的文件" error hint="检查模型文件夹，或到模型库删掉重新下载" />}
                <Row label="时装">
                  <Pick
                    label="时装"
                    value={outfit}
                    options={outfits.map((o) => [o, skin(o)])}
                    onChange={(v) => setPicked({ outfit: v, group: picked.group ?? group })}
                  />
                </Row>
                <Row label="形态">
                  {groups.length > 0 ? (
                    <Choice aria="形态" value={group} options={groups.map((g) => [g, groupLabel(g)])} onChange={(v) => setPicked({ outfit, group: v })} />
                  ) : (
                    <span className="rs-line__value">{sets === null ? '…' : '—'}</span>
                  )}
                </Row>
              </>
            ) : focusOnline ? (
              <Row
                label={focusOnline.state === 'failed' ? '下载失败' : '还没下载'}
                error={focusOnline.state === 'failed'}
                hint={
                  focusOnline.state === 'failed' && focusOnline.error
                    ? focusOnline.error
                    : `${focusOnline.skins > 0 ? `共 ${focusOnline.skins} 套时装，` : ''}下载后可以选时装和形态 · ${mb(focusOnline.size)}`
                }
              />
            ) : (
              <Row label="在左边选一个模型" />
            )}
          </div>
        </div>
      </div>

      <footer className="rl-footer">
        <Button variant="ghost" onClick={onClose}>
          取消
        </Button>
        <Button variant="primary" disabled={focusModel ? !sets || sets.length === 0 : !focusOnline} onClick={use}>
          {focusModel ? '使用' : '下载并使用'}
        </Button>
      </footer>
    </div>
  )
}
