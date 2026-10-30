import { useEffect, useRef, useState } from 'react'
import { send, subscribe } from './bridge'
import { ProviderMark } from './providers'
import type { AppState, SearchHit } from './types'

export function CanvasSearch({ state, onLocate }: { state: AppState; onLocate(hit: SearchHit): void }) {
  const [query, setQuery] = useState('')
  const [hits, setHits] = useState<SearchHit[]>([])
  const [open, setOpen] = useState(false)
  const [loading, setLoading] = useState(false)
  const [active, setActive] = useState(0)
  const field = useRef<HTMLInputElement>(null)
  const request = useRef('')
  const board = state.board!
  useEffect(() => subscribe(p => {
    if (p.type === 'search.results' && p.id === request.current && p.boardID === board.id) {
      setHits(p.hits); setActive(0); setLoading(false)
    }
  }), [board.id])
  useEffect(() => {
    request.current = crypto.randomUUID().toUpperCase()
    setHits([]); setActive(0)
    const text = query.trim()
    setLoading(Boolean(text))
    if (!text) return
    const id = request.current
    const timer = window.setTimeout(() => send({ type: 'board.search', boardID: board.id, text, id }), 180)
    return () => window.clearTimeout(timer)
  }, [query, board.id])
  useEffect(() => {
    const focus = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f' && !document.querySelector('[aria-modal="true"]')) {
        e.preventDefault(); field.current?.focus(); field.current?.select(); setOpen(true)
      }
    }
    document.addEventListener('keydown', focus)
    return () => document.removeEventListener('keydown', focus)
  }, [])
  const locate = (hit: SearchHit) => { onLocate(hit); setOpen(false) }
  return <div className="canvas-search" onBlur={e => { if (!e.currentTarget.contains(e.relatedTarget)) setOpen(false) }}>
    <div className="search-field"><span aria-hidden="true">⌕</span><input ref={field} aria-label="搜索当前画布" placeholder="搜索画布与历史 · ⌘F" value={query} onFocus={() => setOpen(true)} onChange={e => { setQuery(e.target.value); setOpen(true) }} onKeyDown={e => {
      e.stopPropagation()
      if (e.nativeEvent.isComposing) return
      if (e.key === 'Escape') { setOpen(false); field.current?.blur() }
      if (e.key === 'ArrowDown') { e.preventDefault(); setActive(i => Math.min(i + 1, hits.length - 1)) }
      if (e.key === 'ArrowUp') { e.preventDefault(); setActive(i => Math.max(0, i - 1)) }
      if (e.key === 'Enter' && hits[active]) { e.preventDefault(); locate(hits[active]); field.current?.blur() }
    }} />{query && <button className="icon-btn" aria-label="清除搜索" onClick={() => { setQuery(''); field.current?.focus() }}>✕</button>}</div>
    {open && query.trim() && <div className="search-results" aria-label="搜索结果">
      <div className="search-caption" role="status">{loading ? '正在搜索…' : hits.length ? `${hits.length} 个节点 · 包含历史消息` : '当前画布没有匹配内容'}</div>
      {hits.map((hit, i) => {
        const node = board.nodes.find(n => n.id === hit.nodeID)
        const summary = node && state.summaries[node.sessionID]
        return summary && <button key={hit.nodeID} className={`search-result${active === i ? ' active' : ''}`} onMouseDown={e => e.preventDefault()} onClick={() => locate(hit)}>
          <span className="search-result-title"><ProviderMark provider={summary.provider} size={14} />{summary.title}<small>{hit.messageID ? '历史消息' : '节点标题'}</small></span>
          <span className="search-excerpt">{hit.excerpt}</span>
        </button>
      })}
    </div>}
  </div>
}
