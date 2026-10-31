import { useState } from 'react'
import { send } from './bridge'
import { levelDetail, levelLabel, levels } from './harness'
import { projectStatus } from './projects'
import type { AppState, BoardSummary } from './types'

/** Folder actions under the selected board. */
function ProjectRow({ board }: { board: BoardSummary }) {
  const p = board.project
  if (!p) {
    return (
      <div className="project-row">
        <button className="link" onClick={e => { e.stopPropagation(); send({ type: 'board.linkFolder', boardID: board.id }) }}>关联文件夹…</button>
      </div>
    )
  }
  return (
    <div className="project-row" title={p.path}>
      <div className={`project-status${p.trusted === true && !p.missing ? ' trusted' : ''}`}>{projectStatus(p)}</div>
      {p.trusted === true && (
        <div className="level-switch" role="radiogroup" aria-label="权限档位">
          {levels.map(l => (
            <button key={l} role="radio" aria-checked={(p.level ?? 'auto') === l} className={(p.level ?? 'auto') === l ? 'on' : ''} title={levelDetail[l]}
              onClick={e => { e.stopPropagation(); if ((p.level ?? 'auto') !== l) send({ type: 'board.setLevel', boardID: board.id, level: l }) }}>{levelLabel[l]}</button>
          ))}
        </div>
      )}
      <div className="project-actions">
        <button className="link" onClick={e => { e.stopPropagation(); send({ type: 'board.reveal', boardID: board.id }) }}>在访达中显示</button>
        {p.trusted === true && !p.git && !p.missing && <button className="link" title="每个节点在自己的 worktree 和分支上并行改代码" onClick={e => { e.stopPropagation(); send({ type: 'board.gitInit', boardID: board.id }) }}>初始化 git…</button>}
        {p.trusted === true
          ? <button className="link" onClick={e => { e.stopPropagation(); send({ type: 'board.trust', boardID: board.id, ok: false }) }}>取消信任</button>
          : <button className="link" onClick={e => { e.stopPropagation(); send({ type: 'board.trust', boardID: board.id, ok: true }) }}>信任…</button>}
      </div>
    </div>
  )
}

export function Sidebar({ state, collapsed, onToggle }: { state: AppState; collapsed: boolean; onToggle(): void }) {
  const [renaming, setRenaming] = useState<string | null>(null)
  if (collapsed) {
    return (
      <nav className="rail">
        <div className="rail-drag" data-drag />
        <button className="icon-btn" aria-label="展开侧栏" onClick={onToggle}>☰</button>
        <button className="icon-btn" aria-label="新画布" onClick={() => send({ type: 'board.create' })}>＋</button>
        <span className="spacer" />
        <button className="icon-btn" aria-label="设置" onClick={() => send({ type: 'app.open', window: 'settings' })}>⚙</button>
      </nav>
    )
  }
  return (
    <nav className="sidebar">
      <div className="brand-row" data-drag>
        <span className="brand">AgentDesk</span>
        <button className="icon-btn" aria-label="收起侧栏" onClick={onToggle}>‹</button>
      </div>
      <button className="side-item new" onClick={() => send({ type: 'board.create' })}>＋ 新画布</button>
      <div className="side-label">画布</div>
      <div className="board-list">
        {state.boards.map(b => (
          <div key={b.id}>
          <div className={`side-item board${b.id === state.board?.id ? ' on' : ''}`} onClick={() => send({ type: 'board.select', boardID: b.id })} onDoubleClick={() => setRenaming(b.id)}>
            {renaming === b.id ? (
              <input
                className="rename" autoFocus defaultValue={b.title} onClick={e => e.stopPropagation()}
                onBlur={e => { const t = e.target.value.trim(); if (t && t !== b.title) send({ type: 'board.rename', boardID: b.id, title: t }); setRenaming(null) }}
                onKeyDown={e => { if (e.key === 'Enter' && !e.nativeEvent.isComposing) (e.target as HTMLInputElement).blur(); if (e.key === 'Escape') setRenaming(null) }}
              />
            ) : (
              <>
                <span className="board-title">{b.title}{b.project && <span className="board-folder" title={b.project.path}>{b.project.path}</span>}</span>
                {(b.waiting ?? 0) > 0 && <span className="waiting-count" title={`${b.waiting} 个节点等你确认`}>{b.waiting}</span>}
                <span className="count">{b.nodeCount}</span>
                <button className="del" aria-label={`删除画布 ${b.title}`} onClick={e => { e.stopPropagation(); send({ type: 'board.delete', boardID: b.id }) }}>✕</button>
              </>
            )}
          </div>
          {b.id === state.board?.id && <ProjectRow board={b} />}
          </div>
        ))}
      </div>
      <span className="spacer" />
      <button className="side-item" onClick={() => send({ type: 'app.open', window: 'classic' })} title="讨论室、附件、听写、导出暂时在这里">经典界面</button>
      <button className="side-item" onClick={() => send({ type: 'app.open', window: 'mcp' })}>MCP 工具</button>
      <button className="side-item" onClick={() => send({ type: 'app.open', window: 'settings' })}>设置</button>
    </nav>
  )
}
