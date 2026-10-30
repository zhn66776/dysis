import type { BoardProject } from './types'

/** The sidebar line under a project board. */
export function projectStatus(p: BoardProject): string {
  if (p.missing) return '文件夹不存在'
  return p.trusted === true ? '已信任 · 可读写和运行命令' : p.trusted === false ? '只聊天' : '还没决定是否信任'
}
