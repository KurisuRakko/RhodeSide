// 线性图标，一律 currentColor（check-design 不许写死颜色）。
const base = {
  viewBox: '0 0 24 24',
  width: 18,
  height: 18,
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.8,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  'aria-hidden': true,
}

export const IconFolder = () => (
  <svg {...base}>
    <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
  </svg>
)

export const IconCamera = () => (
  <svg {...base}>
    <path d="M4 8a2 2 0 0 1 2-2h1.5l1.5-2h6l1.5 2H18a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2Z" />
    <circle cx="12" cy="12.5" r="3.5" />
  </svg>
)

export const IconReplay = () => (
  <svg {...base}>
    <path d="M4 12a8 8 0 1 0 2.4-5.7M4 4v4h4" />
  </svg>
)

export const IconPlus = () => (
  <svg {...base}>
    <path d="M12 5v14M5 12h14" />
  </svg>
)

export const IconTrash = () => (
  <svg {...base}>
    <path d="M5 7h14M10 11v6M14 11v6M6 7l1 12a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1l1-12M9 7V4h6v3" />
  </svg>
)

export const IconPaw = () => (
  <svg {...base}>
    <circle cx="6.5" cy="10" r="1.8" />
    <circle cx="10" cy="6" r="1.8" />
    <circle cx="14" cy="6" r="1.8" />
    <circle cx="17.5" cy="10" r="1.8" />
    <path d="M12 12c-2.8 0-5 2.6-5 5 0 1.6 1.2 2.5 2.6 2.5.9 0 1.6-.5 2.4-.5s1.5.5 2.4.5c1.4 0 2.6-.9 2.6-2.5 0-2.4-2.2-5-5-5Z" />
  </svg>
)

export const IconBox = () => (
  <svg {...base}>
    <path d="m12 3 8 4.5v9L12 21l-8-4.5v-9Z" />
    <path d="m4 7.5 8 4.5 8-4.5M12 12v9" />
  </svg>
)

export const IconGear = () => (
  <svg {...base}>
    <circle cx="12" cy="12" r="3" />
    <path d="M12 2.5v3M12 18.5v3M4.2 6.2l2.1 2.1M17.7 15.7l2.1 2.1M2.5 12h3M18.5 12h3M4.2 17.8l2.1-2.1M17.7 8.3l2.1-2.1" />
  </svg>
)

export const IconBack = () => (
  <svg {...base}>
    <path d="M15 5l-7 7 7 7" />
  </svg>
)
