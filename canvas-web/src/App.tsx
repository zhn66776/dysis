import { useEffect, useReducer, useState } from 'react'
import { ReactFlowProvider } from '@xyflow/react'
import { isNative, send, subscribe } from './bridge'
import { Canvas } from './Canvas'
import { ChatPanel } from './ChatPanel'
import { Sidebar } from './Sidebar'
import { applyState, initialState } from './store'
import type { AppState, StatePayload } from './types'

export function App() {
  const [state, dispatch] = useReducer((s: AppState, p: StatePayload) => applyState(s, p), initialState)
  const [selectedNodeID, setSelectedNodeID] = useState<string | null>(null)
  const [drafts, setDrafts] = useState<Record<string, string>>({})
  const [collapsed, setCollapsed] = useState(false)

  useEffect(() => {
    const off = subscribe(p => {
      if (p.type === 'state') dispatch(p)
      else if (p.type === 'composer.insert') setDrafts(d => ({ ...d, [p.sessionID]: (d[p.sessionID] ? d[p.sessionID] + '\n\n' : '') + p.text }))
    })
    send({ type: 'ready' })
    return off
  }, [])

  // Swift names the node to focus after creating or branching it.
  useEffect(() => { if (state.focusNodeID) setSelectedNodeID(state.focusNodeID) }, [state.focusNodeID])

  const node = state.board?.nodes.find(n => n.id === selectedNodeID)
  useEffect(() => { if (selectedNodeID && state.board && !node) setSelectedNodeID(null) }, [selectedNodeID, state.board, node])

  // Only the open conversation (and the parent it inherits from) gets full messages.
  const parentSession = node?.inherited ? state.board?.nodes.find(n => n.id === node.inherited!.fromNodeID)?.sessionID : undefined
  const watchKey = [node?.sessionID, parentSession].filter(Boolean).join(',')
  useEffect(() => { if (state.ready) send({ type: 'session.watch', sessionIDs: watchKey ? watchKey.split(',') : [] }) }, [watchKey, state.ready])

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

  if (!state.ready) return <div className="loading">正在载入…</div>

  return (
    <div className={`app${node ? ' with-panel' : ''}`}>
      <Sidebar state={state} collapsed={collapsed || Boolean(node)} onToggle={() => { setCollapsed(c => !c); if (node) setSelectedNodeID(null) }} />
      <main className="main">
        {state.error && (
          <div className="error-banner" role="alert">
            <span>{state.error}</span>
            <button className="icon-btn" aria-label="关闭提示" onClick={() => send({ type: 'error.dismiss' })}>✕</button>
          </div>
        )}
        {!isNative && <div className="preview-badge">浏览器预览 · 模拟数据，不调用模型</div>}
        {state.board && (
          <ReactFlowProvider>
            <Canvas state={state} selectedNodeID={selectedNodeID} onSelect={setSelectedNodeID} />
          </ReactFlowProvider>
        )}
      </main>
      {node && (
        <ChatPanel
          key={node.id}
          state={state}
          node={node}
          draft={drafts[node.sessionID] ?? ''}
          onDraft={t => setDrafts(d => ({ ...d, [node.sessionID]: t }))}
          onClose={() => setSelectedNodeID(null)}
        />
      )}
    </div>
  )
}
