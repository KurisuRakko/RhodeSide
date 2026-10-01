/**
 * Priestess 登录回跳页（https://rhodeside.rakko.cn/auth/callback）。
 * 把 #login_code / state / auth_error 转给 App：rhodeside://auth/callback?…，并立即从地址栏抹掉。
 * 这页在用户的浏览器里打开，拿不到 App 的语言设置：跟浏览器语言（i18n 模块默认就是）。
 */
import { Button } from '@rakko/react'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

import { setTitle, t } from '../i18n/index.ts'

import '../styles/app.css'
import './callback.css'

const KEYS = ['login_code', 'state', 'auth_error', 'auth_error_description'] as const
const hash = new URLSearchParams(location.hash.replace(/^#/, ''))
const query = new URLSearchParams(location.search)
const out = new URLSearchParams()
for (const k of KEYS) {
  const v = hash.get(k) ?? query.get(k)
  if (v) out.set(k, v)
}
history.replaceState(null, '', location.pathname)

const target = `rhodeside://auth/callback?${out.toString()}`
const error = out.get('auth_error')
const hasCode = out.has('login_code')

setTitle((m) => m.auth.windowTitle)

function Callback() {
  const s = t().auth
  const title = error ? s.failedTitle : hasCode ? s.successTitle : s.noResultTitle
  const detail = error ? (s.errors[error] ?? out.get('auth_error_description') ?? error) : hasCode ? s.returning : s.retry
  return (
    <main className="rs-callback">
      <h1 className="rs-callback__title">{title}</h1>
      <p className="rs-callback__detail" data-error={error ? true : undefined}>
        {detail}
      </p>
      {(hasCode || error) && <Button onClick={() => (location.href = target)}>{s.open}</Button>}
    </main>
  )
}

const root = document.getElementById('root')
if (!root) throw new Error('找不到 #root 挂载点')
createRoot(root).render(
  <StrictMode>
    <Callback />
  </StrictMode>,
)
if (hasCode || error) location.href = target
