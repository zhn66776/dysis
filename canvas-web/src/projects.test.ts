import { describe, expect, it } from 'vitest'
import { projectStatus } from './projects'

describe('project boards', () => {
  it('names the trust state', () => {
    const p = { path: '~/AgentDesk Projects/交易', name: '交易', missing: false }
    expect(projectStatus({ ...p, trusted: true })).toBe('已信任 · 没有 git，同一时间一个节点写入')
    expect(projectStatus({ ...p, trusted: true, git: true })).toBe('已信任 · 每个节点一个 worktree')
    expect(projectStatus({ ...p, trusted: false })).toBe('只聊天')
    expect(projectStatus({ ...p, trusted: null })).toBe('还没决定是否信任')
    expect(projectStatus({ ...p, trusted: true, missing: true })).toBe('文件夹不存在')
  })
})
