import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

import '../styles/app.css'
import { WelcomeApp } from './Welcome.tsx'

const container = document.getElementById('root')
if (!container) throw new Error('找不到 #root 挂载点')

createRoot(container).render(
  <StrictMode>
    <WelcomeApp />
  </StrictMode>,
)
