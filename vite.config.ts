import { fileURLToPath } from 'node:url'

import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

/** vendor/ 里的外来件一律用绝对路径做 alias，避免相对 root 解析。 */
const vendor = (rel: string) =>
  fileURLToPath(new URL(`./vendor/rakko-design/${rel}`, import.meta.url))

const port = Number(process.env.SPINESTAGE_PORT ?? 8066)
const page = (rel: string) => fileURLToPath(new URL(`./web/${rel}`, import.meta.url))

export default defineConfig({
  root: 'web',
  // 相对路径：壳从自定义协议（rhodeside-res://）或热更新目录加载页面，不能假设站点根
  base: './',
  plugins: [react()],
  resolve: {
    // 数组形式按顺序匹配：带 /styles.css 的键必须排在裸包名之前。
    alias: [
      { find: '@rakko/react/styles.css', replacement: vendor('react/src/styles.css') },
      { find: '@rakko/react', replacement: vendor('react/src/index.ts') },
      { find: '@rakko/design-system/tokens.css', replacement: vendor('tokens.generated.css') },
      { find: '@rakko/design-system/ripple', replacement: vendor('design-system/src/ripple.js') },
    ],
    dedupe: ['react', 'react-dom'],
  },
  build: {
    // 实际输出目录由 macos/scripts/deploy.sh 的 --outDir 指定
    outDir: 'dist',
    emptyOutDir: true,
    // 多页面：pet.html（桌宠渲染）、settings.html（设置）、welcome.html（引导）、auth-callback.html（登录回跳）
    rolldownOptions: { input: { pet: page('pet.html'), settings: page('settings.html'), welcome: page('welcome.html'), 'auth-callback': page('auth-callback.html') } },
  },
  // 局域网 / tailnet 可访问；allowedHosts 放行 rakkoserver.tail524041.ts.net 这类主机名。
  // fs.allow 只放网页、设计系统和依赖：默认会放行整个工作区，/@fs/ 能读到 models-private（授权模型，不能公开）
  server: {
    host: '0.0.0.0',
    port,
    strictPort: true,
    allowedHosts: true,
    fs: { strict: true, allow: [fileURLToPath(new URL('./web', import.meta.url)), fileURLToPath(new URL('./vendor', import.meta.url)), fileURLToPath(new URL('./node_modules', import.meta.url))] },
  },
})
