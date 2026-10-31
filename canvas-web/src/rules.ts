import type { RuleSourcePayload } from './types'

/** One line of the context preview's rule list: title, size, how it arrives. */
export function ruleSourceLine(r: RuleSourcePayload): string {
  const how = r.delivery === 'native' ? 'CLI 自己读取' : 'AgentDesk 注入'
  return [r.title, `${r.characters.toLocaleString('zh-CN')} 字`, how, r.path, r.note].filter(Boolean).join(' · ')
}

/** The node rules button label: how many characters the node's own rules have. */
export function nodeRulesLabel(rules?: string | null): string {
  const n = rules?.trim().length ?? 0
  return n ? `节点规则 · ${n.toLocaleString('zh-CN')} 字` : '节点规则'
}
