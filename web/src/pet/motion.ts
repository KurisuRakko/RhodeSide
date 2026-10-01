/**
 * 两次位置消息之间怎么外推小人的位置：和原生层 `macos/Sources/PetCore/Geometry.swift` 的 `Motion` 是同一个公式。
 * 地上匀速；空中（g > 0）水平速度按 e^(-k·t) 衰减、竖直按重力走抛物线。
 * 外推有上限（地上 MAX_AHEAD、空中 MAX_AHEAD_IN_AIR 秒），收不到消息就停在那里：原生层卡住时这边还在推，
 * 原生恢复后每帧最多只走 0.05 秒，推太远会冲过头再弹回来。
 * 原生层只在外推误差超过 1.5pt、运动方式变了时才发新位置，另外每 250ms 校正一次。
 */
export interface Motion {
  x: number
  vx: number
  y: number
  vy: number
  /** 重力（pt/s²），0 = 不在空中 */
  g: number
  /** 空中水平速度的衰减率（1/s） */
  k: number
}

export const MAX_AHEAD = 0.3
export const MAX_AHEAD_IN_AIR = 0.1

export function extrapolate(m: Motion, seconds: number): { x: number; y: number } {
  const t = Math.min(Math.max(seconds, 0), m.g > 0 ? MAX_AHEAD_IN_AIR : MAX_AHEAD)
  const dx = m.k > 0 ? (m.vx * (1 - Math.exp(-m.k * t))) / m.k : m.vx * t
  return { x: m.x + dx, y: m.y + m.vy * t - (m.g * t * t) / 2 }
}
