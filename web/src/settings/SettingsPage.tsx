/**
 * 「设置」页：应用级的东西——账号、所有桌宠共用的行为、通用（启动 / 更新）、故障排查（默认折叠）。
 * 每只桌宠自己的设置在「桌宠」页。
 */
import { Button, Field } from '@rakko/react'
import { useState } from 'react'

import * as I from '../ui/icons.tsx'
import { native, send, type NativeState, type UpdateStatus } from './bridge.ts'
import { Choice, Group, nearest, Row, SwitchRow } from './ui.tsx'

const VOLUMES: [string, string][] = [
  ['1', '100%'],
  ['0.7', '70%'],
  ['0.5', '50%'],
  ['0.3', '30%'],
]

const APP_STATE: Record<string, string> = {
  waiting: '有新版本，拖动结束后安装',
  downloading: '正在下载新版本',
  installing: '正在验证新版本',
  restarting: '正在重启',
  failed: '新版本无法启动，已恢复旧版本',
}

export function SettingsPage({ state }: { state: NativeState }) {
  const { config } = state
  // 老版本 App 的配置里没有 voice（前端先热更新到了、App 还没更新时）：不显示语音设置
  const voice = config.voice
  return (
    <div className="rs-page">
      <header className="rs-page__head">
        <h1 className="rs-title">设置</h1>
        {(state.webDev || !native) && (
          <div className="rs-row">
            {state.webDev && <span className="rs-badge">开发版界面</span>}
            {!native && <span className="rs-badge">浏览器预览</span>}
          </div>
        )}
      </header>

      <Account state={state} />

      <Group title="所有桌宠">
        <SwitchRow
          label="在窗口上行走"
          hint="关掉后只在屏幕底部活动"
          checked={config.walkOnWindows}
          onChange={(v) => send({ type: 'updateGlobal', patch: { walkOnWindows: v } })}
        />
        <SwitchRow
          label="其他应用全屏时隐藏"
          hint="有应用全屏时，隐藏那块屏幕上的桌宠"
          checked={config.hideInFullscreen}
          onChange={(v) => send({ type: 'updateGlobal', patch: { hideInFullscreen: v } })}
        />
        <IgnoreList apps={config.ignoredApps} defaults={state.defaultIgnoredApps} />
        {voice && (
          <>
            <SwitchRow
              label="语音"
              hint="基建形态下出现时和被点一下时说话（模型带语音才有）"
              checked={voice.enabled}
              onChange={(v) => send({ type: 'updateGlobal', patch: { voice: { ...voice, enabled: v } } })}
            />
            {voice.enabled && (
              <Row label="语音音量">
                <Choice
                  aria="语音音量"
                  value={nearest(voice.volume, VOLUMES)}
                  options={VOLUMES}
                  onChange={(v) => send({ type: 'updateGlobal', patch: { voice: { ...voice, volume: Number(v) } } })}
                />
              </Row>
            )}
          </>
        )}
      </Group>

      <Group title="通用">
        <SwitchRow label="登录时打开" hint={state.loginItem.detail} checked={state.loginItem.enabled} onChange={(v) => send({ type: 'setLoginItem', enabled: v })} />
        <SwitchRow
          label="自动更新"
          hint="界面更新立即生效；应用更新后会自动重启，启动失败会恢复旧版本"
          checked={config.updates.enabled}
          onChange={(v) => send({ type: 'updateGlobal', patch: { updates: { ...config.updates, enabled: v } } })}
        />
        <Row label="更新状态" hint={updateSummary(state.updates, config.updates.enabled)} error={!!state.updates.error || state.updates.app.state === 'failed'}>
          <Button onClick={() => send({ type: 'checkUpdates' })}>检查更新</Button>
        </Row>
      </Group>

      <details className="rs-fold">
        <summary>故障排查</summary>
        <div className="rs-fold__body">
          <dl className="rs-kv">
            <dt>版本</dt>
            <dd>{state.version}</dd>
            <dt>应用构建</dt>
            <dd>{formatBuild(state.updates.app.current)}</dd>
            <dt>界面构建</dt>
            <dd>{formatBuild(state.updates.current)}</dd>
            {state.updates.lastCheck && (
              <>
                <dt>上次检查</dt>
                <dd>{new Date(state.updates.lastCheck).toLocaleString()}</dd>
              </>
            )}
          </dl>
          <div className="rs-row">
            <Button onClick={() => send({ type: 'reveal', what: 'logs' })}>显示日志</Button>
            <Button onClick={() => send({ type: 'reveal', what: 'models' })}>显示模型文件夹</Button>
            <Button onClick={() => send({ type: 'reveal', what: 'config' })}>显示配置文件</Button>
            <Button onClick={() => send({ type: 'snapshot' })}>
              <I.IconCamera /> 诊断快照
            </Button>
            <Button onClick={() => send({ type: 'reloadWeb' })}>
              <I.IconReplay /> 重新载入界面
            </Button>
          </div>
        </div>
      </details>
    </div>
  )
}

