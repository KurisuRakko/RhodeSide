// node --test web/src/pet/motion.test.ts
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { extrapolate, MAX_AHEAD, MAX_AHEAD_IN_AIR } from './motion.ts'

const near = (a: number, b: number, eps = 1e-6) => assert.ok(Math.abs(a - b) < eps, `${a} ≉ ${b}`)

test('地上匀速', () => {
  const p = extrapolate({ x: 100, vx: 50, y: 54, vy: 0, g: 0, k: 0 }, 0.2)
  near(p.x, 110)
  near(p.y, 54)
})

test('空中抛物线 + 水平阻尼', () => {
  const p = extrapolate({ x: 0, vx: 120, y: 0, vy: 1000, g: 2800, k: 1.2 }, 0.08)
  near(p.x, (120 * (1 - Math.exp(-1.2 * 0.08))) / 1.2)
  near(p.y, 1000 * 0.08 - 1400 * 0.0064)
})

test('最多外推 MAX_AHEAD 秒，负时间当 0', () => {
  const m = { x: 0, vx: 100, y: 0, vy: 0, g: 0, k: 0 }
  near(extrapolate(m, 5).x, 100 * MAX_AHEAD)
  near(extrapolate(m, -1).x, 0)
  near(extrapolate({ ...m, g: 2800, k: 1.2 }, 5).y, -1400 * MAX_AHEAD_IN_AIR * MAX_AHEAD_IN_AIR)
})
