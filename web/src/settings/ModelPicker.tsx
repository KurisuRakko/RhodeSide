/**
 * 桌宠页的「选模型」整页：左边列表（已下载的在上、没下载的在线模型在下），右边预览 + 时装 / 形态。
 * 版式和模型库一样；已下载的模型能预览每一套时装和形态，没下载的只能预览默认时装的基建模型。
 */
import { useEffect, useMemo, useState } from 'react'
import { Button, Field } from '@rakko/react'

import { modelName, nameMatches, t } from '../i18n/index.ts'
import * as I from '../ui/icons.tsx'
import { mb, ModelPreview, type PreviewSource } from '../library/Library.tsx'
import { send, type ModelInfo, type NativeState, type PetConfig, type PetSummary } from './bridge.ts'
import { groupLabel, useSkinNames } from './skins.ts'
import { Choice, Pick, Row } from './ui.tsx'
import { modelSets } from './validate.ts'

type Focus = { kind: 'local'; name: string } | { kind: 'online'; id: string }
type OutfitSet = { outfit: string; group: string }

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
  const match = (name: string) => nameMatches(name, q)

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

  const s = t().picker
  const c = t().common
  const localMeta = (m: ModelInfo) =>
    [m.name === pet.model ? s.inUse : null, m.builtin ? c.builtin : state.catalog.some((x) => x.name === m.name) ? null : s.imported].filter(Boolean).join(' · ')

  return (
    <div className="rs-page rs-page--fill rs-picker">
      <header className="rs-page__head rs-picker__head">
        <Button variant="ghost" onClick={onClose}>
          <I.IconBack /> {c.back}
        </Button>
        <h1 className="rs-title">{s.title(index + 1)}</h1>
      </header>

      <div className="rl-lib">
        <div className="rl-side">
          <Field.Root className="rl-search">
            <Field.Control placeholder={s.search} value={query} onChange={(e) => setQuery((e.target as HTMLInputElement).value)} />
          </Field.Root>
          <ul className="rl-list" role="listbox" aria-label={s.listAria}>
            <li className="rl-heading" role="presentation">
              {s.downloaded}
            </li>
            {local.map((m) => {
              const on = focus?.kind === 'local' && focus.name === m.name
              return (
                <li key={m.name} className="rl-row" role="option" aria-selected={on} data-current={on || undefined} onClick={() => choose({ kind: 'local', name: m.name })}>
                  <span className="rl-row__name">{modelName(m.name)}</span>
                  <span className="rl-row__meta">{localMeta(m)}</span>
                </li>
              )
            })}
            {local.length === 0 && <li className="rs-empty rl-none">{q ? s.noMatch(query) : s.noneDownloaded}</li>}

            <li className="rl-heading" role="presentation">
              {s.online}
            </li>
            {signedIn ? (
              <>
                {online.map((m) => {
                  const on = focus?.kind === 'online' && focus.id === m.id
                  return (
                    <li key={m.id} className="rl-row" role="option" aria-selected={on} data-current={on || undefined} onClick={() => choose({ kind: 'online', id: m.id })}>
                      <span className="rl-row__name">{modelName(m.name)}</span>
                      <span className="rl-row__meta" data-error={m.state === 'failed' || undefined}>
                        {s.state[m.state] || mb(m.size)}
                      </span>
                    </li>
                  )
                })}
                {online.length === 0 && (
                  <li className="rs-empty rl-none">{state.catalog.length === 0 ? (state.updates.error ? s.listError(state.updates.error) : s.fetching) : q ? s.noOnlineMatch : s.allDownloaded}</li>
                )}
              </>
            ) : (
              <li className="rl-login" role="presentation">
                <span className="rs-hint">{s.loginToBrowse}</span>
                <Button onClick={() => send({ type: 'authLogin' })}>{state.auth.phase === 'signingIn' ? c.reopenLogin : c.login}</Button>
              </li>
            )}
          </ul>
        </div>

        <div className="rs-picker__right">
          <ModelPreview
            source={source}
            caption={focusModel ? modelName(focusModel.name) : undefined}
            note={focusModel && group && group !== '基建' ? s.battleNote : undefined}
          />
          <div className="rs-group__body">
            {focusModel ? (
              <>
                {sets !== null && sets.length === 0 && <Row label={s.unreadable} error hint={s.unreadableHint} />}
                <Row label={s.outfit}>
                  <Pick
                    label={s.outfit}
                    value={outfit}
                    options={outfits.map((o) => [o, skin(o)])}
                    onChange={(v) => setPicked({ outfit: v, group: picked.group ?? group })}
                  />
                </Row>
                <Row label={s.form}>
                  {groups.length > 0 ? (
                    <Choice aria={s.form} value={group} options={groups.map((g) => [g, groupLabel(g)])} onChange={(v) => setPicked({ outfit, group: v })} />
                  ) : (
                    <span className="rs-line__value">{sets === null ? '…' : '—'}</span>
                  )}
                </Row>
              </>
            ) : focusOnline ? (
              <Row
                label={focusOnline.state === 'failed' ? s.downloadFailed : s.notDownloaded}
                error={focusOnline.state === 'failed'}
                hint={
                  focusOnline.state === 'failed' && focusOnline.error
                    ? focusOnline.error
                    : s.onlineHint(focusOnline.skins, mb(focusOnline.size))
                }
              />
            ) : (
              <Row label={s.pickLeft} />
            )}
          </div>
        </div>
      </div>

      <footer className="rl-footer">
        <Button variant="ghost" onClick={onClose}>
          {c.cancel}
        </Button>
        <Button variant="primary" disabled={focusModel ? !sets || sets.length === 0 : !focusOnline} onClick={use}>
          {focusModel ? s.use : s.downloadAndUse}
        </Button>
      </footer>
    </div>
  )
}
