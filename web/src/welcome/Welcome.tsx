/**
 * 首次启动引导：① 登录（右下角可以跳过）→ ② 模型库里挑模型（左边勾选、右边预览）→ 完成时开始下载。
 * 登录本身不下载任何东西；标了 default 的模型（荒芜拉普兰德）只是默认勾上。
 */
import { useEffect, useRef, useState } from 'react'
import { Button } from '@rakko/react'

import { onMessage, send, type NativeState } from '../settings/bridge.ts'
import { Library, mb, pickable } from '../library/Library.tsx'
import '../settings/settings.css'
import './welcome.css'

export function WelcomeApp() {
  const [state, setState] = useState<NativeState | null>(null)
  const [skipped, setSkipped] = useState(false)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  // 目录第一次到手时把 default 的勾上（只做一次，之后听用户的）
  const seeded = useRef(false)

  useEffect(() => {
    const off = onMessage((m) => {
      if (m.type === 'state') {
        const { type: _t, ...rest } = m
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

  if (!state) return <div className="rs-loading">正在连接…</div>

  const { auth } = state
  let body
  let footer
  if (auth.phase === 'signedIn') {
    const chosen = state.catalog.filter((m) => selected.has(m.id) && pickable(m))
    const size = chosen.reduce((n, m) => n + m.size, 0)
    body = (
      <>
        <div>
          <h1 className="rw-title">选择模型</h1>
          <p className="rw-text">{auth.user ? `已登录：${auth.user}。` : ''}点击查看预览，勾选要下载的模型；以后也可以在 Rhodeside 窗口的「模型库」里添加。</p>
        </div>
        <Library state={state} selected={selected} onSelected={setSelected} />
      </>
    )
    footer = (
      <>
        <span className="rl-footer__hint">{chosen.length > 0 ? `已选 ${chosen.length} 个 · 共 ${mb(size)}` : '没有选择模型时桌面上不会出现桌宠'}</span>
        <Button onClick={() => send({ type: 'finishOnboarding' })}>稍后</Button>
        <Button disabled={chosen.length === 0} onClick={() => send({ type: 'finishOnboarding', ids: chosen.map((m) => m.id) })}>
          下载并开始使用
        </Button>
      </>
    )
  } else if (skipped) {
    body = (
      <>
        <h1 className="rw-title">已跳过登录</h1>
        <p className="rw-text">没有模型时桌面上不会出现桌宠。之后可以在 Rhodeside 窗口里登录（设置 → 账号）后从模型库下载，或在「模型库 → 我的模型」导入自己的 Spine 模型。</p>
      </>
    )
    footer = (
      <>
        <Button onClick={() => setSkipped(false)}>返回</Button>
        <Button onClick={() => send({ type: 'finishOnboarding' })}>完成</Button>
      </>
    )
  } else {
    body = (
      <>
        <h1 className="rw-title">欢迎使用 Rhodeside</h1>
        <p className="rw-text">登录后可以从模型库挑选下载模型，并自动接收更新。将使用 Priestess 账号在默认浏览器中登录。</p>
        {auth.phase === 'signingIn' && <p className="rw-text">正在等待浏览器完成登录…</p>}
        {auth.error && (
          <p className="rw-text" data-error>
            {auth.error}
          </p>
        )}
        <div className="rs-row">
          <Button onClick={() => send({ type: 'authLogin' })}>{auth.phase === 'signingIn' ? '重新打开登录页' : '登录'}</Button>
        </div>
      </>
    )
    footer = <Button onClick={() => setSkipped(true)}>跳过</Button>
  }

  return (
    <div className="rw-app">
      <main className="rw-body">{body}</main>
      <footer className="rw-footer">{footer}</footer>
    </div>
  )
}
