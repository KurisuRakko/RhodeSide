// node --test web/src/stage/combos.test.ts
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { attackCombo, comboLabel, detectCombos, LOOP_SECONDS } from './combos.ts'

const anims = (o: Record<string, number>) => Object.entries(o).map(([name, duration]) => ({ name, duration }))

/** 典型的六星战斗模型（乌尔比安一类的命名） */
const battle = anims({
  Default: 1, Idle: 1.3, Start: 1.1, Die: 1.5, Attack: 0.8,
  Skill_1_Begin: 0.5, Skill_1_Loop: 1, Skill_1_End: 0.4,
  Skill_3_Begin: 0.6, Skill_3_Idle: 1, Skill_3_Attack: 0.7, Skill_3_End: 0.5,
  Skill_2_Loop: 1, Skill_2_End: 0.3,
  Skill_3_Restart_Begin: 0.4, Stun_End: 0.2,
})

test('认出套组和单个按钮', () => {
  const c = detectCombos(battle)
  assert.deepEqual(c.map((x) => x.id), ['Start', 'Attack', 'Skill_1', 'Skill_2', 'Skill_3'])
  assert.deepEqual(c.map((x) => x.label), ['登场', '攻击', '技能 1', '技能 2', '技能 3'])
  const s1 = c.find((x) => x.id === 'Skill_1')!.steps
  assert.deepEqual(s1.map((s) => s.name), ['Skill_1_Begin', 'Skill_1_Loop', 'Skill_1_End'])
  assert.deepEqual(s1.map((s) => s.loop), [false, true, false])
  assert.equal(s1[1].seconds, LOOP_SECONDS)
  assert.equal(s1[0].seconds, 0.5)
  // 没有开头：循环 + 结尾
  assert.deepEqual(c.find((x) => x.id === 'Skill_2')!.steps.map((s) => s.name), ['Skill_2_Loop', 'Skill_2_End'])
  // 有 Attack 的套组：待机里穿插两次攻击
  assert.deepEqual(c.find((x) => x.id === 'Skill_3')!.steps.map((s) => s.name), [
    'Skill_3_Begin', 'Skill_3_Idle', 'Skill_3_Attack', 'Skill_3_Attack', 'Skill_3_Idle', 'Skill_3_End',
  ])
  // 只有开头（Restart_Begin）、只有结尾（Stun_End）的不算
  assert.ok(!c.some((x) => x.id.includes('Restart') || x.id === 'Stun'))
})

test('有攻击套组时不再单列 Attack', () => {
  const c = detectCombos(anims({ Idle: 1, Attack: 1, Attack_Begin: 0.3, Attack_Loop: 1, Attack_End: 0.3 }))
  assert.deepEqual(c.map((x) => x.id), ['Attack'])
  assert.equal(c[0].steps.length, 3)
  assert.equal(attackCombo(c)?.label, '攻击')
})

test('按钮名', () => {
  assert.equal(comboLabel('Skill_Down_2'), '技能 2 · Down')
  assert.equal(comboLabel('Skill_03'), '技能 3')
  assert.equal(comboLabel('Skill'), '技能')
  assert.equal(comboLabel('Combat_A'), 'Combat · A')
})

test('基建模型没有套组', () => {
  assert.deepEqual(detectCombos(anims({ Relax: 2, Move: 1, Interact: 1.5, Sit: 3, Sleep: 4, Special: 1 })), [])
})
