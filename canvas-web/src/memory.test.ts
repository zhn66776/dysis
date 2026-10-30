import { describe, expect, it } from 'vitest'
import { memoryFor, memoryOverBudget, memorySummary } from './memory'
import { applyState, initialState } from './store'
import type { MemoryPayload, StatePayload } from './types'

const memory = (over: Partial<MemoryPayload> = {}): MemoryPayload => ({ sessionID: 's1', available: true, entries: 3, characters: 1200, budget: 4000, drafts: [], ...over })

describe('project memory', () => {
  it('summarises entries and size against the budget', () => {
    expect(memorySummary(memory())).toBe('项目记忆 3 条 · 1,200 / 4,000 字')
    expect(memorySummary(memory({ entries: 0, characters: 0 }))).toBe('项目记忆还是空的 · 0 / 4,000 字')
    expect(memoryOverBudget(memory())).toBe(false)
    expect(memoryOverBudget(memory({ characters: 4001 }))).toBe(true)
  })

  it('belongs to the panel it was sent for', () => {
    expect(memoryFor(memory(), 's1')?.entries).toBe(3)
    expect(memoryFor(memory(), 's2')).toBeUndefined()
    expect(memoryFor(undefined, 's1')).toBeUndefined()
  })

  it('keeps the last memory state until a reset', () => {
    const base: StatePayload = { type: 'state', running: [], error: '', chain: { total: 0, index: 0 } }
    const first = applyState(initialState, { ...base, memory: memory({ drafts: [{ id: 'd', text: '用 pnpm', author: '用户', fromModel: false }] }) })
    expect(first.memory?.drafts).toHaveLength(1)
    expect(applyState(first, base).memory?.drafts).toHaveLength(1)
    expect(applyState(first, { ...base, reset: true }).memory).toBeUndefined()
  })
})
