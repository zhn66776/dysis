import { memo } from 'react'
import { Handle, Position, type Node, type NodeProps } from '@xyflow/react'
import { fileStats, formatBytes, formatStamp, kindLabel, sourcePreview } from './sources'
import type { SourcePayload } from './types'

export type SourceNodeData = { source: SourcePayload; downstream?: number; onDownstream?(): void }
export type SourceFlowNode = Node<SourceNodeData, 'source'>

// Read-only material: a neutral header and only an output port, since a
// source can feed data edges but never receive one.
function SourceNodeView({ data, selected }: NodeProps<SourceFlowNode>) {
  const s = data.source
  const shown = s.files.slice(0, 3)
  return (
    <div className={`node source-node${selected ? ' selected' : ''}`}>
      <div className="node-head">
        <span className="source-kind">{s.kind === 'mcp' ? 'MCP' : '文件'}</span>
        <span className="node-title">{s.title}</span>
        <span className="node-tag" title="只读资料，只能用数据线连出">只读</span>
      </div>
      {s.kind === 'files' && s.files.length > 0 ? (
        <div className="node-body source-files">
          {shown.map(f => (
            <div key={f.id} className="source-file">
              <span className="file-kind">{kindLabel[f.kind]}</span>
              <span className="file-name">{f.name}</span>
              <span className="meta">{formatBytes(f.bytes)}</span>
            </div>
          ))}
          {s.files.length > shown.length && <div className="muted">还有 {s.files.length - shown.length} 个文件</div>}
        </div>
      ) : (
        <div className={`node-body${s.kind === 'mcp' ? ' mono' : ' muted'}`}>{sourcePreview(s)}</div>
      )}
      <div className="node-foot">
        <span className="meta">{s.kind === 'mcp' && s.mcp ? s.mcp.serverName : s.files.length ? `${s.files.length} 个文件 · ${formatBytes(s.files.reduce((t, f) => t + f.bytes, 0))}` : fileStats(s.files)}</span>
        {s.importing
          ? <span className="status status-running">正在读取…</span>
          : s.mcp?.isError
            ? <span className="status status-failed">工具返回错误</span>
            : <span className="status">{formatStamp(s.kind === 'mcp' && s.mcp ? s.mcp.calledAt : s.updatedAt)}</span>}
      </div>
      {(data.downstream ?? 0) > 0 && (
        <button className="downstream-pill nodrag" title={`让下游 ${data.downstream} 个已运行的节点带上新内容重新回答（${data.downstream} 次调用，运行前会确认）`} onClick={e => { e.stopPropagation(); data.onDownstream?.() }}>
          ▶ 重跑下游 {data.downstream}
        </button>
      )}
      <Handle type="source" position={Position.Right} className="port" />
    </div>
  )
}

export const SourceNode = memo(SourceNodeView)
