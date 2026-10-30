import { describe, expect, it } from 'vitest'
import { approvalsFor, cursorNote, enqueueApproval, modeLabel, nodeLevelChoices, resolveApproval } from './harness'
import { providerName, providerSubtitle } from './providers'
import type { ApprovalShow } from './types'

describe('harness names and modes (H0)', () => {
  it('names the harness, not the chat product', () => {
    expect(providerName).toEqual({ claude: 'Claude Code', codex: 'Codex', grok: 'Cursor · Grok', gemini: 'Cursor · Gemini' })
    expect(providerSubtitle('codex')).toBe('Codex · ChatGPT 账号')
    expect(providerSubtitle('claude')).toBe('Claude Code · Claude 订阅')
    expect(Object.values(providerName).some(n => n.includes('ChatGPT'))).toBe(false)
  })

  it('labels the four modes', () => {
    expect(modeLabel('chat')).toBe('聊天')
    expect(modeLabel('readOnly')).toBe('项目 · 只读')
    expect(modeLabel('ask')).toBe('项目 · 询问')
    expect(modeLabel('auto')).toBe('项目 · 自动')
  })

  it('lets a node only go lower than its board', () => {
    expect(nodeLevelChoices('auto')).toEqual(['readOnly', 'ask', 'auto'])
    expect(nodeLevelChoices('ask')).toEqual(['readOnly', 'ask'])
    expect(nodeLevelChoices('readOnly')).toEqual(['readOnly'])
  })

  it('says what Cursor cannot do below 自动', () => {
    expect(cursorNote('grok', 'ask')).toContain('不能运行命令')
    expect(cursorNote('gemini', 'readOnly')).toContain('只读')
    expect(cursorNote('grok', 'auto')).toBeNull()
    expect(cursorNote('grok', 'chat')).toBeNull()
    expect(cursorNote('codex', 'ask')).toBeNull()
  })
})

describe('approval queue (H1)', () => {
  const card = (id: string, sessionID: string): ApprovalShow => ({ type: 'approval.show', id, sessionID, kind: 'command', title: '运行命令', command: 'ls', files: [], expiresAt: 0 })

  it('queues in order, ignores repeats, and drops answered cards', () => {
    let q = enqueueApproval([], card('a', 's1'))
    q = enqueueApproval(q, card('b', 's2'))
    q = enqueueApproval(q, card('c', 's1'))
    q = enqueueApproval(q, card('a', 's1'))
    expect(q.map(a => a.id)).toEqual(['a', 'b', 'c'])
    expect(approvalsFor(q, 's1').map(a => a.id)).toEqual(['a', 'c'])
    q = resolveApproval(q, 'a')
    expect(approvalsFor(q, 's1').map(a => a.id)).toEqual(['c'])
  })
})
