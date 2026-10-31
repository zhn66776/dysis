import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { ApprovalCard } from './ApprovalCard'
import { Reply } from './Reply'
import { ContextInspector } from './ContextInspector'
import { send } from './bridge'
import { ContextMeter, Dropdown, EffortPicker, ModelPicker, QuotaMeter } from './Controls'
import { cursorNote, levelDetail, levelLabel, modeLabel, nodeLevelChoices } from './harness'
import { ProviderMark, providerSubtitle } from './providers'
import { composerHint, dataInputs, formatBytes, imageNotes, kindLabel } from './sources'
import type { AppState, ApprovalShow, MessagePayload, NodePayload } from './types'

interface Props {
  state: AppState
  node: NodePayload
  draft: string
  onDraft(text: string): void
  onClose(): void
  composerFocus: number
  messageFocus: { messageID?: string; request: number } | null
  /** This node's open approvals, oldest first. */
  approvals: ApprovalShow[]
  onApprovalAnswered(id: string): void
}

export function ChatPanel({ state, node, draft, onDraft, onClose, composerFocus, messageFocus, approvals, onApprovalAnswered }: Props) {
  const board = state.board!
  const summary = state.summaries[node.sessionID]
  const detail = state.details[node.sessionID]
  const running = state.running.has(node.sessionID)
  const [renaming, setRenaming] = useState(false)
  const [showInherited, setShowInherited] = useState(false)
  const [contextOpen, setContextOpen] = useState(false)
  const composer = useRef<HTMLTextAreaElement>(null)
  const list = useRef<HTMLDivElement>(null)
  const stick = useRef(true)
  const locatedRequest = useRef<number | null>(null)

  const parentNode = node.inherited ? board.nodes.find(n => n.id === node.inherited!.fromNodeID) : undefined
  const parent = parentNode ? state.summaries[parentNode.sessionID] : undefined
  const parentDetail = parentNode ? state.details[parentNode.sessionID] : undefined
  const upstream = dataInputs(board, node.id, state.summaries)

  // Follow the stream only while the reader is already at the bottom.
  useLayoutEffect(() => {
    const el = list.current
    if (el && stick.current) el.scrollTop = el.scrollHeight
  }, [detail])
  useEffect(() => { stick.current = true }, [node.id])

  useEffect(() => { if (composerFocus) composer.current?.focus() }, [composerFocus])
  useEffect(() => {
    if (!messageFocus?.messageID || !detail || locatedRequest.current === messageFocus.request) return
    const el = list.current?.querySelector<HTMLElement>(`[data-message-id="${CSS.escape(messageFocus.messageID)}"]`)
    if (el) { locatedRequest.current = messageFocus.request; stick.current = false; el.scrollIntoView({ block: 'center' }) }
  }, [messageFocus, detail])

  if (!summary) return null
  const notes = imageNotes(upstream, summary.provider)
  const boardLevel = state.boards.find(b => b.id === board.id)?.project?.level ?? null
  const cursor = cursorNote(summary.provider, node.mode)

  const files = state.drafts[node.sessionID]
  const importing = files?.importing ?? false
  const hasFiles = (files?.files.length ?? 0) > 0

  const submit = () => {
    const text = draft.trim()
    if ((!text && !hasFiles) || running || importing) return
    send({ type: 'chat.send', boardID: board.id, nodeID: node.id, text })
    onDraft('')
    stick.current = true
  }

  return (
    <aside className="panel" data-drop="panel" onKeyDown={e => { if (e.key === 'Escape' && !e.nativeEvent.isComposing) onClose() }}>
      <header className="panel-head">
        <div className="panel-title-row">
          <ProviderMark provider={summary.provider} size={18} />
          {renaming ? (
            <input
              className="rename" autoFocus defaultValue={summary.title}
              onBlur={e => { const t = e.target.value.trim(); if (t && t !== summary.title) send({ type: 'node.rename', sessionID: summary.id, title: t }); setRenaming(false) }}
              onKeyDown={e => { if (e.key === 'Enter' && !e.nativeEvent.isComposing) (e.target as HTMLInputElement).blur(); if (e.key === 'Escape') setRenaming(false) }}
            />
          ) : (
            <span className="panel-title" title="双击改名" onDoubleClick={() => setRenaming(true)}>{summary.title}</span>
          )}
          <button className="icon-btn" aria-label="关闭面板" onClick={onClose}>✕</button>
        </div>
        <div className="panel-subtitle sub">{providerSubtitle(summary.provider)}</div>
        <div className="controls-row">
          <ModelPicker state={state} summary={summary} locked={running} />
          <EffortPicker summary={summary} locked={running} />
          {node.mode && (node.mode === 'chat' || !boardLevel
            ? <span className="chip mode-chip" title="不在信任的项目文件夹里：只聊天，不用工具">{modeLabel(node.mode)}</span>
            : <Dropdown className="mode-picker" align="right" disabled={running} title="这个节点的权限档位；只能比画布低"
                label={<span className={`mode-tag mode-${node.mode}`}>{modeLabel(node.mode)}</span>}
                items={[
                  { key: 'board', label: `跟随画布（${levelLabel[boardLevel]}）`, detail: levelDetail[boardLevel], checked: !node.nodeLevel, onSelect: () => send({ type: 'node.setLevel', boardID: board.id, nodeID: node.id, level: null }) },
                  ...nodeLevelChoices(boardLevel).filter(l => l !== boardLevel).map(l => ({
                    key: l, label: `只在这个节点用「${levelLabel[l]}」`, detail: levelDetail[l], checked: node.nodeLevel === l,
                    onSelect: () => send({ type: 'node.setLevel', boardID: board.id, nodeID: node.id, level: l }),
                  })),
                ]} />)}
          <span className="spacer" />
          <span className="chip meta" title={summary.remoteShort ? '官方会话 ID' : '第一次发送后由官方 CLI 创建会话'}>{summary.remoteShort ? `${summary.remoteShort}…` : '尚未开始'}</span>
        </div>
        <div className="usage-row">
          <ContextMeter summary={summary} />
          <QuotaMeter provider={summary.provider} quota={state.quotas[summary.provider]} />
        </div>
      </header>

      {approvals[0] && <ApprovalCard key={approvals[0].id} approval={approvals[0]} queued={approvals.length - 1} onAnswer={onApprovalAnswered} />}
      {cursor && <div className="stale-banner neutral cursor-note">{cursor}</div>}
      {node.stale && !running && (
        <div className="stale-banner">
          <span>上游有新的输出，这个回答可能已经过期。</span>
          <button className="btn" title="带上新的上游输出，重新回答上一个问题（1 次调用）" onClick={() => send({ type: 'node.rerun', boardID: board.id, nodeID: node.id })}>用新输入重新回答</button>
        </div>
      )}
      {node.downstream > 0 && !running && (
        <div className="stale-banner neutral">
          <span>下游有 {node.downstream} 个节点还没用上这里的新输出。</span>
          <button className="btn" onClick={() => send({ type: 'chain.downstream', boardID: board.id, nodeID: node.id })}>重跑下游（{node.downstream} 次调用）</button>
        </div>
      )}

      {(node.inherited || upstream.length > 0) && (
        <section className="lineage">
          {node.inherited && (
            <div className={`inherit-banner p-${parent?.provider ?? 'claude'}`}>
              <div>⑂ 继承自「{parent?.title ?? '已删除的节点'}」· {node.inherited.messageCount} 条消息</div>
              <div className="sub">{inheritNote(node, detail?.messages)}</div>
              {parentDetail && (
                <button className="link" onClick={() => setShowInherited(v => !v)}>{showInherited ? '▾ 收起继承的消息' : '▸ 查看继承的消息'}</button>
              )}
            </div>
          )}
          {upstream.length > 0 && (
            <div className="upstream">
              <span className="sub">数据线输入</span>
              {upstream.map(u => (
                <button key={u.edge.id} onClick={() => setContextOpen(true)} className={`chip context-chip ${u.source ? 'source-chip' : `p-${u.provider ?? 'claude'} tinted`}`}
                  title={u.source ? '预览本轮实际输入；资料更新后会再次带上' : '预览本轮实际输入；断开连线只停止后续传入'}>
                  {u.source ? `${u.source.kind === 'mcp' ? 'MCP' : '文件'} · ${u.title}` : `→ ${u.title}${u.edge.sourceMessageID ? ' · 指定回复' : ' · 跟随最新'}`}{u.edge.pending ? ' · 待传入' : ' · 本轮无新增'}
                </button>
              ))}
            </div>
          )}
          {notes.map(n => <div key={n} className="source-note">{n}</div>)}
        </section>
      )}

      <div className="messages" ref={list} onScroll={e => { const el = e.currentTarget; stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40 }}>
        {showInherited && parentDetail && (
          <div className="inherited-list">
            {parentDetail.messages.slice(0, node.inherited!.messageCount).map(m => <Message key={m.id} m={m} readOnly />)}
            <div className="divider">以上为继承内容（只读）</div>
          </div>
        )}
        {!detail && <div className="muted center">正在读取对话…</div>}
        {detail && detail.messages.length === 0 && (
          <div className="muted center">{node.inherited ? '在下面输入这个分支要深挖的问题。' : '在下面输入第一条消息。'}</div>
        )}
        {detail?.messages.map(m => (
          <Message key={m.id} m={m} highlighted={messageFocus?.messageID === m.id}
            onFollowUp={() => composer.current?.focus()}
            onQuote={() => send({ type: 'node.quote', boardID: board.id, nodeID: node.id, messageID: m.id })}
            onBranch={() => send({ type: 'node.branch', boardID: board.id, nodeID: node.id, messageID: m.id })} />
        ))}
        {running && summary.status && <div className="status-line">{summary.status}</div>}
      </div>

      <div className="context-launch"><span className="sub">{upstream.length ? `${upstream.length} 个引用来源` : node.inherited ? '分支继承上下文' : '当前会话上下文'}</span><button className="act" onClick={() => setContextOpen(true)}>预览本轮输入</button></div>
      {contextOpen && <ContextInspector boardID={board.id} nodeID={node.id} draft={draft} onClose={() => setContextOpen(false)} />}
      <div className="composer">
        {(hasFiles || importing) && (
          <div className="attachments">
            {files!.files.map(f => (
              <span key={f.id} className="file-chip" title={`${f.name} · ${formatBytes(f.bytes)}`}>
                <span className="file-kind">{kindLabel[f.kind]}</span>
                <span className="file-name">{f.name}</span>
                <button className="file-remove" aria-label={`移除 ${f.name}`} onClick={() => send({ type: 'attachment.remove', sessionID: summary.id, attachmentID: f.id })}>✕</button>
              </span>
            ))}
            {importing && <span className="file-chip muted">正在读取文件…</span>}
          </div>
        )}
        <textarea
          ref={composer}
          value={draft}
          placeholder={running ? '正在回复…' : '继续追问，Enter 发送，Shift+Enter 换行'}
          rows={3}
          onChange={e => onDraft(e.target.value)}
          onKeyDown={e => {
            if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); submit() }
          }}
        />
        <div className="composer-bar">
          <Dropdown
            className="plus"
            label={<span className="plus-icon">＋</span>}
            title="添加文件或使用 MCP 工具"
            items={[
              { key: 'file', label: '添加图片或文档…', detail: '最多 6 个', onSelect: () => send({ type: 'attachment.choose', sessionID: summary.id }) },
              { key: 'mcp', label: 'MCP 工具…', detail: '结果插入输入框', onSelect: () => send({ type: 'app.open', window: 'mcp', sessionID: summary.id }) },
            ]}
          />
          <span className="composer-hint">{composerHint(upstream, Boolean(summary.remoteShort))}</span>
          <span className="spacer" />
          {running ? (
            <button className="send stop" aria-label="停止" onClick={() => send({ type: 'chat.stop', sessionID: summary.id })}>■</button>
          ) : (
            <button className="send" aria-label="发送" disabled={(!draft.trim() && !hasFiles) || importing} onClick={submit}>↑</button>
          )}
        </div>
      </div>
    </aside>
  )
}


