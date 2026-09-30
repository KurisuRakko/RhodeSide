import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

import '../styles/app.css'
import { SettingsApp } from './Settings.tsx'

const container = document.getElementById('root')
if (!container) throw new Error('找不到 #root 挂载点')

createRoot(container).render(
  <StrictMode>
    <SettingsApp />
  </StrictMode>,
)
