import { useEffect, useRef, useState } from 'react'
import { send, subscribe } from './bridge'
import type { ContextPreview } from './types'
import { ruleSourceLine } from './rules'

export function ContextInspector({ boardID, nodeID, draft, onClose }: { boardID: string; nodeID: string; draft: string; onClose(): void }) {
  const [preview, setPreview] = useState<ContextPreview | null>(null)
  const request = useRef('')
  const root = useRef<HTMLDivElement>(null)
  const refresh = () => {
    request.current = crypto.randomUUID().toUpperCase()
    setPreview(null)
    send({ type: 'context.preview', boardID, nodeID, text: draft, id: request.current })
  }
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null
    const off = subscribe(p => { if (p.type === 'context.preview' && p.id === request.current && p.nodeID === nodeID) setPreview(p) })
    refresh()
    root.current?.focus()
    return () => { off(); previous?.focus() }
  }, [])
  return <div className="modal-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) onClose() }}>
    <div ref={root} className="context-modal" role="dialog" aria-modal="true" aria-label="本轮上下文预览" tabIndex={-1} onKeyDown={e => {
      e.stopPropagation()
      if (e.key === 'Escape') { e.preventDefault(); onClose() }
      if (e.key === 'Tab') {
        const buttons = root.current?.querySelectorAll<HTMLButtonElement>('button')
        if (buttons?.length) {
          const first = buttons[0], last = buttons[buttons.length - 1]
          if (e.shiftKey && (document.activeElement === first || document.activeElement === root.current)) { e.preventDefault(); last.focus() }
          else if (!e.shiftKey && (document.activeElement === last || document.activeElement === root.current)) { e.preventDefault(); first.focus() }
        }
      }
    }}>
      <header><div><strong>本轮上下文预览</strong><div className="sub">本地读取 · 不调用模型</div></div><button className="icon-btn" aria-label="关闭上下文预览" onClick={onClose}>✕</button></header>
      {preview?.harness && preview.harness.length > 0 && (
        <section className="harness-settings" aria-label="本轮的 harness 设置">
          <div className="harness-title">本轮的 harness 设置 <span className="sub">只读</span></div>
          {preview.harness.map(line => <div key={line} className="harness-line">{line}</div>)}
        </section>
      )}
      <div className="context-notes">{preview?.notes.map(n => <p key={n}>{n}</p>)}</div>
      {preview && <RuleSources preview={preview} />}
      <pre className="context-input">{preview?.text ?? '正在读取本轮输入…'}</pre>
      <footer><span className="sub">文字输入包含文档提取内容；原生会话历史与图片另行传入。</span><button className="btn" onClick={refresh}>刷新预览</button></footer>
    </div>
  </div>
}

/** The rule layers active this turn, with their sizes; the injected text on demand. */
function RuleSources({ preview }: { preview: ContextPreview }) {
  const rules = preview.rules ?? []
  return <section className="rule-sources">
    <div className="sub">本轮生效的规则{preview.rulesChannel ? ` · 注入到 ${preview.rulesChannel}` : ''}</div>
    {rules.length === 0 ? <p className="muted">没有生效的规则。可以在设置里写全局规则，在项目设置里写 AGENTS.md，或给这个节点加规则。</p>
      : <ul>{rules.map(r => <li key={r.title + (r.path ?? '')}>{ruleSourceLine(r)}</li>)}</ul>}
    {preview.rulesText && <details><summary>查看注入的规则全文</summary><pre className="context-input">{preview.rulesText}</pre></details>}
  </section>
}
