import { useCallback, useEffect, useReducer, useState } from 'react'
import { ReactFlowProvider } from '@xyflow/react'
import { isNative, send, subscribe } from './bridge'
import { Canvas } from './Canvas'
import { ChatPanel } from './ChatPanel'
import { ConfirmDialog } from './ConfirmDialog'
import { applyChrome } from './chrome'
import { approvalsFor, enqueueApproval, resolveApproval } from './harness'
import { Sidebar } from './Sidebar'
import { SourcePanel } from './SourcePanel'
import { toggleExpanded, watchedSessions } from './interactions'
import { applyState, enqueueConfirm, initialState, resolveConfirm } from './store'
import type { AppState, ApprovalShow, ConfirmShow, StatePayload } from './types'

export function App() {
  const [state, dispatch] = useReducer((s: AppState, p: StatePayload) => applyState(s, p), initialState)
  const [selectedNodeID, setSelectedNodeID] = useState<string | null>(null)
  const [drafts, setDrafts] = useState<Record<string, string>>({})
  const [expanded, setExpanded] = useState<string[]>([])
  const [composerFocus, setComposerFocus] = useState(0)
  const [messageFocus, setMessageFocus] = useState<{nodeID: string; messageID?: string; request: number} | null>(null)
  const [collapsed, setCollapsed] = useState(false)
  const [confirms, setConfirms] = useState<ConfirmShow[]>([])
  const [approvals, setApprovals] = useState<ApprovalShow[]>([])

  useEffect(() => {
    const off = subscribe(p => {
      if (p.type === 'state') dispatch(p)
      else if (p.type === 'composer.insert') setDrafts(d => ({ ...d, [p.sessionID]: (d[p.sessionID] ? d[p.sessionID] + '\n\n' : '') + p.text }))
      else if (p.type === 'confirm.show') setConfirms(q => enqueueConfirm(q, p))
      else if (p.type === 'approval.show') setApprovals(q => enqueueApproval(q, p))
      else if (p.type === 'approval.hide') setApprovals(q => resolveApproval(q, p.id))
      else if (p.type === 'chrome') applyChrome(p)
    })
    send({ type: 'ready' })
    return off
  }, [])

  // Swift names the node to focus after creating or branching it.
  useEffect(() => { if (state.focusNodeID) setSelectedNodeID(state.focusNodeID) }, [state.focusNodeID])

  const node = state.board?.nodes.find(n => n.id === selectedNodeID)
  useEffect(() => { if (selectedNodeID && state.board && !node) setSelectedNodeID(null) }, [selectedNodeID, state.board, node])

  const watchKey = watchedSessions(state, selectedNodeID, expanded).join(',')
  useEffect(() => {
    if (state.ready) send({ type: 'session.watch', sessionIDs: watchKey ? watchKey.split(',') : [], panelSessionID: node?.sessionID })
  }, [watchKey, state.ready, node?.sessionID])
  const followUp = (id: string) => { setSelectedNodeID(id); setComposerFocus(n => n + 1); setMessageFocus(null) }

  // Esc closes the panel unless a field or menu is handling it.
  useEffect(() => {
    if (!node) return
    const onKey = (e: KeyboardEvent) => {
      const field = (e.target as HTMLElement | null)?.closest('input, textarea')
      if (e.key === 'Escape' && !e.isComposing && !field) setSelectedNodeID(null)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [node])

  const confirm = confirms[0]
  const answer = useCallback((ok: boolean, checked?: boolean) => {
    if (!confirm) return
    send({ type: 'confirm.answer', id: confirm.id, ok, checked })
    setConfirms(q => resolveConfirm(q, confirm.id))
  }, [confirm])

  if (!state.ready) return <div className="loading">正在载入…</div>

  return (
    <div className={`app${node ? ' with-panel' : ''}${collapsed || node ? ' rail-shown' : ''}`}>
      <Sidebar state={state} collapsed={collapsed || Boolean(node)} onToggle={() => { setCollapsed(c => !c); if (node) setSelectedNodeID(null) }} />
      <main className="main">
        {state.error && (
          <div className="error-banner" role="alert">
            <span>{state.error}</span>
            <button className="icon-btn" aria-label="关闭提示" onClick={() => send({ type: 'error.dismiss' })}>✕</button>
          </div>
        )}
        {state.notice && !state.error && (
          <div className="notice-banner" role="status">
            <span>{state.notice}</span>
            <button className="icon-btn" aria-label="关闭提示" onClick={() => send({ type: 'notice.dismiss' })}>✕</button>
          </div>
        )}
        {!isNative && <div className="preview-badge">浏览器预览 · 模拟数据，不调用模型</div>}
        {state.board && (
          <ReactFlowProvider key={state.board.id}>
            <Canvas state={state} selectedNodeID={selectedNodeID} onSelect={id => { setSelectedNodeID(id); setMessageFocus(null) }}
              expanded={expanded} onExpand={id => setExpanded(ids => toggleExpanded(ids, id, state.board!.nodes.map(n => n.id)))}
              onFollowUp={followUp} onLocate={hit => { setSelectedNodeID(hit.nodeID); setMessageFocus({ ...hit, request: Date.now() }) }} />
          </ReactFlowProvider>
        )}
      </main>
      {node?.source && <SourcePanel key={node.id} state={state} node={node} source={node.source} onClose={() => setSelectedNodeID(null)} />}
      {node && !node.source && (
        <ChatPanel
          key={node.id}
          state={state}
          node={node}
          composerFocus={composerFocus}
          messageFocus={messageFocus?.nodeID === node.id ? messageFocus : null}
          draft={drafts[node.sessionID] ?? ''}
          approvals={approvalsFor(approvals, node.sessionID)}
          onApprovalAnswered={id => setApprovals(q => resolveApproval(q, id))}
          onDraft={t => setDrafts(d => ({ ...d, [node.sessionID]: t }))}
          onClose={() => setSelectedNodeID(null)}
        />
      )}
      {confirm && <ConfirmDialog key={confirm.id} request={confirm} onAnswer={answer} />}
    </div>
  )
}
