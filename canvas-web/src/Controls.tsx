import { useEffect, useRef, useState, type ReactNode } from 'react'
import { send } from './bridge'
import type { AppState, Provider, Quota, SessionSummary } from './types'

export interface MenuItem { key: string; label: string; detail?: string; checked?: boolean; onSelect(): void }

/** Small popover menu anchored to its button; closes on outside click or Esc. */
export function Dropdown({ label, title, items, disabled, footer, align = 'left', className = '' }: {
  label: ReactNode; title?: string; items: MenuItem[]; disabled?: boolean; footer?: MenuItem; align?: 'left' | 'right'; className?: string
}) {
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent) => { if (!root.current?.contains(e.target as Node)) setOpen(false) }
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); setOpen(false) } }
    document.addEventListener('mousedown', close)
    document.addEventListener('keydown', esc, true)
    return () => { document.removeEventListener('mousedown', close); document.removeEventListener('keydown', esc, true) }
  }, [open])
  const pick = (item: MenuItem) => { item.onSelect(); setOpen(false) }
  return (
    <div className={`dropdown ${className}`} ref={root}>
      <button className="dd-button" title={title} disabled={disabled} onClick={() => setOpen(o => !o)}>
        {label}<span className="dd-caret">▾</span>
      </button>
      {open && (
        <div className={`dd-menu ${align}`}>
          {items.map(item => (
            <button key={item.key} className={`dd-item${item.checked ? ' checked' : ''}`} onClick={() => pick(item)}>
              <span className="dd-check">{item.checked ? '✓' : ''}</span>
              <span className="dd-label">{item.label}</span>
              {item.detail && <span className="dd-detail">{item.detail}</span>}
            </button>
          ))}
          {footer && (
            <>
              {items.length > 0 && <div className="dd-sep" />}
              <button className="dd-item footer" onClick={() => pick(footer)}><span className="dd-check" /><span className="dd-label">{footer.label}</span></button>
            </>
          )}
        </div>
      )}
    </div>
  )
}

const effortLabel: Record<string, string> = {
  none: '关闭', minimal: '最少', low: '低', medium: '中', high: '高', xhigh: '极高', max: '最大', ultra: '超高',
}
const isCursor = (p: Provider) => p === 'grok' || p === 'gemini'

export function ModelPicker({ state, summary, locked }: { state: AppState; summary: SessionSummary; locked: boolean }) {
  const options = state.models[summary.provider] ?? []
  const current = options.find(o => o.key === summary.modelKey)
  const items: MenuItem[] = options.map(o => ({
    key: o.key, label: o.label, detail: o.label === o.id ? undefined : o.id, checked: o.key === summary.modelKey,
    onSelect: () => { if (o.key !== summary.modelKey) send({ type: 'session.setModel', sessionID: summary.id, modelID: o.id }) },
  }))
  const footer: MenuItem | undefined = summary.provider === 'claude' ? undefined : {
    key: 'refresh', label: options.length ? '刷新模型列表' : '读取模型列表', onSelect: () => send({ type: 'provider.refresh', provider: summary.provider }),
  }
  return (
    <Dropdown
      className="picker"
      label={<span className="meta">{current?.label ?? (summary.modelID || '默认模型')}</span>}
      title={locked ? '回复结束后可以切换模型' : '下一条消息使用这个模型'}
      items={items} footer={footer} disabled={locked}
    />
  )
}

export function EffortPicker({ summary, locked }: { summary: SessionSummary; locked: boolean }) {
  const cursor = isCursor(summary.provider)
  const set = (effort: string | null) => send({ type: 'session.setEffort', sessionID: summary.id, effort })
  const items: MenuItem[] = [
    ...(cursor ? [] : [{ key: '__default', label: '官方默认', checked: !summary.effort, onSelect: () => set(null) }]),
    ...summary.effortChoices.map(e => ({ key: e, label: effortLabel[e] ?? e, detail: e, checked: summary.effort === e, onSelect: () => set(e) })),
  ]
  const footer: MenuItem | undefined = summary.provider === 'claude' ? undefined : {
    key: 'refresh', label: summary.effortChoices.length ? '刷新可用档位' : '读取可用档位', onSelect: () => send({ type: 'provider.refresh', provider: summary.provider }),
  }
  const label = summary.effort ? `推理 ${effortLabel[summary.effort] ?? summary.effort}` : (cursor ? '推理 —' : '推理 默认')
  return (
    <Dropdown
      className="picker"
      label={label}
      title={cursor ? '切换同一模型的推理档位（Cursor 用不同的模型 ID 表示档位）' : '下一条消息使用这个推理强度'}
      items={items} footer={footer} disabled={locked}
    />
  )
}

