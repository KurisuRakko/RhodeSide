/**
 * 「模型库」页：在线模型（左边勾选、右边预览、下载所选）和我的模型（已下载 / 导入的，可删）。
 * 拖进窗口的文件夹一律当导入，自动切到这一页。
 */
import { useEffect, useState, type Dispatch, type SetStateAction } from 'react'
import { Button, Field, IconButton, SegmentedChoice } from '@rakko/react'

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

  return (
    <div className={view === 'online' ? 'rs-page rs-page--fill' : 'rs-page'}>
      <header className="rs-page__head">
        <h1 className="rs-title">模型库</h1>
        <div className="rs-row">
          <SegmentedChoice.Root aria-label="模型来源" value={view} onValueChange={(v) => v && setView(v as 'online' | 'mine')}>
            <SegmentedChoice.Item value="online">在线模型</SegmentedChoice.Item>
            <SegmentedChoice.Item value="mine">我的模型</SegmentedChoice.Item>
          </SegmentedChoice.Root>
        </div>
      </header>

      {view === 'online' ? (
        <>
          <Library state={state} selected={selected} onSelected={setSelected} />
          <footer className="rl-footer">
            {signedIn ? (
              <>
                <span className="rl-footer__hint">{chosen.length > 0 ? `已选 ${chosen.length} 个 · 共 ${mb(size)}` : '点击查看预览，勾选后下载'}</span>
                <Button
                  disabled={chosen.length === 0}
                  onClick={() => {
                    send({ type: 'downloadModels', ids: chosen.map((m) => m.id) })
                    setSelected(new Set())
                  }}
                >
                  下载所选{chosen.length > 0 ? `（${chosen.length}）` : ''}
                </Button>
              </>
            ) : (
              <Button onClick={() => send({ type: 'authLogin' })}>{state.auth.phase === 'signingIn' ? '重新打开登录页' : '登录'}</Button>
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
  const list = state.models.filter((m) => !q || m.name.toLowerCase().includes(q))
  return (
    <>
      <div className="rs-row">
        {state.models.length > 6 && (
          <Field.Root className="rs-grow">
            <Field.Control placeholder="搜索" value={query} onChange={(e) => setQuery((e.target as HTMLInputElement).value)} />
          </Field.Root>
        )}
        <Button onClick={() => send({ type: 'importPick' })}>
          <I.IconFolder /> 导入…
        </Button>
      </div>
      {imports.map((j) => (
        <div key={j.token} className="rs-item" data-state={j.state}>
          <span className="rs-item__name">{j.name}</span>
          <span className="rs-item__meta">{j.state === 'checking' ? '正在检查…' : `无法导入：${j.reason}`}</span>
          {j.state === 'failed' && (
            <IconButton aria-label="移除" onClick={() => setImports((l) => l.filter((x) => x.token !== j.token))}>
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
      {state.models.length === 0 && <p className="rs-empty">还没有模型：从「在线模型」下载，或者导入自己的。</p>}
      <p className="rs-hint">
        导入：把模型文件夹拖进这个窗口，或点「导入…」。支持 Spine 3.8：骨骼（.skel / .json）+ 同名图集（.atlas）+ 贴图，一个文件夹是一个模型。
      </p>
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

  return (
    <div className="rs-item">
      <span className="rs-item__name">{model.name}</span>
      <span className="rs-item__meta">
        {model.builtin ? '内置' : online ? '在线下载' : '自己导入'} · {sets === null ? '…' : `${sets} 套时装`}
        {usedBy > 0 && ` · ${usedBy} 只桌宠在用`}
      </span>
      {!model.builtin && (
        <Button onClick={() => confirm() && send({ type: 'deleteModel', name: model.name })}>
          <I.IconTrash /> {armed ? '确认删除' : '删除'}
        </Button>
      )}
    </div>
  )
}
