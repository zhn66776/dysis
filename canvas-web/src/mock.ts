// Browser-only stand-in for the Swift host, used by `npm run dev`.
// Replies are canned local text, clearly labelled; nothing leaves the page.
import { previewLayout } from './organize'
import { searchExcerpt } from './interactions'
import type { Incoming, BoardPayload, Command, ContextPreview, MessagePayload, NodePayload, Provider, RuleSourcePayload, SessionSummary, SourceFile, SourcePayload, StatePayload } from './types'

interface MockSession { id: string; title: string; provider: Provider; modelID: string; started: boolean; messages: MessagePayload[]; rules?: string }

const models: Record<Provider, string> = { claude: 'sonnet', codex: 'gpt-6.1-sol', grok: 'grok-4.7-medium', gemini: 'gemini-4-argon-medium' }
const uid = () => crypto.randomUUID()

export function createMockHost(emit: (p: Incoming) => void) {
  const sessions = new Map<string, MockSession>()
  const boards: BoardPayload[] = []
  let current = ''
  let watched = new Set<string>()
  const running = new Map<string, number>()
  const efforts = new Map<string, string>()
  type Edit = { before: BoardPayload; after: BoardPayload; label: string }
  const histories = new Map<string, { past: Edit[]; future: Edit[] }>()
  const history = (id: string) => { if (!histories.has(id)) histories.set(id, { past: [], future: [] }); return histories.get(id)! }
  const edit = (b: BoardPayload, label: string, change: () => void) => {
    const before = structuredClone(b); change()
    if (JSON.stringify(before) === JSON.stringify(b)) return
    const h = history(b.id); h.past.push({ before, after: structuredClone(b), label }); h.future = []
  }
  const normalizeGroups = (b: BoardPayload) => {
    const seen = new Set<string>(), valid = new Set(b.nodes.map(n => n.id))
    b.groups = (b.groups ?? []).map(g => ({ ...g, nodeIDs: g.nodeIDs.filter(id => valid.has(id) && !seen.has(id) && Boolean(seen.add(id))) })).filter(g => g.nodeIDs.length)
  }
  const drafts = new Map<string, { id: string; name: string; kind: 'pdf'; bytes: number }[]>()
  const confirms = new Map<string, () => void>()
  const confirm = (title: string, detail: string, action: string, perform: () => void) => {
    const id = uid()
    confirms.set(id, perform)
    emit({ type: 'confirm.show', id, title, detail, action })
  }

  const addSession = (provider: Provider, title: string, messages: MessagePayload[] = []) => {
    const s: MockSession = { id: uid(), title, provider, modelID: models[provider], started: messages.length > 0, messages }
    sessions.set(s.id, s)
    return s
  }
  const msg = (role: MessagePayload['role'], text: string): MessagePayload => ({ id: uid(), role, text, state: 'complete', createdAt: Date.now() })

  const a = addSession('claude', '定价调研', [msg('user', 'Q4 新产品怎么定价？给我三个方向'), msg('assistant', '1. **订阅制**：月付，年付打八折。\n2. **按量计费**：按任务次数阶梯计价。\n3. **混合**：基础订阅加超额按量。\n\n（浏览器预览的示例内容）')])
  const b = addSession('codex', '写定价说明')
  const c = addSession('grok', 'Grok 竞品速览')
  const board: BoardPayload = { id: uid(), title: '示例画布', nodes: [], edges: [] }
  const na: NodePayload = { id: uid(), sessionID: a.id, x: 80, y: 120, stale: false, downstream: 0 }
  const nb: NodePayload = { id: uid(), sessionID: b.id, x: 440, y: 120, stale: false, downstream: 0 }
  const nc: NodePayload = { id: uid(), sessionID: c.id, x: 440, y: 340, stale: false, downstream: 0 }
  board.nodes.push(na, nb, nc)
  board.edges.push({ id: uid(), kind: 'data', source: na.id, target: nb.id, pending: true })

  // Source nodes: read-only files and an MCP result, fed into two conversations.
  const file = (name: string, kind: SourceFile['kind'], bytes: number, note?: string): SourceFile => ({ id: uid(), name, kind, bytes, note })
  const filesTitle = (files: SourceFile[]) => files.length === 0 ? '文件' : files.length === 1 ? files[0].name : `${files[0].name} 等 ${files.length} 个文件`
  const customTitles = new Map<string, string>()
  const sourceNode = (source: SourcePayload, x: number, y: number): NodePayload => { const id = uid(); return { id, sessionID: id, x, y, stale: false, downstream: 0, source } }
  const sampleFiles = [file('需求说明.md', 'text', 18_400), file('竞品价格表.pdf', 'pdf', 412_000, '仅提取前 100 页，共 120 页。'), file('定价草图.png', 'image', 1_240_000)]
  const nf = sourceNode({ kind: 'files', title: filesTitle(sampleFiles), updatedAt: Date.now() - 3600e3, importing: false, files: sampleFiles }, 80, 330)
  const nm = sourceNode({
    kind: 'mcp', title: 'query_prices', updatedAt: Date.now() - 600e3, importing: false, files: [],
    mcp: { serverName: '本地价格库（示例）', toolName: 'query_prices', arguments: '{\n  "region": "CN",\n  "quarter": "Q3"\n}', text: '{\n  "rows": [\n    { "plan": "基础版", "price": 49 },\n    { "plan": "专业版", "price": 199 }\n  ]\n}', isError: false, calledAt: Date.now() - 600e3 },
  }, 80, 520)
  board.nodes.push(nf, nm)
  for (const [from, to] of [[nf, nb], [nm, nb], [nf, nc]]) board.edges.push({ id: uid(), kind: 'data', source: from.id, target: to.id, pending: true })
  boards.push(board)
  current = board.id

  /** New content: every edge out of the node is pending again, like a new version. */
  const touch = (n: NodePayload) => {
    const src = n.source!
    if (src.kind === 'files') src.title = customTitles.get(n.id) ?? filesTitle(src.files)
    src.updatedAt = Date.now()
    for (const e of boardNow().edges) if (e.source === n.id) e.pending = true
  }

  const summary = (s: MockSession): SessionSummary => {
    const last = [...s.messages].reverse().find(m => m.role === 'assistant')
    const state = running.has(s.id) ? 'running' : last ? (last.state === 'streaming' ? 'running' : last.state) : 'empty'
    return { id: s.id, title: s.title, provider: s.provider, modelID: s.modelID, modelKey: s.modelID, effort: efforts.get(s.id), effortChoices: ['low', 'medium', 'high', 'xhigh', 'max'], remoteShort: s.started ? s.id.slice(0, 8) : undefined, state, latestReplyID: [...s.messages].reverse().find(m => m.role === 'assistant' && m.state === 'complete' && m.text)?.id, preview: (last?.text ?? s.messages.at(-1)?.text ?? '').slice(0, 140), messageCount: s.messages.length, updatedAt: Date.now(), contextUsed: s.started ? 18_400 : undefined, contextWindow: s.started ? 200_000 : undefined, rules: s.rules }
  }
  const boardNow = () => boards.find(x => x.id === current)!
  const push = (extra: Partial<StatePayload> = {}) => emit({
    type: 'state', reset: true, running: [...running.keys()], error: '', chain: { total: 0, index: 0 },
    boards: boards.map(x => ({ id: x.id, title: x.title, nodeCount: x.nodes.length })),
    board: { ...structuredClone(boardNow()), history: { undoLabel: history(current).past.at(-1)?.label, redoLabel: history(current).future.at(-1)?.label } },
    summaries: [...sessions.values()].map(summary),
    details: [...watched].filter(id => sessions.has(id)).map(id => ({ id, messages: structuredClone(sessions.get(id)!.messages) })),
    models: {
      claude: [{ id: 'claude-opus-5-5', key: 'claude-opus-5-5', label: 'Opus 5.5' }, { id: 'sonnet', key: 'sonnet', label: 'Sonnet · 跟随官方更新' }],
      codex: [{ id: 'gpt-6.1-sol', key: 'gpt-6.1-sol', label: 'gpt-6.1-sol' }, { id: 'gpt-6-luna', key: 'gpt-6-luna', label: 'gpt-6-luna' }],
    },
    quotas: { claude: { windows: [{ label: '5 小时', usedPercent: 38, resetsAt: Date.now() + 2.5 * 3600e3 }, { label: '每周', usedPercent: 61 }], updatedAt: Date.now() } },
    drafts: [...watched].map(id => ({ sessionID: id, files: drafts.get(id) ?? [], importing: false })),
    ...extra,
  })
  const nodeOf = (boardID: string, nodeID: string) => boards.find(x => x.id === boardID)?.nodes.find(n => n.id === nodeID)

  return (c: Command) => {
    switch (c.type) {
      case 'ready': case 'error.dismiss': break
      case 'board.create': { const nb: BoardPayload = { id: uid(), title: '新画布', nodes: [], edges: [] }; boards.push(nb); current = nb.id; break }
      case 'board.select': current = c.boardID; break
      case 'board.rename': { const x = boards.find(y => y.id === c.boardID); if (x) x.title = c.title; break }
      case 'board.delete': {
        const target = boards.find(y => y.id === c.boardID)
        if (!target || boards.length <= 1) return
        confirm(`删除画布「${target.title}」？`, `画布上的 ${target.nodes.length} 个对话的本地记录也会删除。官方 CLI 中的历史和工作目录文件不受影响。`, '删除画布', () => {
          boards.splice(boards.findIndex(y => y.id === c.boardID), 1); current = boards[0].id
        })
        return
      }
      case 'confirm.answer': { const perform = confirms.get(c.id); confirms.delete(c.id); if (c.ok && perform) perform(); break }
      case 'node.create': {
        const s = addSession(c.provider, '新对话')
        const n: NodePayload = { id: uid(), sessionID: s.id, x: c.x, y: c.y, stale: false, downstream: 0 }
        const target = boards.find(y => y.id === c.boardID)!
        histories.delete(target.id)
        target.nodes.push(n)
        if (c.connectFrom) target.edges.push({ id: uid(), kind: 'data', source: c.connectFrom, target: n.id })
        push({ focusNodeID: n.id }); return
      }
      case 'node.move': { const b = boards.find(b => b.id === c.boardID)!; edit(b, '移动节点', () => { for (const p of c.positions) { const n = nodeOf(c.boardID, p.nodeID); if (n) { n.x = p.x; n.y = p.y } } }); break }
      case 'node.delete': {
        const x = boardNow()
        const titles = x.nodes.filter(n => c.nodeIDs.includes(n.id)).map(n => n.source?.title ?? sessions.get(n.sessionID)?.title ?? '')
        confirm(`删除${titles.length === 1 ? `「${titles[0]}」` : `${c.nodeIDs.length} 个节点`}？`, '只删除本地记录和画布上的节点，官方 CLI 中的历史和工作目录文件不受影响。', '删除', () => {
          x.nodes = x.nodes.filter(n => !c.nodeIDs.includes(n.id)); x.edges = x.edges.filter(e => !c.nodeIDs.includes(e.source) && !c.nodeIDs.includes(e.target))
          normalizeGroups(x); histories.delete(x.id)
        })
        return
      }
      case 'node.rename': { const s = sessions.get(c.sessionID); if (s) s.title = c.title; break }
      case 'node.branch': {
        const parent = nodeOf(c.boardID, c.nodeID)!
        const ps = sessions.get(parent.sessionID)!
        const s = addSession(ps.provider, `分支 · ${ps.title}`)
        s.modelID = ps.modelID
        if (efforts.has(ps.id)) efforts.set(s.id, efforts.get(ps.id)!)
        let y = parent.y; while (boardNow().nodes.some(o => Math.abs(o.x - parent.x - 320) < 260 && Math.abs(o.y - y) < 150)) y += 40
        const n: NodePayload = { id: uid(), sessionID: s.id, x: parent.x + 320, y, stale: false, downstream: 0, inherited: { fromNodeID: parent.id, messageCount: ps.messages.findIndex(m => m.id === c.messageID) + 1, mode: (ps.provider === 'claude' || ps.provider === 'codex') ? 'native' as const : 'replay' as const, reason: (ps.provider === 'claude' || ps.provider === 'codex') ? undefined : 'Cursor 不支持原生分叉' } }
        const x = boardNow(); histories.delete(x.id); x.nodes.push(n); x.edges.push({ id: uid(), kind: 'inherit', source: parent.id, target: n.id })
        push({ focusNodeID: n.id }); return
      }
      case 'board.layout': {
        const b = boards.find(b => b.id === c.boardID)!
        edit(b, '自动布局', () => { for (const p of previewLayout(b, c.sizes)) { const n = b.nodes.find(n => n.id === p.nodeID)!; n.x = p.x; n.y = p.y } })
        push({ fitBoardID: b.id }); return
      }
      case 'board.undo': case 'board.redo': {
        const b = boards.find(b => b.id === c.boardID)!, h = history(b.id)
        const entry = (c.type === 'board.undo' ? h.past : h.future).pop()
        if (!entry) return
        const saved = c.type === 'board.undo' ? entry.before : entry.after
        for (const n of b.nodes) { const old = saved.nodes.find(s => s.id === n.id); if (old) { n.x = old.x; n.y = old.y } }
        b.groups = structuredClone(saved.groups ?? []); b.edges = structuredClone(saved.edges)
        ;(c.type === 'board.undo' ? h.future : h.past).push(entry)
        break
      }
      case 'group.create': case 'group.add': {
        const b = boards.find(b => b.id === c.boardID)!
        edit(b, c.type === 'group.create' ? '创建分组' : '调整分组', () => {
          const ids = b.nodes.filter(n => c.nodeIDs.includes(n.id)).map(n => n.id)
          if (!ids.length) return
          if (c.type === 'group.add' && !b.groups?.some(g => g.id === c.groupID)) return
          for (const g of b.groups ?? []) g.nodeIDs = g.nodeIDs.filter(id => !ids.includes(id))
          if (c.type === 'group.create') { b.groups ??= []; b.groups.push({ id: uid(), title: '新分组', nodeIDs: ids }) }
          else b.groups!.find(g => g.id === c.groupID)!.nodeIDs.push(...ids)
          normalizeGroups(b)
        })
        if (c.type === 'group.create') { push({ fitBoardID: b.id }); return }
        break
      }
      case 'group.rename': case 'group.dissolve': {
        const b = boards.find(b => b.id === c.boardID)!
        edit(b, c.type === 'group.rename' ? '分组改名' : '解散分组', () => {
          if (c.type === 'group.dissolve') b.groups = b.groups?.filter(g => g.id !== c.groupID)
          else { const g = b.groups?.find(g => g.id === c.groupID); if (g && c.title.trim()) g.title = c.title.trim() }
        }); break
      }
      case 'board.search': {
        const target = boards.find(b => b.id === c.boardID)
        const query = c.text.trim()
        const hits = query ? (target?.nodes ?? []).flatMap(n => {
          const s = sessions.get(n.sessionID)
          if (!s) return []
          if (searchExcerpt(s.title, query)) return [{ nodeID: n.id, excerpt: s.title }]
          const m = [...s.messages].reverse().find(m => searchExcerpt(m.text, query))
          return m ? [{ nodeID: n.id, messageID: m.id, excerpt: searchExcerpt(m.text, query)! }] : []
        }) : []
        emit({ type: 'search.results', id: c.id, boardID: c.boardID, query: c.text, hits }); return
      }
      case 'context.preview': {
        const target = boards.find(b => b.id === c.boardID)!
        const node = target.nodes.find(n => n.id === c.nodeID)!
        const inputs = target.edges.filter(e => e.kind === 'data' && e.target === node.id && e.pending).map(e => {
          const source = target.nodes.find(n => n.id === e.source)!
          if (source.source) return `--- 资料节点「${source.source.title}」---\n` + (source.source.kind === 'mcp' ? source.source.mcp?.text ?? '' : source.source.files.map(f => `【${f.name}】`).join('\n'))
          const s = sessions.get(source.sessionID)!
          const reply = e.sourceMessageID ? s.messages.find(m => m.id === e.sourceMessageID) : [...s.messages].reverse().find(m => m.role === 'assistant' && m.state === 'complete')
          return reply ? `--- 来自「${s.title}」---\n${reply.text}` : ''
        }).filter(Boolean)
        emit({ type: 'context.preview', id: c.id, nodeID: c.nodeID, text: [...inputs, '[本轮用户消息]\n' + (c.text || '（在输入框中填写本轮问题）')].join('\n\n'), notes: ['浏览器预览：示例内容，不调用模型。正式应用复用实际发送时的上下文与附件文字组装。'],
          ...mockRules(sessions.get(node.sessionID)) }); return
      }
      case 'node.quote': {
        const parent = nodeOf(c.boardID, c.nodeID)!
        const ps = sessions.get(parent.sessionID)!
        if (!ps.messages.some(m => m.id === c.messageID && m.state === 'complete' && m.role === 'assistant')) return
        const s = addSession(ps.provider, `引用 · ${ps.title}`)
        s.modelID = ps.modelID
        if (efforts.has(ps.id)) efforts.set(s.id, efforts.get(ps.id)!)
        const x = boardNow()
        const n: NodePayload = { id: uid(), sessionID: s.id, x: parent.x + 440, y: parent.y + 200, stale: false, downstream: 0 }
        histories.delete(x.id)
        x.nodes.push(n); x.edges.push({ id: uid(), kind: 'data', source: parent.id, target: n.id, sourceMessageID: c.messageID, pending: true })
        push({ focusNodeID: n.id }); return
      }
      case 'edge.create': { const x = boardNow(); if (x.nodes.find(n => n.id === c.target)?.source) { push({ error: '文件和 MCP 结果节点只能作为数据线的起点。' }); return }; edit(x, '添加连线', () => { x.edges.push({ id: uid(), kind: 'data', source: c.source, target: c.target, pending: true }) }); break }
      case 'edge.delete': { const x = boardNow(); edit(x, '移除连线', () => { x.edges = x.edges.filter(e => !c.edgeIDs.includes(e.id)) }); break }
      case 'session.watch': watched = new Set(c.sessionIDs); break
      case 'chat.send': {
        const n = nodeOf(c.boardID, c.nodeID)!
        const s = sessions.get(n.sessionID)!
        if (s.title === '新对话' && s.messages.length === 0) s.title = c.text.slice(0, 32)
        for (const e of boardNow().edges) if (e.target === n.id) e.pending = false
        s.messages.push(msg('user', c.text))
        const reply: MessagePayload = { ...msg('assistant', ''), state: 'streaming' }
        s.messages.push(reply)
        s.started = true
        const words = '这是浏览器预览里的模拟回复，没有调用任何模型。真正的回复会从官方 CLI 流式返回，并以同样的方式逐段出现在这里。'.split('')
        let i = 0
        running.set(s.id, window.setInterval(() => {
          reply.text += words.slice(i, i + 3).join(''); i += 3
          if (i >= words.length) { reply.state = 'complete'; window.clearInterval(running.get(s.id)); running.delete(s.id) }
          push()
        }, 60))
        break
      }
      case 'chat.stop': {
        const t = running.get(c.sessionID); if (t) window.clearInterval(t); running.delete(c.sessionID)
        const last = sessions.get(c.sessionID)?.messages.at(-1); if (last?.state === 'streaming') last.state = 'cancelled'
        break
      }
      case 'viewport.save': { const x = boards.find(y => y.id === c.boardID); if (x) x.viewport = { x: c.x, y: c.y, zoom: c.zoom }; return }
      case 'clipboard.copy': void navigator.clipboard?.writeText(c.text); return
      case 'node.merge': {
        const x = boardNow()
        const sources = x.nodes.filter(n => c.nodeIDs.includes(n.id))
        const titles = { compare: '对比', summarize: '汇总', critique: '挑错' } as const
        const s = addSession(c.provider, `合流 · ${titles[c.template]}`)
        const n: NodePayload = { id: uid(), sessionID: s.id, x: Math.max(...sources.map(o => o.x)) + 340, y: sources.reduce((t, o) => t + o.y, 0) / sources.length, stale: false, downstream: 0, merge: titles[c.template] }
        histories.delete(x.id)
        x.nodes.push(n)
        for (const o of sources) x.edges.push({ id: uid(), kind: 'data', source: o.id, target: n.id, pending: true })
        push({ focusNodeID: n.id })
        emit({ type: 'composer.insert', sessionID: s.id, text: `（${titles[c.template]}模板）对比以上 ${sources.length} 个方案……` })
        return
      }
      case 'node.rerun': case 'chain.downstream': case 'chain.stop': break
      case 'session.setRules': { const s = sessions.get(c.sessionID); if (s) s.rules = c.text.trim() || undefined; break }
      case 'session.setModel': { const s = sessions.get(c.sessionID); if (s) s.modelID = c.modelID; break }
      case 'session.setEffort': if (c.effort) efforts.set(c.sessionID, c.effort); else efforts.delete(c.sessionID); break
      case 'provider.refresh': break
      case 'attachment.choose': drafts.set(c.sessionID, [...(drafts.get(c.sessionID) ?? []), { id: uid(), name: '示例文档.pdf', kind: 'pdf', bytes: 248_000 }]); break
      case 'attachment.remove': drafts.set(c.sessionID, (drafts.get(c.sessionID) ?? []).filter(f => f.id !== c.attachmentID)); break
      case 'source.createFiles': {
        histories.delete(c.boardID)
        const files = [file('示例文件.pdf', 'pdf', 248_000)]
        const n = sourceNode({ kind: 'files', title: filesTitle(files), updatedAt: Date.now(), importing: false, files }, c.x, c.y)
        boards.find(y => y.id === c.boardID)!.nodes.push(n)
        push({ focusNodeID: n.id }); return
      }
      case 'source.addFiles': { const n = nodeOf(c.boardID, c.nodeID); if (n?.source) { n.source.files.push(file('补充数据.csv', 'text', 9_800)); touch(n) } break }
      case 'source.removeFile': { const n = nodeOf(c.boardID, c.nodeID); if (n?.source) { n.source.files = n.source.files.filter(f => f.id !== c.attachmentID); touch(n) } break }
      case 'source.rename': {
        const n = nodeOf(c.boardID, c.nodeID)
        if (!n?.source) break
        if (c.title) customTitles.set(n.id, c.title); else customTitles.delete(n.id)
        n.source.title = c.title || (n.source.kind === 'mcp' ? (n.source.mcp?.toolName ?? 'MCP 结果') : filesTitle(n.source.files))
        break
      }
      case 'source.rerunMCP': {
        // Stand-in for running the tool again in the native workbench.
        const n = nodeOf(c.boardID, c.nodeID)
        if (!n?.source?.mcp || !window.confirm('浏览器预览：这里会打开原生 MCP 工作台并填好参数。模拟一次重新运行？')) return
        n.source.mcp = { ...n.source.mcp, text: n.source.mcp.text.replace('199', '219'), calledAt: Date.now() }
        touch(n); break
      }
      case 'app.open': window.alert(`浏览器预览：这里会打开原生的「${c.window}」窗口。`); return
    }
    push()
  }
}

/** Browser preview of the rule sources: a sample global rule plus the node's own. */
function mockRules(s?: MockSession): Pick<ContextPreview, 'rules' | 'rulesText' | 'rulesChannel'> {
  const global = '回答用中文；改代码前先说明计划。'
  const rules: RuleSourcePayload[] = [
    { title: 'AgentDesk 全局规则', characters: global.length, delivery: 'injected' },
    { title: '项目规则', characters: 420, delivery: 'native', path: '~/AgentDesk Projects/示例/AGENTS.md', note: '示例：由 CLI 自己读取' },
  ]
  const blocks = [`## AgentDesk 全局规则\n\n${global}`]
  if (s?.rules) { rules.push({ title: '本节点规则', characters: s.rules.length, delivery: 'injected' }); blocks.push(`## 本节点规则\n\n${s.rules}`) }
  return { rules, rulesText: '以下规则由 AgentDesk 提供，越靠后的优先级越高。\n\n' + blocks.join('\n\n'), rulesChannel: '浏览器预览' }
}