const compact = (n: number) => n >= 1_000_000 ? `${(n / 1_000_000).toFixed(n >= 10_000_000 ? 0 : 1)}M` : n >= 1000 ? `${(n / 1000).toFixed(n >= 100_000 ? 0 : 1)}k` : String(n)

function Meter({ fraction, tone }: { fraction: number; tone: 'ok' | 'warn' | 'bad' }) {
  return <span className={`meter meter-${tone}`}><span style={{ width: `${Math.max(2, Math.min(100, fraction * 100))}%` }} /></span>
}

export function ContextMeter({ summary }: { summary: SessionSummary }) {
  if (summary.contextUsed == null) {
    const why = isCursor(summary.provider) ? 'Cursor 不提供上下文用量' : '回复后显示这段对话占用的上下文'
    return <span className="usage muted" title={why}>上下文 —</span>
  }
  const window = summary.contextWindow
  const fraction = window ? summary.contextUsed / window : 0
  const tone = fraction > 0.9 ? 'bad' : fraction > 0.75 ? 'warn' : 'ok'
  return (
    <span className="usage" title={window ? `最近一次回复后，上下文占用 ${summary.contextUsed.toLocaleString()} / ${window.toLocaleString()} tokens（${Math.round(fraction * 100)}%）` : `最近一次回复后，上下文占用 ${summary.contextUsed.toLocaleString()} tokens`}>
      <span className="usage-label">上下文</span>
      {window && <Meter fraction={fraction} tone={tone} />}
      <span className="meta">{compact(summary.contextUsed)}{window ? ` / ${compact(window)}` : ''}</span>
    </span>
  )
}

const resetText = (ms?: number) => {
  if (!ms) return ''
  const mins = Math.round((ms - Date.now()) / 60000)
  if (mins <= 0) return '，已到重置时间'
  if (mins < 60) return `，${mins} 分钟后重置`
  if (mins < 60 * 48) return `，${Math.round(mins / 60)} 小时后重置`
  return `，${Math.round(mins / 1440)} 天后重置`
}

export function QuotaMeter({ provider, quota }: { provider: Provider; quota?: Quota }) {
  if (!quota || quota.windows.length === 0) {
    const why = isCursor(provider) ? 'Cursor CLI 不提供订阅额度数据'
      : provider === 'claude' ? (quota?.status === 'allowed_warning' ? 'Claude Code 提示额度接近上限' : 'Claude Code 在回复时报告额度，回复后显示')
      : '正在通过 Codex 读取额度（不发起模型回合）'
    return <span className={`usage muted${quota?.status === 'allowed_warning' || quota?.status === 'rejected' ? ' warn-text' : ''}`} title={why}>额度 {quota?.status === 'rejected' ? '已用尽' : '—'}</span>
  }
  // The tightest window decides what's left right now.
  const tightest = quota.windows.reduce((a, b) => (b.usedPercent > a.usedPercent ? b : a))
  const left = Math.max(0, 100 - tightest.usedPercent)
  const tone = left < 10 ? 'bad' : left < 25 ? 'warn' : 'ok'
  const detail = quota.windows.map(w => `${w.label}：已用 ${Math.round(w.usedPercent)}%${resetText(w.resetsAt)}`).join('\n')
  return (
    <span className="usage" title={`订阅额度（${new Date(quota.updatedAt).toLocaleTimeString()} 更新）\n${detail}`}>
      <span className="usage-label">{tightest.label}剩余</span>
      <Meter fraction={left / 100} tone={tone} />
      <span className="meta">{Math.round(left)}%</span>
    </span>
  )
}