/** 更新状态一句话：正在进行的事 > 错误 > 有新版本 > 已是最新 */
function updateSummary(u: UpdateStatus, enabled: boolean): string {
  if (u.app.state) return APP_STATE[u.app.state] ?? u.app.state
  if (u.error) return u.error
  const newer = (u.app.remote !== null && u.app.remote > u.app.current) || (u.remote !== null && u.remote > u.current)
  if (newer) return enabled ? '发现新版本，正在更新…' : '有新版本（自动更新已关闭，打开后安装）'
  if (!u.lastCheck) return enabled ? '还没检查过' : '自动更新已关闭'
  return `已是最新 · ${new Date(u.lastCheck).toLocaleTimeString()} 检查`
}

/* ------------------------------------------------------------------ 账号 */

function Account({ state }: { state: NativeState }) {
  const { auth } = state
  const signedIn = auth.phase === 'signedIn'
  const text =
    auth.phase === 'signedIn'
      ? `已登录${auth.user ? ` · ${auth.user}` : ''}`
      : auth.phase === 'signingIn'
        ? '正在等待浏览器完成登录…'
        : auth.phase === 'denied'
          ? '这个账号没有使用权限'
          : '没登录：登录后才能接收更新、下载模型'
  return (
    <Group title="账号">
      <Row label="Priestess 账号" hint={auth.error ? `${text} · ${auth.error}` : text} error={auth.phase === 'denied' || !!auth.error}>
        {signedIn ? (
          <Button onClick={() => send({ type: 'authLogout' })}>退出登录</Button>
        ) : (
          <Button variant="primary" onClick={() => send({ type: 'authLogin' })}>
            {auth.phase === 'signingIn' ? '重新打开登录页' : '登录'}
          </Button>
        )}
      </Row>
    </Group>
  )
}

/* ------------------------------------------------------------------ 排除的应用 */

function IgnoreList({ apps, defaults }: { apps: string[]; defaults: string[] }) {
  const [open, setOpen] = useState(false)
  const [draft, setDraft] = useState('')
  const set = (list: string[]) => send({ type: 'updateGlobal', patch: { ignoredApps: list } })
  const add = () => {
    const name = draft.trim()
    if (name && !apps.some((a) => a.toLowerCase() === name.toLowerCase())) set([...apps, name])
    setDraft('')
  }
  const same = apps.length === defaults.length && apps.every((a, i) => a === defaults[i])
  return (
    <>
      <Row label="排除的应用" hint="桌宠不会站到这些应用的窗口上，适合截图、悬浮窗类工具">
        <span className="rs-line__value">{apps.length} 个</span>
        <Button onClick={() => setOpen(!open)}>{open ? '收起' : '编辑'}</Button>
      </Row>
      {open && (
        <div className="rs-line rs-line--block">
          <div className="rs-chips">
            {apps.map((a) => (
              <span key={a} className="rs-chip">
                {a}
                <button type="button" className="rs-chip__x" aria-label={`移除 ${a}`} onClick={() => set(apps.filter((x) => x !== a))}>
                  ✕
                </button>
              </span>
            ))}
            {apps.length === 0 && <span className="rs-hint">没有排除任何应用</span>}
          </div>
          <form
            className="rs-row"
            onSubmit={(e) => {
              e.preventDefault()
              add()
            }}
          >
            <Field.Root className="rs-grow">
              <Field.Control placeholder="进程名，如 Snipaste" value={draft} onChange={(e) => setDraft((e.target as HTMLInputElement).value)} />
            </Field.Root>
            <Button type="submit" disabled={!draft.trim()}>
              添加
            </Button>
            {!same && <Button onClick={() => set(defaults)}>恢复默认</Button>}
          </form>
        </div>
      )}
    </>
  )
}

/** 构建号是毫秒时间戳：显示成本地时间 */
function formatBuild(build: number) {
  if (!build) return '内置版本'
  const d = new Date(build)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
}
