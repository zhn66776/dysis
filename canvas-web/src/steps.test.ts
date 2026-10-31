import { describe, expect, it } from 'vitest'
import { diffLabel, diffLineClass, exitLabel, splitDiff, stepsSummary } from './steps'
import type { StepPayload } from './types'

const diff = [
  'diff --git a/README.md b/README.md',
  'index 1111111..2222222 100644',
  '--- a/README.md',
  '+++ b/README.md',
  '@@ -1 +1,2 @@',
  ' hello',
  '+world',
  'diff --git a/src/new.swift b/src/new.swift',
  'new file mode 100644',
  '--- /dev/null',
  '+++ b/src/new.swift',
  '@@ -0,0 +1,2 @@',
  '+let x = 1',
  '+let y = 2',
  'diff --git a/old.txt b/old.txt',
  'deleted file mode 100644',
  '--- a/old.txt',
  '+++ /dev/null',
  '@@ -1 +0,0 @@',
  '-gone',
].join('\n')

describe('steps and diffs', () => {
  it('labels a diff stat like the node card', () => {
    expect(diffLabel({ files: 2, added: 13, removed: 1 })).toBe('改了 2 个文件 +13 −1')
  })

  it('splits a git diff per file and counts lines', () => {
    const files = splitDiff(diff)
    expect(files.map(f => [f.path, f.added, f.removed])).toEqual([['README.md', 1, 0], ['src/new.swift', 2, 0], ['old.txt', 0, 1]])
    expect(files[0].body.startsWith('diff --git a/README.md')).toBe(true)
    expect(splitDiff('')).toEqual([])
  })

  it('classes diff lines', () => {
    expect(diffLineClass('+++ b/x')).toBe('dl-head')
    expect(diffLineClass('@@ -1 +1 @@')).toBe('dl-hunk')
    expect(diffLineClass('+a')).toBe('dl-add')
    expect(diffLineClass('-a')).toBe('dl-del')
    expect(diffLineClass(' a')).toBe('')
  })

  it('summarises steps and exit codes', () => {
    const steps: StepPayload[] = [
      { id: '1', kind: 'command', title: 'swift test', state: 'failed', exitCode: 1 },
      { id: '2', kind: 'fileChange', title: 'a.swift', state: 'done' },
      { id: '3', kind: 'command', title: 'rm -rf build', state: 'declined' },
      { id: '4', kind: 'read', title: 'b.swift', state: 'running' },
    ]
    expect(stepsSummary(steps)).toBe('4 个步骤 · 1 个失败 · 1 个被拒绝 · 进行中')
    expect(exitLabel(steps[0])).toBe('退出码 1')
    expect(exitLabel(steps[1])).toBe('')
  })
})
