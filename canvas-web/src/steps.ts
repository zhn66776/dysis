// Display logic for tool steps and turn diffs (HARNESS.md H3). Pure, so it
// can be tested offline (steps.test.ts).
import type { DiffStat, StepKind, StepPayload, StepState } from './types'

/** "改了 N 个文件 +a −b" */
export const diffLabel = (s: DiffStat) => `改了 ${s.files} 个文件 +${s.added} −${s.removed}`

export const stepKindLabel: Record<StepKind, string> = {
  command: '命令', fileChange: '改文件', mcp: 'MCP', read: '读取', search: '搜索', web: '网页', other: '工具',
}

export const stepStateLabel: Record<StepState, string> = { running: '进行中', done: '完成', failed: '失败', declined: '已拒绝' }

/** One line under the reply: "3 个步骤 · 1 个失败 · 进行中". */
export function stepsSummary(steps: StepPayload[]) {
  const failed = steps.filter(s => s.state === 'failed').length
  const declined = steps.filter(s => s.state === 'declined').length
  const running = steps.some(s => s.state === 'running')
  return [`${steps.length} 个步骤`, failed ? `${failed} 个失败` : '', declined ? `${declined} 个被拒绝` : '', running ? '进行中' : ''].filter(Boolean).join(' · ')
}

/** Exit code badge for commands: shown when known. */
export const exitLabel = (s: StepPayload) => s.exitCode === undefined ? '' : `退出码 ${s.exitCode}`

export interface FileDiff { path: string; body: string; added: number; removed: number }

/** Splits a unified `git diff` into files, counting lines added and removed. */
export function splitDiff(diff: string): FileDiff[] {
  const files: FileDiff[] = []
  let current: FileDiff | null = null
  let inHeader = false
  for (const line of diff.split('\n')) {
    const header = /^diff --git a\/(.*?) b\/(.*)$/.exec(line)
    if (header) {
      current = { path: header[2], body: line, added: 0, removed: 0 }
      files.push(current); inHeader = true; continue
    }
    if (!current) continue
    current.body += '\n' + line
    if (line.startsWith('@@')) { inHeader = false; continue }
    if (inHeader) {
      const renamed = /^\+\+\+ b\/(.*)$/.exec(line)
      if (renamed) current.path = renamed[1]
      continue
    }
    if (line.startsWith('+')) current.added++
    else if (line.startsWith('-')) current.removed++
  }
  return files
}

/** CSS class for one diff line. */
export const diffLineClass = (line: string) =>
  line.startsWith('+++') || line.startsWith('---') || line.startsWith('diff --git') || line.startsWith('index ') ? 'dl-head'
    : line.startsWith('@@') ? 'dl-hunk' : line.startsWith('+') ? 'dl-add' : line.startsWith('-') ? 'dl-del' : ''
