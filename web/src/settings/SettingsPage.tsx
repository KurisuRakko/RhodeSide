/**
 * 「设置」页：应用级的东西——账号、所有桌宠共用的行为、通用（启动 / 更新）、故障排查（默认折叠）。
 * 每只桌宠自己的设置在「桌宠」页。
 */
import { Button, Field } from '@rakko/react'
import { useState } from 'react'

import { dateTime, languageOptions, t, time } from '../i18n/index.ts'
import * as I from '../ui/icons.tsx'
import { native, send, type LogUploadStatus, type NativeState, type UpdateStatus } from './bridge.ts'
import { Choice, Group, nearest, Pick, Row, SwitchRow } from './ui.tsx'

const VOLUMES: [string, string][] = [
  ['1', '100%'],
  ['0.7', '70%'],
  ['0.5', '50%'],
  ['0.3', '30%'],
]

export function SettingsPage({ state }: { state: NativeState }) {
  const { config } = state
  // 老版本 App 的配置里没有 voice（前端先热更新到了、App 还没更新时）：不显示语音设置
  const voice = config.voice
  const s = t().settings
  const c = t().common
  // 老版本 App 的配置里没有 language（改了也存不住）：不显示
  const language = config.language
  return (
    <div className="rs-page">
      <header className="rs-page__head">
        <h1 className="rs-title">{s.title}</h1>
        {(state.webDev || !native) && (
          <div className="rs-row">
            {state.webDev && <span className="rs-badge">{s.devBadge}</span>}
            {!native && <span className="rs-badge">{c.browserPreview}</span>}
          </div>
        )}
      </header>

      <Account state={state} />

      <Group title={s.allPets}>
        <SwitchRow
          label={s.walkOnWindows}
          hint={s.walkOnWindowsHint}
          checked={config.walkOnWindows}
          onChange={(v) => send({ type: 'updateGlobal', patch: { walkOnWindows: v } })}
        />
        {config.hopOnWindows !== undefined && config.walkOnWindows && (
          <SwitchRow
            label={s.hopOnWindows}
            hint={s.hopOnWindowsHint}
            checked={config.hopOnWindows}
            onChange={(v) => send({ type: 'updateGlobal', patch: { hopOnWindows: v } })}
          />
        )}
        <SwitchRow
          label={s.hideInFullscreen}
          hint={s.hideInFullscreenHint}
          checked={config.hideInFullscreen}
          onChange={(v) => send({ type: 'updateGlobal', patch: { hideInFullscreen: v } })}
        />
        {config.watchMouse !== undefined && (
          <SwitchRow
            label={s.watchMouse}
            hint={s.watchMouseHint}
            checked={config.watchMouse}
            onChange={(v) => send({ type: 'updateGlobal', patch: { watchMouse: v } })}
          />
        )}
        {config.restWhenIdle !== undefined && (
          <SwitchRow
            label={s.restWhenIdle}
            hint={s.restWhenIdleHint}
            checked={config.restWhenIdle}
            onChange={(v) => send({ type: 'updateGlobal', patch: { restWhenIdle: v } })}
          />
        )}
        <IgnoreList apps={config.ignoredApps} defaults={state.defaultIgnoredApps} />
        {voice && (
          <>
            <SwitchRow
              label={s.voice}
              hint={s.voiceHint}
              checked={voice.enabled}
              onChange={(v) => send({ type: 'updateGlobal', patch: { voice: { ...voice, enabled: v } } })}
            />
            {voice.enabled && (
              <Row label={s.voiceVolume}>
                <Choice
                  aria={s.voiceVolume}
                  value={nearest(voice.volume, VOLUMES)}
                  options={VOLUMES}
                  onChange={(v) => send({ type: 'updateGlobal', patch: { voice: { ...voice, volume: Number(v) } } })}
                />
              </Row>
            )}
          </>
        )}
      </Group>

      <Group title={s.general}>
        {language !== undefined && (
          <Row label={s.language} hint={s.languageHint}>
            <Pick
              label={s.language}
              value={language}
              options={languageOptions()}
              onChange={(v) => send({ type: 'updateGlobal', patch: { language: v } })}
            />
          </Row>
        )}
        <SwitchRow label={s.openAtLogin} hint={state.loginItem.detail} checked={state.loginItem.enabled} onChange={(v) => send({ type: 'setLoginItem', enabled: v })} />
        <SwitchRow
          label={s.autoUpdate}
          hint={s.autoUpdateHint}
          checked={config.updates.enabled}
          onChange={(v) => send({ type: 'updateGlobal', patch: { updates: { ...config.updates, enabled: v } } })}
        />
        <Row label={s.updateStatus} hint={updateSummary(state.updates, config.updates.enabled)} error={!!state.updates.error || state.updates.app.state === 'failed'}>
          <Button onClick={() => send({ type: 'checkUpdates' })}>{s.checkUpdates}</Button>
        </Row>
      </Group>

      <details className="rs-fold">
        <summary>{s.troubleshooting}</summary>
        <div className="rs-fold__body">
          <dl className="rs-kv">
            <dt>{s.version}</dt>
            <dd>{state.version}</dd>
            <dt>{s.appBuild}</dt>
            <dd>{formatBuild(state.updates.app.current)}</dd>
            <dt>{s.webBuild}</dt>
            <dd>{formatBuild(state.updates.current)}</dd>
            {state.updates.lastCheck && (
              <>
                <dt>{s.lastCheck}</dt>
                <dd>{dateTime(new Date(state.updates.lastCheck))}</dd>
              </>
            )}
            {state.logUpload && (
              <>
                <dt>{s.logUpload}</dt>
                <dd>{logUploadSummary(state.logUpload)}</dd>
              </>
            )}
          </dl>
          {state.logUpload && <p className="rs-hint">{s.logUploadNote}</p>}
          <div className="rs-row">
            <Button onClick={() => send({ type: 'reveal', what: 'logs' })}>{s.showLogs}</Button>
            <Button onClick={() => send({ type: 'reveal', what: 'models' })}>{s.showModels}</Button>
            <Button onClick={() => send({ type: 'reveal', what: 'config' })}>{s.showConfig}</Button>
            <Button onClick={() => send({ type: 'snapshot' })}>
              <I.IconCamera /> {s.snapshot}
            </Button>
            <Button onClick={() => send({ type: 'reloadWeb' })}>
              <I.IconReplay /> {s.reloadWeb}
            </Button>
          </div>
        </div>
      </details>
    </div>
  )
}

