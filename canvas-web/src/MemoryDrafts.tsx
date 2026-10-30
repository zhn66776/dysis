import { useState } from 'react'
import { send } from './bridge'
import { memoryOverBudget, memorySummary } from './memory'
import type { MemoryDraft, MemoryPayload } from './types'

/** Drafts for the project memory: written only when the user saves them. */
export function MemoryDrafts({ memory, boardID }: { memory: MemoryPayload; boardID: string }) {
  if (!memory.available || (memory.drafts.length === 0 && !memoryOverBudget(memory))) return null
  return <section className="memory-drafts">
    <div className="memory-head">
      <span className="sub">{memorySummary(memory)}</span>
      <button className="act" onClick={() => send({ type: 'app.open', window: 'project', boardID })}>管理…</button>
    </div>
    {memoryOverBudget(memory) && <div className="memory-warn">项目记忆超过 {memory.budget.toLocaleString('zh-CN')} 字，每轮都要带上它。请在项目设置里删掉过时的条目；AgentDesk 不会自动删除。</div>}
    {memory.drafts.map(d => <Draft key={d.id} draft={d} />)}
  </section>
}

function Draft({ draft }: { draft: MemoryDraft }) {
  const [text, setText] = useState(draft.text)
  return <div className="memory-draft">
    <div className="sub">{draft.fromModel ? `${draft.author} 建议记住` : '记住这个'}{draft.reason ? `：${draft.reason}` : ''}</div>
    <textarea rows={3} value={text} onChange={e => setText(e.target.value)} onKeyDown={e => e.stopPropagation()} />
    <div className="sub">{text.trim().length} 字 · 保存后这个项目的所有对话都会读到</div>
    <div className="row">
      <span className="spacer" />
      <button className="btn" onClick={() => send({ type: 'memory.discard', id: draft.id })}>丢弃</button>
      <button className="btn primary" disabled={!text.trim()} onClick={() => send({ type: 'memory.confirm', id: draft.id, text })}>保存到项目记忆</button>
    </div>
  </div>
}
