import { levelLabel } from './harness'
import type { BoardProject } from './types'

/** The sidebar line under a project board. */
export function projectStatus(p: BoardProject): string {
  if (p.missing) return '文件夹不存在'
  if (p.trusted === true) return `已信任 · ${levelLabel[p.level ?? 'auto']}`
  return p.trusted === false ? '只聊天' : '还没决定是否信任'
}
