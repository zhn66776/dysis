import { memo } from 'react'
import { Handle, Position, type Node, type NodeProps } from '@xyflow/react'
import { Reply } from './Reply'
import { modeLabel } from './harness'
import { ProviderMark, providerSubtitle } from './providers'
import type { HarnessMode, SessionSummary, MessagePayload } from './types'

export type ChatNodeData = {
  summary?: SessionSummary; inherited: boolean; nativeFork?: boolean
  merge?: string; stale?: boolean; downstream?: number; chainCurrent?: boolean; picked?: boolean
  expanded?: boolean; reading?: MessagePayload; mode?: HarnessMode
  onExpand?(): void; onFollowUp?(): void; onBranch?(): void; onQuote?(): void
  onDownstream?(): void
}
export type ChatFlowNode = Node<ChatNodeData, 'chat'>

// Node bodies are three lines of plain text; drop Markdown punctuation.
export const plainPreview = (text: string) =>
  text.replace(/```[\s\S]*?```/g, ' ').replace(/[#*_`>|]+/g, '').replace(/\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/\s+/g, ' ').trim()

const stateLabel: Record<SessionSummary['state'], string> = {
  empty: '待发送', running: '运行中', waiting: '等待确认', complete: '完成', failed: '失败', cancelled: '已停止',
}

function ChatNodeView({ data, selected }: NodeProps<ChatFlowNode>) {
  const s = data.summary
  if (!s) return <div className="node node-missing">会话不存在</div>
  return (
    <div className={`node p-${s.provider} state-${s.state}${selected ? ' selected' : ''}${data.stale ? ' stale' : ''}${data.chainCurrent ? ' chain-current' : ''}${data.picked ? ' picked' : ''}${data.expanded ? ' expanded' : ''}`}>
      <Handle type="target" position={Position.Left} className="port" />
      <div className="node-head">
        <span title={providerSubtitle(s.provider)}><ProviderMark provider={s.provider} size={16} /></span>
        <span className="node-title">{s.title}</span>
        {s.state === 'waiting' && <span className="node-badge waiting-badge" title="模型想做的事需要你确认；打开面板回答">等你确认</span>}
        {data.merge && <span className="node-badge" title="合流节点：读取所有入线节点的输出">合流 · {data.merge}</span>}
        {data.inherited && <span className="node-tag" title={data.nativeFork ? '原生分叉' : '从父节点分支'}>⑂</span>}
      </div>
      {data.expanded ? <div className="node-reading nodrag nowheel" onClick={e => e.stopPropagation()}>
        {data.reading ? <><div className="reading-caption">{data.reading.role === 'assistant' ? '最新回复' : '最新消息'}{data.reading.state === 'streaming' ? ' · 正在生成' : ''}</div><Reply text={data.reading.text} /></> : <div className="muted">{s.messageCount ? '正在读取完整内容…' : '还没有消息，点击追问开始。'}</div>}
      </div> : <div className={`node-body${s.preview ? '' : ' muted'}`}>
        {plainPreview(s.preview) || (data.inherited ? '分支已建好，发送后带上父节点的历史' : '还没有消息')}
      </div>}
      <div className="node-actions nodrag" onClick={e => e.stopPropagation()}>
        <button title="在画布上阅读完整回复；最多同时展开 6 张，继续展开会收起最早的一张" aria-expanded={Boolean(data.expanded)} onClick={data.onExpand}>{data.expanded ? '收起' : '展开阅读'}</button>
        <span className="spacer" />
        <button title="继续当前会话，保留已有历史" onClick={data.onFollowUp}>追问</button>
        <button title="从最近一条完整回复分支，继承历史" disabled={!s.latestReplyID} onClick={data.onBranch}>分支</button>
        <button title="新建独立节点，只引用最近一条完整回复" disabled={!s.latestReplyID} onClick={data.onQuote}>引用</button>
      </div>
      <div className="node-foot">
        <span className="meta">{data.mode && <span className={`mode-tag mode-${data.mode}`} title="这个节点下一轮的运行模式">{modeLabel(data.mode)}</span>}{s.modelID || '默认模型'}</span>
        {data.stale && s.state !== 'running' && s.state !== 'waiting'
          ? <span className="status status-stale" title="上游有新的输出，这个回答可能已经过期">● 上游已更新</span>
          : <span className={`status status-${s.state}`}>{s.state === 'running' && s.status ? s.status : stateLabel[s.state]}</span>}
      </div>
      {(data.downstream ?? 0) > 0 && s.state !== 'running' && s.state !== 'waiting' && (
        <button className="downstream-pill nodrag" title={`让下游 ${data.downstream} 个已运行的节点带上新输出重新回答（${data.downstream} 次调用，运行前会确认）`} onClick={e => { e.stopPropagation(); data.onDownstream?.() }}>
          ▶ 重跑下游 {data.downstream}
        </button>
      )}
      <Handle type="source" position={Position.Right} className="port" />
    </div>
  )
}

export const ChatNode = memo(ChatNodeView)
