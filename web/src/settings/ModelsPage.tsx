/**
 * 「模型库」页：在线模型（左边勾选、右边预览、下载所选）和我的模型（已下载 / 导入的，可删）。
 * 拖进窗口的文件夹一律当导入，自动切到这一页。
 */
import { useEffect, useState, type Dispatch, type SetStateAction } from 'react'
import { Button, Field, IconButton, SegmentedChoice } from '@rakko/react'

import { modelName, nameMatches, t } from '../i18n/index.ts'
import * as I from '../ui/icons.tsx'
import { Library, mb, pickable } from '../library/Library.tsx'
import { send, type ModelInfo, type NativeState } from './bridge.ts'
import { useConfirm } from './ui.tsx'
import { modelSets } from './validate.ts'

export type ImportStatus = { token: string; name: string; state: 'checking' | 'failed'; reason?: string }

export function ModelsPage({
  state,
  imports,
  setImports,
}: {
  state: NativeState
  imports: ImportStatus[]
  setImports: Dispatch<SetStateAction<ImportStatus[]>>
}) {
  const signedIn = state.auth.phase === 'signedIn'
  const [view, setView] = useState<'online' | 'mine'>(signedIn ? 'online' : 'mine')
  const [selected, setSelected] = useState<Set<string>>(new Set())
  // 有导入在进行：切到「我的模型」看结果
  useEffect(() => {
    if (imports.length > 0) setView('mine')
  }, [imports.length])

  const chosen = state.catalog.filter((m) => selected.has(m.id) && pickable(m))
  const size = chosen.reduce((n, m) => n + m.size, 0)
  const s = t().models
  const c = t().common

  return (
    <div className={view === 'online' ? 'rs-page rs-page--fill' : 'rs-page'}>
      <header className="rs-page__head">
        <h1 className="rs-title">{s.title}</h1>
        <div className="rs-row">
          <SegmentedChoice.Root aria-label={s.sourceAria} value={view} onValueChange={(v) => v && setView(v as 'online' | 'mine')}>
            <SegmentedChoice.Item value="online">{s.online}</SegmentedChoice.Item>
            <SegmentedChoice.Item value="mine">{s.mine}</SegmentedChoice.Item>
          </SegmentedChoice.Root>
        </div>
      </header>

      {view === 'online' ? (
        <>
          <Library state={state} selected={selected} onSelected={setSelected} />
          <footer className="rl-footer">
            {signedIn ? (
              <>
                <span className="rl-footer__hint">{chosen.length > 0 ? c.selected(chosen.length, mb(size)) : s.clickToPreview}</span>
                <Button
                  disabled={chosen.length === 0}
                  onClick={() => {
                    send({ type: 'downloadModels', ids: chosen.map((m) => m.id) })
                    setSelected(new Set())
                  }}
                >
                  {s.downloadSelected(chosen.length)}
                </Button>
              </>
            ) : (
              <Button onClick={() => send({ type: 'authLogin' })}>{state.auth.phase === 'signingIn' ? c.reopenLogin : c.login}</Button>
            )}
          </footer>
        </>
      ) : (
        <MyModels state={state} imports={imports} setImports={setImports} />
      )}
    </div>
  )
}

function MyModels({ state, imports, setImports }: { state: NativeState; imports: ImportStatus[]; setImports: Dispatch<SetStateAction<ImportStatus[]>> }) {
  const [query, setQuery] = useState('')
  const q = query.trim().toLowerCase()
  const list = state.models.filter((m) => nameMatches(m.name, q))
  const s = t().models
  return (
    <>
      <div className="rs-row">
        {state.models.length > 6 && (
          <Field.Root className="rs-grow">
            <Field.Control placeholder={s.search} value={query} onChange={(e) => setQuery((e.target as HTMLInputElement).value)} />
          </Field.Root>
        )}
        <Button onClick={() => send({ type: 'importPick' })}>
          <I.IconFolder /> {s.import}
        </Button>
      </div>
      {imports.map((j) => (
        <div key={j.token} className="rs-item" data-state={j.state}>
          <span className="rs-item__name">{j.name}</span>
          <span className="rs-item__meta">{j.state === 'checking' ? s.checking : s.cannotImport(j.reason ?? '')}</span>
          {j.state === 'failed' && (
            <IconButton aria-label={t().common.remove} onClick={() => setImports((l) => l.filter((x) => x.token !== j.token))}>
              ✕
            </IconButton>
          )}
        </div>
      ))}
      {list.map((m) => (
        <ModelRow
          key={m.name}
          model={m}
          online={state.catalog.some((c) => c.name === m.name && (c.state === 'installed' || c.state === 'outdated'))}
          usedBy={state.config.pets.filter((p) => p.model === m.name).length}
        />
      ))}
      {state.models.length === 0 && <p className="rs-empty">{s.empty}</p>}
      <p className="rs-hint">{s.importHint}</p>
    </>
  )
}

function ModelRow({ model, online, usedBy }: { model: ModelInfo; online: boolean; usedBy: number }) {
  const [sets, setSets] = useState<number | null>(null)
  const [armed, confirm] = useConfirm()
  useEffect(() => {
    let alive = true
    modelSets(model.name, model.files).then(
      (s) => alive && setSets(new Set(s.map((x) => x.outfit)).size),
      () => alive && setSets(0),
    )
    return () => {
      alive = false
    }
  }, [model])

  const s = t().models
  const c = t().common
  return (
    <div className="rs-item">
      <span className="rs-item__name">{modelName(model.name)}</span>
      <span className="rs-item__meta">
        {model.builtin ? c.builtin : online ? s.fromOnline : s.fromImport} · {sets === null ? '…' : c.outfitCount(sets)}
        {usedBy > 0 && ` · ${s.usedBy(usedBy)}`}
      </span>
      {!model.builtin && (
        <Button onClick={() => confirm() && send({ type: 'deleteModel', name: model.name })}>
          <I.IconTrash /> {armed ? c.confirmDelete : c.delete}
        </Button>
      )}
    </div>
  )
}
