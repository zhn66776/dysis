import { useState } from 'react'
import { send } from './bridge'
import { fileStats, formatBytes, formatStamp, kindLabel } from './sources'
import type { AppState, NodePayload, SourcePayload } from './types'

const maxFiles = 6

/** Panel for a files or MCP result node: read-only content, no composer, no model. */
export function SourcePanel({ state, node, source, onClose }: { state: AppState; node: NodePayload; source: SourcePayload; onClose(): void }) {
  const board = state.board!
  const [renaming, setRenaming] = useState(false)
  const targets = board.edges.filter(e => e.kind === 'data' && e.source === node.id).map(e => {
    const target = board.nodes.find(n => n.id === e.target)
    return { edge: e, summary: target ? state.summaries[target.sessionID] : undefined }
  })

  return (
    <aside className="panel source-panel" data-drop={source.kind === 'files' ? 'source' : undefined} data-node-id={node.id}
      onKeyDown={e => { if (e.key === 'Escape' && !e.nativeEvent.isComposing) onClose() }}>
      <header className="panel-head">
        <div className="panel-title-row">
          <span className="source-kind">{source.kind === 'mcp' ? 'MCP' : '文件'}</span>
          {renaming ? (
            <input
              className="rename" autoFocus defaultValue={source.title}
              onBlur={e => { const t = e.target.value.trim(); if (t !== source.title) send({ type: 'source.rename', boardID: board.id, nodeID: node.id, title: t }); setRenaming(false) }}
              onKeyDown={e => { if (e.key === 'Enter' && !e.nativeEvent.isComposing) (e.target as HTMLInputElement).blur(); if (e.key === 'Escape') setRenaming(false) }}
            />
          ) : (
            <span className="panel-title" title="双击改名；清空名称会恢复自动名称" onDoubleClick={() => setRenaming(true)}>{source.title}</span>
          )}
          <button className="icon-btn" aria-label="关闭面板" onClick={onClose}>✕</button>
        </div>
        <div className="chips">
          <span className="chip">只读 · 不调用模型</span>
          {source.kind === 'files' && <span className="chip meta">{fileStats(source.files)}</span>}
          <span className="chip meta" title="内容变化时，连出的对话会标为已过期">更新于 {formatStamp(source.updatedAt)}</span>
        </div>
      </header>

      {node.downstream > 0 && (
        <div className="stale-banner neutral">
          <span>下游有 {node.downstream} 个节点还没用上这里的新内容。</span>
          <button className="btn" onClick={() => send({ type: 'chain.downstream', boardID: board.id, nodeID: node.id })}>重跑下游（{node.downstream} 次调用）</button>
        </div>
      )}

      <section className="lineage">
        <div className="upstream">
          <span className="sub">数据线输出</span>
          {targets.length === 0 && <span className="sub">还没有连线：从右侧输出口拖到对话节点上</span>}
          {targets.map(t => (
            <span key={t.edge.id} className={`chip p-${t.summary?.provider ?? 'claude'} tinted`} title={t.edge.pending ? '下一次发送时带上这里的当前内容' : '已送达当前内容'}>
              → {t.summary?.title ?? '未知节点'}{t.edge.pending ? ' · 待送达' : ' · 已送达'}
            </span>
          ))}
        </div>
      </section>

      <div className="messages source-body">
        {source.kind === 'files' ? (
          <>
            <div className="source-list">
              {source.files.map(f => (
                <div key={f.id} className="source-row">
                  <span className="file-kind">{kindLabel[f.kind]}</span>
                  <div className="source-row-main">
                    <div className="file-name">{f.name}</div>
                    <div className="sub">{formatBytes(f.bytes)}{f.note ? ` · ${f.note}` : ''}</div>
                  </div>
                  <button className="icon-btn" aria-label={`移除 ${f.name}`} disabled={source.importing}
                    onClick={() => send({ type: 'source.removeFile', boardID: board.id, nodeID: node.id, attachmentID: f.id })}>✕</button>
                </div>
              ))}
              {source.importing && <div className="source-row muted">正在读取文件…</div>}
            </div>
            <button className="btn" disabled={source.importing || source.files.length >= maxFiles} onClick={() => send({ type: 'source.addFiles', boardID: board.id, nodeID: node.id })}>＋ 添加文件…</button>
            <div className="sub">最多 6 个文件、4 张图片，单个不超过 20 MB；也可以把文件拖到这里。文档以提取的文字送到下游，图片作为图片输入（Cursor 不接收图片）。改动后，已回答过的下游节点会标为已过期。</div>
          </>
        ) : source.mcp ? (
          <>
            <dl className="source-meta">
              <dt>服务器</dt><dd>{source.mcp.serverName}</dd>
              <dt>工具</dt><dd className="meta">{source.mcp.toolName}</dd>
              <dt>调用时间</dt><dd className="meta">{formatStamp(source.mcp.calledAt)}</dd>
              <dt>参数</dt><dd><pre className="source-pre small">{source.mcp.arguments}</pre></dd>
            </dl>
            {source.mcp.isError && <div className="msg-note danger">工具返回了错误，下游会看到这条说明。</div>}
            <pre className="source-pre">{source.mcp.text}</pre>
            <button className="btn" onClick={() => send({ type: 'source.rerunMCP', boardID: board.id, nodeID: node.id })}>重新运行工具…</button>
            <div className="sub">打开 MCP 工作台并填好服务器、工具和参数；只有你在那里按“运行工具”才会调用。更新后，已回答过的下游节点会标为已过期。</div>
          </>
        ) : null}
      </div>
    </aside>
  )
}
