import type { MemoryPayload } from './types'

/** The memory line in a panel: entry count and size against the budget. */
export function memorySummary(m: MemoryPayload): string {
  const size = `${m.characters.toLocaleString('zh-CN')} / ${m.budget.toLocaleString('zh-CN')} 字`
  return m.entries ? `项目记忆 ${m.entries} 条 · ${size}` : `项目记忆还是空的 · ${size}`
}

/** Above the budget AgentDesk asks the user to tidy up; nothing is deleted automatically. */
export function memoryOverBudget(m: MemoryPayload): boolean { return m.characters > m.budget }

/** The memory state for this panel's session, if Swift sent one. */
export function memoryFor(memory: MemoryPayload | undefined, sessionID: string): MemoryPayload | undefined {
  return memory?.sessionID === sessionID ? memory : undefined
}
