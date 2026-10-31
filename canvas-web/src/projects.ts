import { levelLabel } from './harness'
import type { BoardProject } from './types'

/** The sidebar line under a project board. */
export function projectStatus(p: BoardProject): string {
  if (p.missing) return '文件夹不存在'
  if (p.trusted === true) return `已信任 · ${levelLabel[p.level ?? 'auto']} · ${p.git ? '每个节点一个 worktree' : '没有 git，同一时间一个节点写入'}`
  return p.trusted === false ? '只聊天' : '还没决定是否信任'
}
