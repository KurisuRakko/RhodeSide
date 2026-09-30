/**
 * Priestess 登录回跳页（https://rhodeside.rakko.cn/auth/callback）。
 * 把 #login_code / state / auth_error 转给 App：rhodeside://auth/callback?…，并立即从地址栏抹掉。
 */
import { Button } from '@rakko/react'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

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

const MESSAGES: Record<string, string> = {
  app_access_denied: '当前账号没有 Rhodeside 的使用权限，请联系管理员。',
  local_user_disabled: '账号已停用。',
  app_not_found: 'Priestess 中没有 Rhodeside 应用（未注册或已停用）。',
}

function Callback() {
  const title = error ? '登录未完成' : hasCode ? '登录成功' : '没有收到登录结果'
  const detail = error
    ? (MESSAGES[error] ?? out.get('auth_error_description') ?? error)
    : hasCode
      ? '正在返回 Rhodeside。如果没有自动打开，请点击下方按钮（60 秒内有效）。'
      : '请回到 Rhodeside 重新发起登录。'
  return (
    <main className="rs-callback">
      <h1 className="rs-callback__title">{title}</h1>
      <p className="rs-callback__detail" data-error={error ? true : undefined}>
        {detail}
      </p>
      {(hasCode || error) && <Button onClick={() => (location.href = target)}>打开 Rhodeside</Button>}
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
