/* 首屏主题：外链脚本（不内联，便于以后上 CSP script-src 'self'），
   在 CSS 之前定好 data-theme，避免闪白 / 闪黑。
   localStorage.rakkoTheme ∈ light|dark 优先；否则跟随 prefers-color-scheme；
   未手动选过（键不存在 / 为 system）时继续跟随系统变化。 */
;(function () {
  var KEY = 'rakkoTheme'
  var stored = null
  try {
    stored = window.localStorage.getItem(KEY)
  } catch (err) {
    stored = null
  }
  var mq = window.matchMedia('(prefers-color-scheme: dark)')
  var manual = stored === 'light' || stored === 'dark'
  var apply = function (dark) {
    document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light')
  }
  apply(manual ? stored === 'dark' : mq.matches)
  if (!manual) {
    mq.addEventListener('change', function (event) {
      apply(event.matches)
    })
  }
})()