function logUploadSummary(u: LogUploadStatus): string {
  const s = t().settings
  if (u.busy) return s.uploading
  const last = u.lastUpload ? dateTime(new Date(u.lastUpload)) : s.neverUploaded
  return u.error ? s.lastFailed(last, u.error) : last
}

/** 更新状态一句话：正在进行的事 > 错误 > 有新版本 > 已是最新 */
function updateSummary(u: UpdateStatus, enabled: boolean): string {
  const s = t().settings
  if (u.app.state) return s.appState[u.app.state] ?? u.app.state
  if (u.error) return u.error
  const newer = (u.app.remote !== null && u.app.remote > u.app.current) || (u.remote !== null && u.remote > u.current)
  if (newer) return enabled ? s.updating : s.newerButOff
  if (!u.lastCheck) return enabled ? s.neverChecked : s.updatesOff
  return s.upToDate(time(new Date(u.lastCheck)))
}

/* ------------------------------------------------------------------ 账号 */

function Account({ state }: { state: NativeState }) {
  const { auth } = state
  const signedIn = auth.phase === 'signedIn'
  const s = t().settings
  const c = t().common
  const text =
    auth.phase === 'signedIn' ? s.signedIn(auth.user) : auth.phase === 'signingIn' ? s.signingIn : auth.phase === 'denied' ? s.denied : s.signedOut
  return (
    <Group title={s.account}>
      <Row label={s.priestess} hint={auth.error ? `${text} · ${auth.error}` : text} error={auth.phase === 'denied' || !!auth.error}>
        {signedIn ? (
          <Button onClick={() => send({ type: 'authLogout' })}>{s.logout}</Button>
        ) : (
          <Button variant="primary" onClick={() => send({ type: 'authLogin' })}>
            {auth.phase === 'signingIn' ? c.reopenLogin : c.login}
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
  const s = t().settings
  const c = t().common
  return (
    <>
      <Row label={s.ignoredApps} hint={s.ignoredAppsHint}>
        <span className="rs-line__value">{s.appCount(apps.length)}</span>
        <Button onClick={() => setOpen(!open)}>{open ? c.collapse : c.edit}</Button>
      </Row>
      {open && (
        <div className="rs-line rs-line--block">
          <div className="rs-chips">
            {apps.map((a) => (
              <span key={a} className="rs-chip">
                {a}
                <button type="button" className="rs-chip__x" aria-label={s.removeApp(a)} onClick={() => set(apps.filter((x) => x !== a))}>
                  ✕
                </button>
              </span>
            ))}
            {apps.length === 0 && <span className="rs-hint">{s.noIgnoredApps}</span>}
          </div>
          <form
            className="rs-row"
            onSubmit={(e) => {
              e.preventDefault()
              add()
            }}
          >
            <Field.Root className="rs-grow">
              <Field.Control placeholder={s.processPlaceholder} value={draft} onChange={(e) => setDraft((e.target as HTMLInputElement).value)} />
            </Field.Root>
            <Button type="submit" disabled={!draft.trim()}>
              {c.add}
            </Button>
            {!same && <Button onClick={() => set(defaults)}>{s.restoreDefaults}</Button>}
          </form>
        </div>
      )}
    </>
  )
}

/** 构建号是毫秒时间戳：显示成本地时间 */
function formatBuild(build: number) {
  if (!build) return t().settings.builtinBuild
  const d = new Date(build)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
}
