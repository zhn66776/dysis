import { describe, expect, it } from 'vitest'
import { applyState, initialState } from './store'
import type { StatePayload } from './types'

const summary = (id: string, title = id) => ({
  id, title, provider: 'claude' as const, modelID: 'sonnet', modelKey: 'sonnet', effortChoices: [], state: 'empty' as const,
  preview: '', messageCount: 0, updatedAt: 0,
})

const base: StatePayload = {
  type: 'state', reset: true, running: [], error: '', chain: { total: 0, index: 0 },
  boards: [{ id: 'b1', title: '画布', nodeCount: 1 }],
  board: { id: 'b1', title: '画布', nodes: [{ id: 'n1', sessionID: 's1', x: 0, y: 0, stale: false, downstream: 0 }], edges: [] },
  summaries: [summary('s1'), summary('s2')],
  details: [{ id: 's1', messages: [{ id: 'm1', role: 'assistant', text: '你好', state: 'streaming', createdAt: 0 }] }],
}

describe('applyState', () => {
  it('replaces everything on reset', () => {
    const s = applyState(initialState, base)
    expect(s.ready).toBe(true)
    expect(Object.keys(s.summaries)).toEqual(['s1', 's2'])
    expect(s.board?.nodes).toHaveLength(1)
  })

  it('appends streamed text to the right message only', () => {
    const s1 = applyState(initialState, base)
    const s2 = applyState(s1, { type: 'state', running: ['s1'], error: '', chain: { total: 0, index: 0 }, appends: [{ sessionID: 's1', messageID: 'm1', text: '，世界' }] })
    expect(s2.details.s1.messages[0].text).toBe('你好，世界')
    expect(s2.running.has('s1')).toBe(true)
    expect(s2.board).toBe(s1.board)
    expect(s1.details.s1.messages[0].text).toBe('你好')
  })

  it('keeps unchanged parts of a patch and drops removed sessions', () => {
    const s1 = applyState(initialState, base)
    const s2 = applyState(s1, { type: 'state', running: [], error: '出错了', chain: { total: 0, index: 0 }, summaries: [summary('s2', '改名')], removedSessions: ['s1'] })
    expect(s2.summaries.s2.title).toBe('改名')
    expect(s2.summaries.s1).toBeUndefined()
    expect(s2.details.s1).toBeUndefined()
    expect(s2.boards).toBe(s1.boards)
    expect(s2.error).toBe('出错了')
  })

  it('keeps models and quotas until Swift sends new ones', () => {
    const s1 = applyState(initialState, { ...base, models: { claude: [{ id: 'sonnet', key: 'sonnet', label: 'Sonnet' }] }, quotas: { codex: { windows: [{ label: '5 小时', usedPercent: 40 }], updatedAt: 0 } }, drafts: [{ sessionID: 's1', files: [], importing: true }] })
    const s2 = applyState(s1, { type: 'state', running: [], error: '', chain: { total: 0, index: 0 } })
    expect(s2.models.claude).toHaveLength(1)
    expect(s2.quotas.codex?.windows[0].usedPercent).toBe(40)
    expect(s2.drafts.s1.importing).toBe(true)
  })

  it('ignores appends for sessions that are not watched', () => {
    const s1 = applyState(initialState, base)
    const s2 = applyState(s1, { type: 'state', running: [], error: '', chain: { total: 0, index: 0 }, appends: [{ sessionID: 's2', messageID: 'x', text: 'lost' }] })
    expect(s2.details.s2).toBeUndefined()
  })
})

import { plainPreview } from './ChatNode'

describe('plainPreview', () => {
  it('strips Markdown punctuation for node bodies', () => {
    expect(plainPreview('1. **订阅制**：月付\n## 标题 [链接](https://x.y) `code`')).toBe('1. 订阅制：月付 标题 链接 code')
  })
})
