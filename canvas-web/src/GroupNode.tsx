import { memo, useRef, useState } from 'react'
import type { Node, NodeProps } from '@xyflow/react'
import { send } from './bridge'

export type GroupFlowNode = Node<{ groupID: string; boardID: string; title: string; count: number }, 'groupFrame'>

export const GroupNode = memo(function GroupNode({ data }: NodeProps<GroupFlowNode>) {
  const [renaming, setRenaming] = useState(false)
  const cancelled = useRef(false)
  return <div className="group-frame">
    <div className="group-handle" title="拖动标题栏移动整组；分组只整理画布，输入来源由连线决定">
      <span className="group-grip" aria-hidden="true">⠿</span>
      {renaming ? <input className="group-rename nodrag" autoFocus defaultValue={data.title} aria-label="分组名称" maxLength={100} onBlur={e => {
        const title = e.target.value.trim()
        if (!cancelled.current && title && title !== data.title) send({ type: 'group.rename', boardID: data.boardID, groupID: data.groupID, title })
        setRenaming(false)
      }} onKeyDown={e => {
        e.stopPropagation()
        if (e.nativeEvent.isComposing) return
        if (e.key === 'Enter') e.currentTarget.blur()
        if (e.key === 'Escape') { cancelled.current = true; setRenaming(false) }
      }} /> : <button className="group-title nodrag" aria-label={`重命名分组 ${data.title}`} onClick={() => { cancelled.current = false; setRenaming(true) }}>{data.title}</button>}
      <span className="group-count">{data.count} 个节点</span>
      <button className="group-dissolve nodrag" aria-label={`解散分组 ${data.title}`} title="解散分组并保留全部节点，可以撤销" onClick={() => send({ type: 'group.dissolve', boardID: data.boardID, groupID: data.groupID })}>解散</button>
    </div>
  </div>
})
