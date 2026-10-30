import { describe, expect, it } from 'vitest'
import { nodeRulesLabel, ruleSourceLine } from './rules'

describe('rule sources', () => {
  it('names each source with its size and delivery', () => {
    expect(ruleSourceLine({ title: 'AgentDesk 全局规则', characters: 1234, delivery: 'injected' })).toBe('AgentDesk 全局规则 · 1,234 字 · AgentDesk 注入')
    expect(ruleSourceLine({ title: '项目规则', characters: 7, delivery: 'native', path: '~/p/AGENTS.md', note: 'Codex 自己读取' }))
      .toBe('项目规则 · 7 字 · CLI 自己读取 · ~/p/AGENTS.md · Codex 自己读取')
  })

  it('shows the node rules size on the button', () => {
    expect(nodeRulesLabel(null)).toBe('节点规则')
    expect(nodeRulesLabel('  ')).toBe('节点规则')
    expect(nodeRulesLabel('只改 src/api/')).toBe('节点规则 · 11 字')
  })
})
