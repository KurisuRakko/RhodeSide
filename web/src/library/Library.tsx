/**
 * 模型库：左边在线模型列表（搜索 + 勾选），右边预览选中的那个。
 * 预览只下载它默认时装的基建模型，只循环播待机一个动作（原生层 previewModel → preview 消息）。
 * 主窗口的「模型库」页和引导页第 2 步共用这个组件，底部按钮由外面给。
 * 预览 ModelPreview 也给桌宠页的选模型界面用（那里还能预览已下载模型的各套时装 / 形态）。
 */
import { useEffect, useMemo, useRef, useState } from 'react'
import { Checkbox, Field } from '@rakko/react'

import { modelName, nameMatches, t } from '../i18n/index.ts'
import { onMessage, send, type CatalogModel, type NativeState } from '../settings/bridge.ts'
import { collectSets, fetchSetImages, fetchSkeletons, type ModelSet } from '../stage/loader.ts'
import { Stage } from '../stage/engine.ts'
import './library.css'

export const mb = (bytes: number) => `${(bytes / 1048576).toFixed(1)} MB`

/** 可以勾选下载的（没装、没在下） */
export const pickable = (m: CatalogModel) => m.state === 'available' || m.state === 'failed'

export function Library({
  state,
  selected,
  onSelected,
}: {
  state: NativeState
  selected: Set<string>
  onSelected: (s: Set<string>) => void
}) {
  const [query, setQuery] = useState('')
  const [focus, setFocus] = useState<string | null>(null)
  const list = useMemo(() => {
    const q = query.trim().toLowerCase()
    return q ? state.catalog.filter((m) => nameMatches(m.name, q)) : state.catalog
  }, [state.catalog, query])
  const current = state.catalog.find((m) => m.id === focus) ?? list[0] ?? null

  const toggle = (id: string, on: boolean) => {
    const next = new Set(selected)
    if (on) next.add(id)
    else next.delete(id)
    onSelected(next)
  }

  const s = t().library
  if (state.auth.phase !== 'signedIn') {
    return <p className="rs-empty rl-empty">{s.loginRequired}</p>
  }
  if (state.catalog.length === 0) {
    return (
      <p className="rs-empty rl-empty" data-error={state.updates.error ? true : undefined}>
        {state.updates.error ? s.catalogError(state.updates.error) : s.fetching}
      </p>
    )
  }

  return (
    <div className="rl-lib">
      <div className="rl-side">
        <Field.Root className="rl-search">
          <Field.Control placeholder={s.search(state.catalog.length)} value={query} onChange={(e) => setQuery((e.target as HTMLInputElement).value)} />
        </Field.Root>
        <ul className="rl-list" role="listbox" aria-label={s.listAria}>
          {list.map((m) => (
            <li
              key={m.id}
              className="rl-row"
              role="option"
              aria-selected={current?.id === m.id}
              data-current={current?.id === m.id || undefined}
              onClick={() => setFocus(m.id)}
            >
              <span className="rl-row__check" onClick={(e) => e.stopPropagation()}>
                <Checkbox.Root
                  aria-label={s.downloadAria(modelName(m.name))}
                  checked={!pickable(m) || selected.has(m.id)}
                  disabled={!pickable(m)}
                  onCheckedChange={(v) => toggle(m.id, v === true)}
                >
                  <Checkbox.Indicator />
                </Checkbox.Root>
              </span>
              <span className="rl-row__name">{modelName(m.name)}</span>
              <span className="rl-row__meta" data-error={m.state === 'failed' || undefined}>
                {s.state[m.state] || `${m.skins > 0 ? `${t().common.outfitCount(m.skins)} · ` : ''}${mb(m.size)}`}
              </span>
            </li>
          ))}
          {list.length === 0 && <li className="rs-empty rl-none">{s.noMatch(query)}</li>}
        </ul>
      </div>
      <ModelPreview source={current && { kind: 'online', id: current.id, name: current.name, preview: current.preview }} />
    </div>
  )
}

/* ------------------------------------------------------------------ 预览 */

/**
 * 预览来源：
 *   - online：没下载的在线模型，原生层只给默认时装的基建模型（previewModel → preview 消息）
 *   - local：已下载 / 导入的模型，直接从 ./models/ 载入指定的时装 + 形态
 */
