// Display logic for files / MCP result nodes and the data-edge inputs of a
// chat node. Pure, so it can be tested offline (sources.test.ts).
import type { BoardPayload, EdgePayload, FileKind, Provider, SessionSummary, SourceFile, SourcePayload } from './types'

export const kindLabel: Record<FileKind, string> = { image: '图片', pdf: 'PDF', document: '文档', text: '文本' }

export const formatBytes = (n: number) => n >= 1 << 20 ? `${(n / (1 << 20)).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`

const pad = (n: number) => String(n).padStart(2, '0')
/** Local "MM-DD hh:mm". */
export const formatStamp = (ms: number) => {
  const d = new Date(ms)
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

/** "2 个文档 · 1 张图片 · 3.4 MB" */
export function fileStats(files: SourceFile[]) {
  if (files.length === 0) return '没有文件'
  const images = files.filter(f => f.kind === 'image').length
  const docs = files.length - images
  const parts = [docs ? `${docs} 个文档` : '', images ? `${images} 张图片` : ''].filter(Boolean)
  return [...parts, formatBytes(files.reduce((t, f) => t + f.bytes, 0))].join(' · ')
}

/** Images one send can carry (MultimodalInputSupport.maxImages in Swift). */
export const maxImagesPerTurn = 4

export const acceptsImages = (p: Provider) => p === 'claude' || p === 'codex'

/** One data edge into a chat node: either another conversation or a source node. */
export interface DataInput {
  edge: EdgePayload
  title: string
  provider?: Provider
  source?: SourcePayload
}

export function dataInputs(board: BoardPayload, nodeID: string, summaries: Record<string, SessionSummary>): DataInput[] {
  return board.edges.filter(e => e.kind === 'data' && e.target === nodeID).map(edge => {
    const from = board.nodes.find(n => n.id === edge.source)
    if (from?.source) return { edge, title: from.source.title, source: from.source }
    const s = from ? summaries[from.sessionID] : undefined
    return { edge, title: s?.title ?? '未知节点', provider: s?.provider }
  })
}

/** What happens to images in connected files nodes; empty when they all go as images. */
export function imageNotes(inputs: DataInput[], target: Provider): string[] {
  const withImages = inputs.filter(i => i.source?.kind === 'files' && i.source.files.some(f => f.kind === 'image'))
  const count = (i: DataInput) => i.source!.files.filter(f => f.kind === 'image').length
  if (!acceptsImages(target)) {
    return withImages.map(i => `「${i.title}」里的 ${count(i)} 张图片不会发送：Cursor 连接不支持图片输入，只发送文档文字。`)
  }
  const pending = withImages.filter(i => i.edge.pending).reduce((t, i) => t + count(i), 0)
  return pending > maxImagesPerTurn ? [`资料里共有 ${pending} 张待发送的图片，一次最多发送 ${maxImagesPerTurn} 张，多出的会省略并在提示词里注明。`] : []
}

/** The line under the composer: what one send will carry. */
export function composerHint(inputs: DataInput[], started: boolean) {
  const chats = inputs.filter(i => !i.source)
  const pendingChats = chats.filter(i => i.edge.pending).length
  const waiting = chats.length - pendingChats
  const sources = inputs.filter(i => i.source && i.edge.pending)
  const parts: string[] = []
  // Before the first send every upstream conversation is listed, even those still empty.
  if (pendingChats > 0 || (!started && chats.length > 0)) parts.push(`${pendingChats} 个上游输出`)
  if (sources.length > 0) parts.push(`资料${sources.map(s => `「${s.title}」`).join('')}`)
  if (parts.length === 0) return '发送 1 次 · 可先预览输入'
  const carried = parts.join('、')
  return `发送 1 次，带上${/^\d/.test(carried) ? ' ' : ''}${carried}${!started && waiting > 0 ? `（${waiting} 个还没有回复）` : ''}`
}

/** Short body text of a source node on the canvas. */
export function sourcePreview(source: SourcePayload) {
  if (source.kind === 'mcp') return source.mcp?.text.replace(/\s+/g, ' ').trim() || '没有结果'
  if (source.files.length === 0) return source.importing ? '正在读取文件…' : '没有文件'
  return source.files.map(f => f.name).join('、')
}
