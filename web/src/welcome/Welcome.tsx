/**
 * 首次启动引导：① 登录（右下角可以跳过，左下角可以换界面语言）→ ② 模型库里挑模型（左边勾选、右边预览）→ 完成时开始下载。
 * 登录本身不下载任何东西；标了 default 的模型（荒芜拉普兰德）只是默认勾上。
 */
import { useEffect, useRef, useState } from 'react'
import { Button } from '@rakko/react'

import { adoptState, languageOptions, setTitle, t } from '../i18n/index.ts'
import { onMessage, send, type NativeState } from '../settings/bridge.ts'
import { Library, mb, pickable } from '../library/Library.tsx'
import { Pick } from '../settings/ui.tsx'
import '../settings/settings.css'
import './welcome.css'

export function WelcomeApp() {
  const [state, setState] = useState<NativeState | null>(null)
  const [skipped, setSkipped] = useState(false)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  // 目录第一次到手时把 default 的勾上（只做一次，之后听用户的）
  const seeded = useRef(false)

  useEffect(() => {
    setTitle((m) => m.welcome.windowTitle)
    const off = onMessage((m) => {
      if (m.type === 'state') {
        const { type: _t, ...rest } = m
        adoptState(rest)
        setState(rest)
        if (!seeded.current && rest.catalog.length > 0) {
          seeded.current = true
          setSelected(new Set(rest.catalog.filter((c) => c.default && pickable(c)).map((c) => c.id)))
        }
      }
    })
    send({ type: 'ready' })
    return off
  }, [])

  const s = t().welcome
  const c = t().common
  if (!state) return <div className="rs-loading">{c.connecting}</div>

  const { auth } = state
  let body
  let footer
  if (auth.phase === 'signedIn') {
    const chosen = state.catalog.filter((m) => selected.has(m.id) && pickable(m))
    const size = chosen.reduce((n, m) => n + m.size, 0)
    body = (
      <>
        <div>
          <h1 className="rw-title">{s.chooseTitle}</h1>
          <p className="rw-text">{s.chooseText(auth.user)}</p>
        </div>
        <Library state={state} selected={selected} onSelected={setSelected} />
      </>
    )
    footer = (
      <>
        <span className="rl-footer__hint">{chosen.length > 0 ? c.selected(chosen.length, mb(size)) : s.noneSelected}</span>
        <Button onClick={() => send({ type: 'finishOnboarding' })}>{s.later}</Button>
        <Button disabled={chosen.length === 0} onClick={() => send({ type: 'finishOnboarding', ids: chosen.map((m) => m.id) })}>
          {s.downloadAndStart}
        </Button>
      </>
    )
  } else if (skipped) {
    body = (
      <>
        <h1 className="rw-title">{s.skippedTitle}</h1>
        <p className="rw-text">{s.skippedText}</p>
      </>
    )
    footer = (
      <>
        <Button onClick={() => setSkipped(false)}>{c.back}</Button>
        <Button onClick={() => send({ type: 'finishOnboarding' })}>{s.done}</Button>
      </>
    )
  } else {
    body = (
      <>
        <h1 className="rw-title">{s.title}</h1>
        <p className="rw-text">{s.text}</p>
        {auth.phase === 'signingIn' && <p className="rw-text">{t().settings.signingIn}</p>}
        {auth.error && (
          <p className="rw-text" data-error>
            {auth.error}
          </p>
        )}
        <div className="rs-row">
          <Button onClick={() => send({ type: 'authLogin' })}>{auth.phase === 'signingIn' ? c.reopenLogin : c.login}</Button>
        </div>
      </>
    )
    const language = state.config.language
    footer = (
      <>
        {/* 老版本 App 存不住 language：不显示 */}
        {language !== undefined && (
          <div className="rw-lang">
            <Pick
              label={t().settings.language}
              value={language}
              options={languageOptions()}
              onChange={(v) => send({ type: 'updateGlobal', patch: { language: v } })}
            />
          </div>
        )}
        <Button onClick={() => setSkipped(true)}>{s.skip}</Button>
      </>
    )
  }

  return (
    <div className="rw-app">
      <main className="rw-body">{body}</main>
      <footer className="rw-footer">{footer}</footer>
    </div>
  )
}
