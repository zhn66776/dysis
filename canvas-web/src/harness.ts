import type { ApprovalShow, HarnessMode, PermissionLevel, Provider } from './types'

export const levels: PermissionLevel[] = ['readOnly', 'ask', 'auto']

export const levelLabel: Record<PermissionLevel, string> = { readOnly: '只读', ask: '询问', auto: '自动' }

export const levelDetail: Record<PermissionLevel, string> = {
  readOnly: '读文件；改文件、运行命令、联网前先问',
  ask: '读、改项目文件；运行命令、联网前先问',
  auto: '改文件、运行命令、联网都不再询问',
}

/** 聊天 / 项目 · 只读 / 项目 · 询问 / 项目 · 自动. */
export function modeLabel(mode: HarnessMode): string {
  return mode === 'chat' ? '聊天' : `项目 · ${levelLabel[mode]}`
}

/** Levels a node may pick: the board's and the ones below it. */
export function nodeLevelChoices(boardLevel: PermissionLevel): PermissionLevel[] {
  return levels.slice(0, levels.indexOf(boardLevel) + 1)
}

/** Cursor's --print cannot ask, so below 自动 it gets static rules; say what that means. */
export function cursorNote(provider: Provider, mode: HarnessMode | undefined): string | null {
  if ((provider !== 'grok' && provider !== 'gemini') || !mode || mode === 'chat' || mode === 'auto') return null
  return mode === 'ask'
    ? 'Cursor 不能逐条确认：这一档只能读写项目文件，不能运行命令。需要运行命令请改用 Codex 或 Claude Code 节点。'
    : 'Cursor 不能逐条确认：这一档只读，不能改文件或运行命令。'
}

/** Cards waiting for an answer, oldest first. */
export function enqueueApproval(queue: ApprovalShow[], request: ApprovalShow): ApprovalShow[] {
  return queue.some(a => a.id === request.id) ? queue : [...queue, request]
}

export function resolveApproval(queue: ApprovalShow[], id: string): ApprovalShow[] {
  return queue.filter(a => a.id !== id)
}

export function approvalsFor(queue: ApprovalShow[], sessionID: string): ApprovalShow[] {
  return queue.filter(a => a.sessionID === sessionID)
}
