import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  Background, BackgroundVariant, Controls, MarkerType, ReactFlow, useReactFlow,
  applyEdgeChanges, applyNodeChanges,
  type Edge, type EdgeChange, type NodeChange, type OnBeforeDelete, type OnConnectEnd, type Viewport,
} from '@xyflow/react'
import { send } from './bridge'
import { ChatNode, type ChatFlowNode } from './ChatNode'
import { SourceNode, type SourceFlowNode } from './SourceNode'
import { Dropdown } from './Controls'
import { ProviderMark, providerColor, providerName, providers } from './providers'
import type { AppState, MergeTemplate, Provider } from './types'

const templates: { id: MergeTemplate; label: string; hint: string }[] = [
  { id: 'compare', label: '对比', hint: '列出优缺点和适用场景，给出推荐' },
  { id: 'summarize', label: '汇总', hint: '合并成一份结论，标出矛盾' },
  { id: 'critique', label: '挑错', hint: '找错误、漏洞和风险，按严重程度排序' },
]

const nodeTypes = { chat: ChatNode, source: SourceNode }

type FlowNode = ChatFlowNode | SourceFlowNode

interface Menu { clientX: number; clientY: number; connectFrom?: string }

export function Canvas({ state, selectedNodeID, onSelect }: { state: AppState; selectedNodeID: string | null; onSelect(id: string | null): void }) {
  const board = state.board!
  const flow = useReactFlow()
  const wrapper = useRef<HTMLDivElement>(null)
  const [nodes, setNodes] = useState<FlowNode[]>([])
  const [edges, setEdges] = useState<Edge[]>([])
  const [menu, setMenu] = useState<Menu | null>(null)
  const [mergeProvider, setMergeProvider] = useState<Provider>('claude')
  // Nodes picked for merging: ⌘/Shift/Ctrl-click toggles, a box selection replaces.
  const [picked, setPicked] = useState<string[]>([])

  const runningChain = state.chain.total > 0 && state.chain.boardID === board.id ? state.chain : null

  // Swift owns the layout. Rebuild from each payload, but keep the local
  // position of a node while it is being dragged so streaming ticks do not
  // snap it back. Selection stays local so multi-selection survives updates.
  useEffect(() => {
    setNodes(prev => {
      const old = new Map(prev.map(n => [n.id, n]))
      return board.nodes.map((n): FlowNode => {
        const p = old.get(n.id)
        // Keep React Flow's own fields (measured size) so edges stay drawn.
        const base = {
          ...p,
          id: n.id,
          position: p?.dragging ? p.position : { x: n.x, y: n.y },
          selected: p ? p.selected : n.id === selectedNodeID,
        }
        const onDownstream = () => send({ type: 'chain.downstream', boardID: board.id, nodeID: n.id })
        if (n.source) return { ...base, type: 'source', data: { source: n.source, downstream: n.downstream, onDownstream } }
        return {
          ...base, type: 'chat',
          data: {
            summary: state.summaries[n.sessionID], inherited: Boolean(n.inherited), nativeFork: n.inherited?.mode === 'native',
            merge: n.merge, stale: n.stale, downstream: n.downstream, chainCurrent: runningChain?.currentNodeID === n.id,
            picked: picked.includes(n.id),
            onDownstream,
          },
        }
      })
    })
  }, [board.nodes, board.id, state.summaries, selectedNodeID, runningChain?.currentNodeID, picked])

  // A node Swift just created (create, branch, merge) becomes the only selection.
  const focus = state.focusNodeID
  useEffect(() => {
    if (!focus) return
    setNodes(ns => ns.map(n => ({ ...n, selected: n.id === focus })))
    // Bring it into view once the panel has taken its width.
    const target = board.nodes.find(n => n.id === focus)
    if (target) window.setTimeout(() => flow.setCenter(target.x + 120, target.y + 65, { zoom: flow.getZoom(), duration: 300 }), 80)
  }, [focus])

  // Only conversations can be merged; files and MCP nodes stay upstream.
  const selectedIDs = picked.filter(id => board.nodes.some(n => n.id === id && !n.source && state.summaries[n.sessionID]))
  const merge = (template: MergeTemplate) => {
    send({ type: 'node.merge', boardID: board.id, nodeIDs: selectedIDs, provider: mergeProvider, template })
    setPicked([])
  }

  const sessionOfNode = useMemo(() => new Map(board.nodes.map(n => [n.id, n.sessionID])), [board.nodes])
  // Files and MCP nodes only feed data edges; they never take one.
  const sourceIDs = useMemo(() => new Set(board.nodes.filter(n => n.source).map(n => n.id)), [board.nodes])

  // Native asks what is under a file drop (page CSS px) and where the visible
  // middle is; the page never sees the files themselves.
  useEffect(() => {
    const host = window.agentDesk!
    host.dropTarget = (x, y) => {
      const el = document.elementFromPoint(x, y)
      const zone = el?.closest<HTMLElement>('[data-drop]')
      if (zone?.dataset.drop === 'panel') return { kind: 'panel' }
      if (zone?.dataset.drop === 'source') return { kind: 'source', nodeID: zone.dataset.nodeId }
      const nodeID = el?.closest<HTMLElement>('.react-flow__node')?.dataset.id
      if (nodeID && board.nodes.find(n => n.id === nodeID)?.source?.kind === 'files') return { kind: 'source', nodeID }
      if (!el?.closest('.canvas')) return { kind: 'none' }
      const p = flow.screenToFlowPosition({ x, y })
      return { kind: 'canvas', x: Math.round(p.x - 120), y: Math.round(p.y - 40) }
    }
    host.viewCenter = () => {
      const r = wrapper.current?.getBoundingClientRect()
      if (!r) return null
      const p = flow.screenToFlowPosition({ x: r.left + r.width / 2, y: r.top + r.height / 2 })
      return { x: Math.round(p.x - 120), y: Math.round(p.y - 65) }
    }
    return () => { delete host.dropTarget; delete host.viewCenter }
  }, [board.nodes, flow])

  useEffect(() => {
    setEdges(prev => {
      const selected = new Set(prev.filter(e => e.selected).map(e => e.id))
      return board.edges.map(e => {
        const sourceProvider = state.summaries[sessionOfNode.get(e.source) ?? '']?.provider
        const targetRunning = state.running.has(sessionOfNode.get(e.target) ?? '')
        const inherit = e.kind === 'inherit'
        return {
          id: e.id, source: e.source, target: e.target,
          selected: selected.has(e.id),
          animated: targetRunning,
          className: `edge-${e.kind}${e.pending ? ' edge-pending' : ''}`,
          style: inherit
            ? { stroke: sourceProvider ? providerColor[sourceProvider] : 'var(--edge-data)', strokeWidth: 3 }
            : { stroke: 'var(--edge-data)', strokeWidth: 1.4 },
          markerEnd: inherit ? undefined : { type: MarkerType.ArrowClosed, color: 'var(--edge-data)', width: 16, height: 16 },
        }
      })
    })
  }, [board.edges, state.summaries, state.running, sessionOfNode])

  const onNodesChange = useCallback((changes: NodeChange<FlowNode>[]) => {
    // Removal goes through Swift (native confirmation); apply the rest locally.
    setNodes(ns => applyNodeChanges(changes.filter(c => c.type !== 'remove'), ns))
  }, [])
  const onEdgesChange = useCallback((changes: EdgeChange[]) => {
    setEdges(es => applyEdgeChanges(changes.filter(c => c.type !== 'remove'), es))
  }, [])

  const onBeforeDelete: OnBeforeDelete<FlowNode> = useCallback(async ({ nodes: ns, edges: es }) => {
    const nodeIDs = ns.map(n => n.id)
    const edgeIDs = es.filter(e => !nodeIDs.includes(e.source) && !nodeIDs.includes(e.target)).map(e => e.id)
    if (nodeIDs.length) send({ type: 'node.delete', boardID: board.id, nodeIDs })
    if (edgeIDs.length) send({ type: 'edge.delete', boardID: board.id, edgeIDs })
    return false
  }, [board.id])

  const onConnectEnd: OnConnectEnd = useCallback((event, connection) => {
    if (connection.isValid || !connection.fromNode || connection.fromHandle?.type !== 'source') return
    const point = 'changedTouches' in event ? event.changedTouches[0] : event
    setMenu({ clientX: point.clientX, clientY: point.clientY, connectFrom: connection.fromNode.id })
  }, [])

  const saveViewport = useRef<number>(0)
  const onMoveEnd = useCallback((_: unknown, v: Viewport) => {
    window.clearTimeout(saveViewport.current)
    saveViewport.current = window.setTimeout(() => send({ type: 'viewport.save', boardID: board.id, x: v.x, y: v.y, zoom: v.zoom }), 400)
  }, [board.id])

  const create = (provider: Provider) => {
    if (!menu) return
    const p = flow.screenToFlowPosition({ x: menu.clientX, y: menu.clientY })
    send({ type: 'node.create', boardID: board.id, provider, x: Math.round(p.x), y: Math.round(p.y - 40), connectFrom: menu.connectFrom })
    setMenu(null)
  }
  const createFiles = () => {
    if (!menu) return
    const p = flow.screenToFlowPosition({ x: menu.clientX, y: menu.clientY })
    send({ type: 'source.createFiles', boardID: board.id, x: Math.round(p.x), y: Math.round(p.y - 40) })
    setMenu(null)
  }

  const openMenuAtCenter = () => {
    const r = wrapper.current?.getBoundingClientRect()
    if (r) setMenu({ clientX: r.left + r.width / 2 - 120, clientY: r.top + r.height / 2 - 60 })
  }

  const wrapperRect = wrapper.current?.getBoundingClientRect()

  return (
    <div
      className="canvas"
      ref={wrapper}
      onDoubleClick={e => {
        if ((e.target as HTMLElement).classList.contains('react-flow__pane')) setMenu({ clientX: e.clientX, clientY: e.clientY })
      }}
    >
      <ReactFlow
        key={board.id}
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        onBeforeDelete={onBeforeDelete}
        onConnect={c => send({ type: 'edge.create', boardID: board.id, source: c.source, target: c.target })}
        onConnectEnd={onConnectEnd}
        isValidConnection={c => c.source !== c.target && !sourceIDs.has(c.target)}
        onNodeClick={(e, n) => {
          setMenu(null)
          if (e.metaKey || e.shiftKey || e.ctrlKey) {
            setPicked(p => {
              const base = p.length ? p : selectedNodeID ? [selectedNodeID] : []
              return base.includes(n.id) ? base.filter(id => id !== n.id) : [...base, n.id]
            })
          } else {
            setPicked([])
            onSelect(n.id)
          }
        }}
        onSelectionChange={({ nodes: ns }) => { if (ns.length >= 2) setPicked(ns.map(n => n.id)) }}
        onPaneClick={() => { onSelect(null); setMenu(null); setPicked([]) }}
        onNodeDragStop={(_, __, dragged) => send({ type: 'node.move', boardID: board.id, positions: dragged.map(n => ({ nodeID: n.id, x: Math.round(n.position.x), y: Math.round(n.position.y) })) })}
        onMoveEnd={onMoveEnd}
        defaultViewport={board.viewport}
        fitView={!board.viewport}
        fitViewOptions={{ maxZoom: 1, padding: 0.3 }}
        minZoom={0.2}
        maxZoom={2}
        zoomOnDoubleClick={false}
        deleteKeyCode={['Backspace', 'Delete']}
        proOptions={{ hideAttribution: true }}
      >
        <Background variant={BackgroundVariant.Dots} gap={18} size={1.2} color="var(--dot)" />
        <Controls showInteractive={false} position="bottom-left" />
      </ReactFlow>

      <div className="canvas-top" data-drag>
        <span className="canvas-title">{board.title}</span>
        <span className="spacer" />
        {selectedIDs.length >= 2 && (
          <div className="merge-bar">
            <span className="muted">已选 {selectedIDs.length} 个</span>
            <span className="merge-label">合并结论，用</span>
            <Dropdown
              className="picker"
              label={<span className="merge-provider"><ProviderMark provider={mergeProvider} size={14} />{providerName[mergeProvider]}</span>}
              items={providers.map(p => ({ key: p, label: providerName[p], checked: p === mergeProvider, onSelect: () => setMergeProvider(p) }))}
            />
            {templates.map(t => (
              <button key={t.id} className="btn merge-btn" title={`${t.hint}。会新建一个节点并连好数据线，确认提示词后再发送（1 次调用）`} onClick={() => merge(t.id)}>{t.label}</button>
            ))}
          </div>
        )}
        {runningChain && (
          <div className="chain-bar">
            <span>正在重跑 {Math.min(runningChain.index + 1, runningChain.total)} / {runningChain.total}</span>
            <span className="muted">{state.summaries[board.nodes.find(n => n.id === runningChain.currentNodeID)?.sessionID ?? '']?.title}</span>
            <button className="btn" onClick={() => send({ type: 'chain.stop' })}>停止</button>
          </div>
        )}
        {state.running.size > 0 && <span className="running-count">{state.running.size} 个节点运行中</span>}
        <button className="btn" onClick={openMenuAtCenter}>＋ 新节点</button>
      </div>

      {board.nodes.length > 1 && selectedIDs.length < 2 && !runningChain && (
        <div className="canvas-hint">⌘ 点选或 Shift 拖动框选多个节点，可以合并结论</div>
      )}

      {board.nodes.length === 0 && (
        <div className="canvas-empty">
          <div className="empty-title">从一个节点开始</div>
          <div>双击空白处，或点右上角“新节点”。一个节点就是一段对话；把文件拖到这里会变成文件节点。</div>
        </div>
      )}

      {menu && wrapperRect && (
        <div className="menu" style={{ left: menu.clientX - wrapperRect.left, top: menu.clientY - wrapperRect.top }} onDoubleClick={e => e.stopPropagation()}>
          <div className="menu-label">{menu.connectFrom ? '新建下游节点（连数据线）' : '新建节点'}</div>
          {providers.map(p => (
            <button key={p} className="menu-item" onClick={() => create(p)}>
              <ProviderMark provider={p} size={16} />{providerName[p]}
            </button>
          ))}
          {!menu.connectFrom && (
            <>
              <div className="menu-label menu-sep">只读资料（用数据线连到多个对话）</div>
              <button className="menu-item" onClick={createFiles}><span className="source-kind">文件</span>文件…</button>
              <button className="menu-item" title="在 MCP 工作台运行工具，再选“放到画布上”" onClick={() => { send({ type: 'app.open', window: 'mcp' }); setMenu(null) }}>
                <span className="source-kind">MCP</span>MCP 结果…
              </button>
            </>
          )}
        </div>
      )}
    </div>
  )
}
