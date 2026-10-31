import { useEffect, useState } from 'react'
import { send } from './bridge'
import type { ApprovalDecision, ApprovalShow } from './types'

const kindLabel: Record<ApprovalShow['kind'], string> = { command: '命令', fileChange: '文件', network: '联网', tool: '工具' }

/** The oldest open approval of this node; the turn waits until it is answered. */
export function ApprovalCard({ approval, queued, onAnswer }: { approval: ApprovalShow; queued: number; onAnswer(id: string): void }) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => { const t = window.setInterval(() => setNow(Date.now()), 1000); return () => window.clearInterval(t) }, [])
  const left = Math.max(0, Math.round((approval.expiresAt - now) / 1000))
  const answer = (decision: ApprovalDecision) => { send({ type: 'approval.answer', id: approval.id, decision }); onAnswer(approval.id) }
  return (
    <section className="approval-card" role="alertdialog" aria-label={`等你确认：${approval.title}`}>
      <div className="approval-head">
        <span className="approval-kind">{kindLabel[approval.kind]}</span>
        <strong>{approval.title}</strong>
        <span className="spacer" />
        <span className="sub" title="到时没有回答就拒绝">{left} 秒后拒绝</span>
      </div>
      {approval.command && <pre className="approval-command">{approval.command}</pre>}
      {approval.cwd && <div className="sub approval-meta">工作目录：{approval.cwd}</div>}
      {approval.files.length > 0 && <div className="sub approval-meta">{approval.files.join('、')}</div>}
      {approval.diff && <pre className="approval-diff">{approval.diff.split('\n').map((line, i) => (
        <span key={i} className={line.startsWith('+') ? 'add' : line.startsWith('-') ? 'del' : undefined}>{line}{'\n'}</span>
      ))}</pre>}
      {approval.reason && <div className="approval-reason">理由：{approval.reason}</div>}
      <div className="approval-actions">
        <button className="btn danger" onClick={() => answer('deny')}>拒绝</button>
        <span className="spacer" />
        <button className="btn" onClick={() => answer('once')}>允许一次</button>
        <button className="btn primary" title={approval.sessionScope ? `本会话内都允许：${approval.sessionScope}` : undefined} onClick={() => answer('conversation')}>本会话内都允许</button>
      </div>
      {(approval.sessionScope || queued > 0) && (
        <div className="sub approval-foot">
          {approval.sessionScope && <span>“本会话内都允许”只包括{approval.sessionScope}。</span>}
          {queued > 0 && <span>后面还有 {queued} 个等你确认。</span>}
        </div>
      )}
    </section>
  )
}
