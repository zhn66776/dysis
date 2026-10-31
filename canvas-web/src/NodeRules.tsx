import { useEffect, useState } from 'react'
import { send } from './bridge'
import { nodeRulesLabel } from './rules'
import type { SessionSummary } from './types'

/** The node's own rules (third layer), sent after the global ones on every turn. */
export function NodeRules({ summary, locked }: { summary: SessionSummary; locked: boolean }) {
  const [open, setOpen] = useState(false)
  const [text, setText] = useState(summary.rules ?? '')
  useEffect(() => { if (!open) setText(summary.rules ?? '') }, [summary.rules, open])
  const save = () => { send({ type: 'session.setRules', sessionID: summary.id, text }); setOpen(false) }
  return <span className="node-rules">
    <button className={`act${summary.rules ? ' on' : ''}`} title="只对这个节点生效的规则，例如“只改 src/api/”" onClick={() => setOpen(v => !v)}>{nodeRulesLabel(summary.rules)}</button>
    {open && <div className="node-rules-pop" role="dialog" aria-label="节点规则" onKeyDown={e => { e.stopPropagation(); if (e.key === 'Escape') setOpen(false) }}>
      <div className="sub">只对这个节点生效，排在全局规则和项目规则后面。下一轮发送时生效。</div>
      <textarea autoFocus rows={5} value={text} placeholder="例如：只改 src/api/ 下的文件。" onChange={e => setText(e.target.value)} />
      <div className="row"><span className="spacer" /><button className="btn" onClick={() => setOpen(false)}>取消</button><button className="btn primary" disabled={locked} title={locked ? '回复结束后再改' : undefined} onClick={save}>保存</button></div>
    </div>}
  </span>
}