export type PreviewSource =
  | { kind: 'online'; id: string; name: string; preview: boolean }
  | { kind: 'local'; name: string; files: string[]; outfit: string | null; group: string | null; pma: boolean }

/** 本地模型的骨骼 + 图集只留最近一个（切时装 / 形态时不用重下） */
let localCache: { key: string; sets: Promise<ModelSet[]> } | null = null
function localSets(name: string, files: string[]) {
  const key = `${name}\u0000${files.join('\u0000')}`
  if (localCache?.key !== key) {
    const sets = fetchSkeletons('./models/', files).then(collectSets)
    sets.catch(() => {
      if (localCache?.sets === sets) localCache = null
    })
    localCache = { key, sets }
  }
  return localCache.sets
}

/** caption 覆盖标题栏左边的名字；note 是没有载入状态时标题栏右边的小字 */
export function ModelPreview({ source, caption, note }: { source: PreviewSource | null; caption?: string; note?: string }) {
  const canvas = useRef<HTMLCanvasElement>(null)
  const stage = useRef<Stage | null>(null)
  // 存成函数：切了界面语言，下次渲染就是新语言
  const [status, setStatus] = useState<(() => string) | null>(null)
  const [error, setError] = useState(false)

  useEffect(() => {
    if (!canvas.current) return
    try {
      const s = new Stage(canvas.current)
      s.setMode('view')
      stage.current = s
    } catch (err) {
      setStatus(() => () => (err instanceof Error ? err.message : String(err)))
      setError(true)
    }
    return () => {
      stage.current?.dispose()
      stage.current = null
    }
  }, [])

  // 按内容比较：父组件每次渲染都会给一个新对象
  const key = source ? JSON.stringify(source) : null
  useEffect(() => {
    const s = stage.current
    if (!s) return
    if (!key) {
      s.setModel(null)
      setStatus(null)
      return
    }
    const src = JSON.parse(key) as PreviewSource
    s.setModel(null)
    let alive = true
    const fail = (err: unknown) => {
      if (!alive) return
      setStatus(() => () => t().library.previewFailed(err instanceof Error ? err.message : String(err)))
      setError(true)
    }
    const show = async (base: string, pick: (sets: ModelSet[]) => ModelSet, sets: ModelSet[], pma: boolean) => {
      const loaded = await s.load(await fetchSetImages(base, pick(sets)), pma)
      if (!alive) {
        for (const t of loaded.textures) t.dispose()
        return
      }
      // 只循环待机：view 模式载入时默认就播 roles.idle
      s.setModel(loaded)
      setStatus(null)
    }
    setError(false)

    if (src.kind === 'local') {
      setStatus(() => () => t().library.loadingPreview)
      const pick = (sets: ModelSet[]) =>
        sets.find((x) => x.outfit === src.outfit && x.group === src.group) ??
        sets.find((x) => x.outfit === src.outfit && x.group === '基建') ??
        sets.find((x) => x.outfit === src.outfit) ??
        sets.find((x) => x.group === '基建') ??
        sets[0]
      localSets(src.name, src.files).then((sets) => show('./models/', pick, sets, src.pma)).catch(fail)
      return () => {
        alive = false
      }
    }

    if (!src.preview) {
      setStatus(() => () => t().library.noPreview)
      return
    }
    setStatus(() => () => t().library.loadingPreview)
    const off = onMessage((m) => {
      if (m.type !== 'preview' || m.id !== src.id) return
      off()
      if (!alive) return
      if (m.error || !m.base || !m.files) {
        fail(m.error ?? t().library.noFiles)
        return
      }
      const base = m.base
      fetchSkeletons(base, m.files)
        .then(collectSets)
        .then((sets) => show(base, (all) => all.find((x) => x.group === '基建') ?? all[0], sets, false))
        .catch(fail)
    })
    send({ type: 'previewModel', id: src.id })
    return () => {
      alive = false
      off()
    }
  }, [key])

  const name = source ? modelName(source.name) : ''
  const statusText = status?.() ?? null
  return (
    <div className="rl-preview">
      <canvas ref={canvas} className="rl-canvas" aria-label={source ? t().library.previewOf(name) : t().library.preview} />
      <div className="rl-caption">
        <span className="rl-caption__name">{caption ?? name}</span>
        {(statusText ?? note) && (
          <span className="rl-caption__status" data-error={(statusText && error) || undefined}>
            {statusText ?? note}
          </span>
        )}
      </div>
    </div>
  )
}
