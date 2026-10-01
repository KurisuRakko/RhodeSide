// node --test web/src/i18n/i18n.test.ts
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { resolveLang, systemLang } from './index.ts'

test('系统语言：写明文字的按文字，没写的按地区', () => {
  assert.equal(systemLang(['zh-Hans-HK']), 'zh-Hans')
  assert.equal(systemLang(['zh-HK']), 'zh-Hant')
  assert.equal(systemLang(['zh-Hant-TW']), 'zh-Hant')
  assert.equal(systemLang(['zh-CN', 'en']), 'zh-Hans')
  assert.equal(systemLang(['yue-Hant-HK']), 'zh-Hant')
  assert.equal(systemLang(['en-AU', 'zh-Hans']), 'en')
  assert.equal(systemLang([]), 'zh-Hans')
})

test('配置值优先，不认识的当跟随系统', () => {
  assert.equal(resolveLang('en', ['zh-Hans']), 'en')
  assert.equal(resolveLang('system', ['zh-Hant-HK']), 'zh-Hant')
  assert.equal(resolveLang('klingon', ['ja-JP']), 'en')
})