// Before the first send the mode comes from Swift; afterwards from the
// sources recorded on the first message.
function inheritNote(node: NodePayload, messages?: MessagePayload[]) {
  const i = node.inherited!
  if (i.mode === 'native') return '原生分叉：由官方 CLI 复制父节点的会话，第一次发送时创建。'
  if (i.mode === 'replay') return `回放继承（${i.reason ?? '无法原生分叉'}）：第一次发送时只带文字，不带工具调用和图片。`
  const first = messages?.find(m => m.role === 'user')
  if (first?.contextSources?.some(s => s.includes('原生分叉'))) return '已通过原生分叉继承父节点的会话。'
  return first ? '已在第一次发送时通过回放继承带上父节点的文字记录。' : '已继承。'
}

function Message({ m, readOnly, onBranch, onQuote, onFollowUp, highlighted }: { m: MessagePayload; readOnly?: boolean; highlighted?: boolean; onBranch?(): void; onQuote?(): void; onFollowUp?(): void }) {
  if (m.role === 'user') {
    return (
      <div data-message-id={m.id} className={`msg-user${highlighted ? ' search-highlight' : ''}`}>
        {m.contextSources && m.contextSources.length > 0 && (
          <div className="context-sources">{m.contextSources.map(s => <span key={s} className="chip">{s}</span>)}</div>
        )}
        {m.attachments && m.attachments.length > 0 && (
          <div className="context-sources">{m.attachments.map(a => <span key={a} className="chip">📎 {a}</span>)}</div>
        )}
        <div className="bubble">{m.text}</div>
      </div>
    )
  }
  return (
    <div data-message-id={m.id} className={`msg-assistant state-${m.state}${highlighted ? ' search-highlight' : ''}`}>
      <Reply text={m.text} />
      {m.state === 'streaming' && <span className="caret" />}
      {m.state === 'failed' && <div className="msg-note danger">回复失败</div>}
      {m.state === 'cancelled' && <div className="msg-note">已停止</div>}
      {!readOnly && m.state === 'complete' && (
        <div className="msg-actions">
          <button className="act" onClick={onFollowUp}>追问</button>
          <button className="act" title="继承截至这条回复的历史" onClick={onBranch}>⑂ 从这里分支</button>
          <button className="act" title="新建独立节点，只引用这条回复" onClick={onQuote}>引用</button>
          <button className="act" onClick={() => send({ type: 'clipboard.copy', text: m.text })}>复制</button>
          {m.actualModels && m.actualModels.length > 0 && <span className="meta muted">{m.actualModels.join(' · ')}</span>}
        </div>
      )}
    </div>
  )
}
