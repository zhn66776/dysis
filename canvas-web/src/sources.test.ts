import { describe, expect, it } from 'vitest'
import { composerHint, dataInputs, fileStats, formatStamp, imageNotes, sourcePreview, type DataInput } from './sources'
import type { BoardPayload, EdgePayload, SessionSummary, SourcePayload } from './types'

const files = (...kinds: ('image' | 'pdf' | 'text')[]): SourcePayload => ({
  kind: 'files', title: '资料包', updatedAt: 0, importing: false,
  files: kinds.map((kind, i) => ({ id: `f${i}`, name: `f${i}.${kind === 'image' ? 'png' : kind}`, kind, bytes: 1 << 20 })),
})
const mcp: SourcePayload = {
  kind: 'mcp', title: 'lookup', updatedAt: 0, importing: false, files: [],
  mcp: { serverName: 'fixture', toolName: 'lookup', arguments: '{}', text: '{\n  "rows": 3\n}', isError: false, calledAt: 0 },
}
const edge = (source: string, pending: boolean): EdgePayload => ({ id: `e-${source}`, kind: 'data', source, target: 't', pending })
const chat = (title: string, pending: boolean): DataInput => ({ edge: edge(title, pending), title, provider: 'claude' })
const src = (s: SourcePayload, pending: boolean): DataInput => ({ edge: edge(s.title, pending), title: s.title, source: s })

describe('source nodes', () => {
  it('summarises files by kind and size', () => {
    expect(fileStats(files('pdf', 'text', 'image').files)).toBe('2 个文档 · 1 张图片 · 3.0 MB')
    expect(fileStats(files('image').files)).toBe('1 张图片 · 1.0 MB')
    expect(fileStats([])).toBe('没有文件')
  })

  it('previews files and MCP text on one line', () => {
    expect(sourcePreview(files('pdf', 'image'))).toBe('f0.pdf、f1.png')
    expect(sourcePreview(mcp)).toBe('{ "rows": 3 }')
    expect(sourcePreview({ ...files(), importing: true })).toBe('正在读取文件…')
  })

  it('formats a local timestamp', () => {
    expect(formatStamp(new Date(2026, 9, 30, 9, 5).getTime())).toBe('10-30 09:05')
  })
})

describe('data-edge inputs', () => {
  it('lists chat upstreams and source nodes into one target', () => {
    const board: BoardPayload = {
      id: 'b', title: 'b', edges: [edge('a', true), edge('s', false), { id: 'x', kind: 'inherit', source: 'a', target: 't' }],
      nodes: [
        { id: 'a', sessionID: 'sa', x: 0, y: 0, stale: false, downstream: 0 },
        { id: 's', sessionID: 's', x: 0, y: 0, stale: false, downstream: 0, source: mcp },
        { id: 't', sessionID: 'st', x: 0, y: 0, stale: false, downstream: 0 },
      ],
    }
    const summaries = { sa: { id: 'sa', title: '调研', provider: 'codex' } as SessionSummary }
    const inputs = dataInputs(board, 't', summaries)
    expect(inputs.map(i => [i.title, i.provider, i.source?.kind])).toEqual([['调研', 'codex', undefined], ['lookup', undefined, 'mcp']])
  })

  it('composer hint names pending sources and waiting upstreams', () => {
    expect(composerHint([], false)).toBe('发送 1 次 · 可先预览输入')
    expect(composerHint([chat('a', true), chat('b', false)], false)).toBe('发送 1 次，带上 1 个上游输出（1 个还没有回复）')
    expect(composerHint([chat('a', true), src(files('pdf'), true), src(mcp, true)], false)).toBe('发送 1 次，带上 1 个上游输出、资料「资料包」「lookup」')
    expect(composerHint([src(mcp, true)], true)).toBe('发送 1 次，带上资料「lookup」')
    // Delivered already and nothing new: the default hint.
    expect(composerHint([chat('a', false), src(mcp, false)], true)).toBe('发送 1 次 · 可先预览输入')
  })

  it('explains skipped images for Cursor and the per-send cap otherwise', () => {
    const inputs = [src(files('pdf', 'image', 'image'), true), src(mcp, true)]
    expect(imageNotes(inputs, 'grok')).toEqual(['「资料包」里的 2 张图片不会发送：Cursor 连接不支持图片输入，只发送文档文字。'])
    expect(imageNotes(inputs, 'claude')).toEqual([])
    const many = [src({ ...files('image', 'image', 'image'), title: 'A' }, true), src({ ...files('image', 'image'), title: 'B' }, true)]
    expect(imageNotes(many, 'codex')).toHaveLength(1)
    expect(imageNotes(many.map(i => ({ ...i, edge: { ...i.edge, pending: false } })), 'codex')).toEqual([])
  })
})
