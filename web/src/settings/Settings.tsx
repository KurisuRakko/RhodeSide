/**
 * Rhodeside 主窗口：左边侧栏三页——桌宠（每只的外观和行为）/ 模型库（在线 + 我的模型）/ 设置（应用级）。
 * 所有改动立刻发给原生层（它存 config.json 并马上生效），原生层再推回完整状态。
 * 打开哪一页：URL 的 #pets / #models / #settings，或原生层发 navigate。
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import { SideNav, Snackbar, Tabs, useSnackbar } from '@rakko/react'

import * as I from '../ui/icons.tsx'
import { onMessage, send, type NativeState, type StagedImport } from './bridge.ts'
import { ModelsPage, type ImportStatus } from './ModelsPage.tsx'
import { PetsPage } from './PetsPage.tsx'
import { SettingsPage } from './SettingsPage.tsx'
import { validateImport } from './validate.ts'
import './settings.css'

export type Tab = 'pets' | 'models' | 'settings'
const TABS: Tab[] = ['pets', 'models', 'settings']
const tabFromHash = (): Tab => {
  const h = location.hash.slice(1)
  return (TABS as string[]).includes(h) ? (h as Tab) : 'pets'
}

export function SettingsApp() {
  return (
    <Snackbar.Provider>
      <Main />
      <SnackbarHost />
    </Snackbar.Provider>
  )
}

function SnackbarHost() {
  const { toasts } = useSnackbar()
  return (
    <Snackbar.Viewport>
      {toasts.map((toast) => (
        <Snackbar.Root key={toast.id} toast={toast}>
          <Snackbar.Title />
        </Snackbar.Root>
      ))}
    </Snackbar.Viewport>
  )
}

function Main() {
  const toast = useSnackbar()
  const toastRef = useRef(toast)
  toastRef.current = toast
  const say = useCallback((title: string) => toastRef.current.add({ title }), [])

  const [state, setState] = useState<NativeState | null>(null)
  const [imports, setImports] = useState<ImportStatus[]>([])
  const [dropHover, setDropHover] = useState(false)
  const [tab, setTab] = useState<Tab>(tabFromHash)

  const runImport = useCallback(async (job: StagedImport) => {
    setTab('models')
    setImports((list) => [...list.filter((j) => j.token !== job.token), { token: job.token, name: job.name, state: 'checking' }])
    const verdict = await validateImport(job.base, job.files)
    if (verdict.ok) {
      setImports((list) => list.filter((j) => j.token !== job.token))
      send({ type: 'importResult', token: job.token, ok: true })
    } else {
      setImports((list) => list.map((j) => (j.token === job.token ? { ...j, state: 'failed', reason: verdict.reason } : j)))
      send({ type: 'importResult', token: job.token, ok: false, reason: verdict.reason })
    }
  }, [])

  useEffect(() => {
    const off = onMessage((m) => {
      switch (m.type) {
        case 'state': {
          const { type: _t, ...rest } = m
          setState(rest)
          break
        }
        case 'toast':
          say(m.text)
          break
        case 'importStaged':
          void runImport(m)
          break
        case 'dropHover':
          setDropHover(m.on)
          break
        case 'navigate':
          if ((TABS as string[]).includes(m.tab)) setTab(m.tab as Tab)
          break
      }
    })
    const onHash = () => setTab(tabFromHash())
    window.addEventListener('hashchange', onHash)
    send({ type: 'ready' })
    return () => {
      off()
      window.removeEventListener('hashchange', onHash)
    }
  }, [say, runImport])

  if (!state) return <div className="rs-loading">正在连接…</div>

  return (
    <SideNav.Provider>
      <Tabs.Root className="rs-shell" orientation="vertical" value={tab} onValueChange={(v) => setTab(v as Tab)} data-drop={dropHover || undefined}>
        <SideNav.Root aria-label="Rhodeside" top={0} width={168}>
          <SideNav.Item value="pets" icon={<I.IconPaw />}>
            桌宠
          </SideNav.Item>
          <SideNav.Item value="models" icon={<I.IconBox />}>
            模型库
          </SideNav.Item>
          <SideNav.Item value="settings" icon={<I.IconGear />}>
            设置
          </SideNav.Item>
        </SideNav.Root>
        <main className="rs-main">
          <Tabs.Panel value="pets">
            <PetsPage state={state} />
          </Tabs.Panel>
          <Tabs.Panel value="models">
            <ModelsPage state={state} imports={imports} setImports={setImports} />
          </Tabs.Panel>
          <Tabs.Panel value="settings">
            <SettingsPage state={state} />
          </Tabs.Panel>
        </main>
      </Tabs.Root>
    </SideNav.Provider>
  )
}
