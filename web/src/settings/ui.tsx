/** Rhodeside 窗口的版式零件：系统设置式分组（左边名字、右边控件）+ 几个表单小件 */
import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { SegmentedChoice, Select, Switch } from '@rakko/react'

import { t } from '../i18n/index.ts'

/** 一组设置：组标题在框外，框里一行一项，行之间有分隔线 */
export function Group({ title, action, children }: { title: string; action?: ReactNode; children: ReactNode }) {
  return (
    <section className="rs-group">
      <header className="rs-group__head">
        <h2 className="rs-group__title">{title}</h2>
        {action}
      </header>
      <div className="rs-group__body">{children}</div>
    </section>
  )
}

/** 一行：左边名字 + 小字说明，右边控件；窗口窄时控件换到下一行 */
export function Row({ label, hint, error, children }: { label: ReactNode; hint?: ReactNode; error?: boolean; children?: ReactNode }) {
  return (
    <div className="rs-line">
      <div className="rs-line__text">
        <div className="rs-line__label">{label}</div>
        {hint && (
          <div className="rs-line__hint" data-error={error || undefined}>
            {hint}
          </div>
        )}
      </div>
      {children !== undefined && <div className="rs-line__control">{children}</div>}
    </div>
  )
}

/** 开关行：整行都能点 */
export function SwitchRow({ label, hint, checked, onChange }: { label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="rs-line rs-line--switch">
      <span className="rs-line__text">
        <span className="rs-line__label">{label}</span>
        {hint && <span className="rs-line__hint">{hint}</span>}
      </span>
      <Switch.Root checked={checked} onCheckedChange={onChange}>
        <Switch.Thumb />
      </Switch.Root>
    </label>
  )
}

/** 下拉选择：当前值不在选项里（手改了配置、模型被删了）时补一项标成不可用，界面和实际配置保持一致 */
export function Pick({ label, value, options, onChange }: { label: string; value: string | null; options: [string, string][]; onChange: (v: string) => void }) {
  const all: [string, string][] = value !== null && !options.some(([v]) => v === value) ? [...options, [value, t().common.unavailable(value)]] : options
  // items 身份一变 Base UI 的 Select 就会重算：按内容 memo
  const key = JSON.stringify(all)
  const items = useMemo(() => (JSON.parse(key) as [string, string][]).map(([v, text]) => ({ value: v, label: text })), [key])
  return (
    <Select.Root items={items} value={value} onValueChange={(v) => v !== null && onChange(v as string)}>
      <Select.Trigger aria-label={label} className="rs-select">
        <Select.Value placeholder="—" />
        <Select.Icon aria-hidden="true">▾</Select.Icon>
      </Select.Trigger>
      <Select.Popup>
        {items.map((it) => (
          <Select.Item key={it.value} value={it.value}>
            <Select.ItemText>{it.label}</Select.ItemText>
            <Select.ItemIndicator />
          </Select.Item>
        ))}
      </Select.Popup>
    </Select.Root>
  )
}

/** 分段选择（大小、不透明度、活动方式…） */
export function Choice({ aria, value, options, onChange }: { aria: string; value: string | null; options: [string, string][]; onChange: (v: string) => void }) {
  return (
    <SegmentedChoice.Root className="rs-choice" aria-label={aria} value={value ?? ''} onValueChange={(v) => v && onChange(String(v))}>
      {options.map(([v, t]) => (
        <SegmentedChoice.Item key={v} value={v}>
          {t}
        </SegmentedChoice.Item>
      ))}
    </SegmentedChoice.Root>
  )
}

/** 手改过配置的值不在预设里时，高亮最接近的一档 */
export function nearest(v: number, options: [string, string][]) {
  let best = options[0][0]
  for (const [o] of options) if (Math.abs(Number(o) - v) < Math.abs(Number(best) - v)) best = o
  return best
}

/** 点两次才执行（删除、移除）：第一次变成「确认…」，3 秒不点就复原 */
export function useConfirm(): [boolean, () => boolean] {
  const [armed, setArmed] = useState(false)
  useEffect(() => {
    if (!armed) return
    const t = setTimeout(() => setArmed(false), 3000)
    return () => clearTimeout(t)
  }, [armed])
  return [
    armed,
    () => {
      if (armed) return true
      setArmed(true)
      return false
    },
  ]
}
