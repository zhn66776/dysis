// Mirrors the Swift bridge payloads (Sources/AgentDesk/CanvasBridge.swift).
// Protocol: design/CANVAS.md §4.2.

export type Provider = 'claude' | 'codex' | 'grok' | 'gemini'
export type SessionState = 'empty' | 'running' | 'complete' | 'failed' | 'cancelled'
export type MessageState = 'complete' | 'streaming' | 'failed' | 'cancelled'

export interface BoardSummary { id: string; title: string; nodeCount: number }

export interface NodePayload {
  id: string
  sessionID: string
  x: number
  y: number
  /** mode/reason are set until the node's first send; afterwards both are absent. */
  inherited?: { fromNodeID: string; messageCount: number; mode?: 'native' | 'replay'; reason?: string }
  /** Merge template title ("对比" / "汇总" / "挑错") for merge nodes. */
  merge?: string
  /** Answered before, but an upstream node has newer output. */
  stale: boolean
  /** How many nodes a downstream re-run from here would call. */
  downstream: number
}

export type MergeTemplate = 'compare' | 'summarize' | 'critique'

export interface Chain { boardID?: string; total: number; index: number; currentNodeID?: string }

export interface EdgePayload {
  id: string
  kind: 'inherit' | 'data'
  source: string
  target: string
  /** Data edges: the source has a reply the target has not received yet. */
  pending?: boolean
}

export interface BoardPayload {
  id: string
  title: string
  nodes: NodePayload[]
  edges: EdgePayload[]
  viewport?: { x: number; y: number; zoom: number }
}

export interface SessionSummary {
  id: string
  title: string
  provider: Provider
  modelID: string
  /** Matches ModelOption.key (for Cursor: the model family). */
  modelKey: string
  effort?: string
  remoteShort?: string
  /** Efforts the current model offers; empty when not discovered yet. */
  effortChoices: string[]
  state: SessionState
  status?: string
  preview: string
  messageCount: number
  updatedAt: number
  contextUsed?: number
  contextWindow?: number
}

export interface ModelOption { id: string; key: string; label: string }
export interface QuotaWindow { label: string; usedPercent: number; resetsAt?: number }
export interface Quota { windows: QuotaWindow[]; status?: string; updatedAt: number }
export interface DraftFile { id: string; name: string; kind: 'image' | 'pdf' | 'document' | 'text'; bytes: number }
export interface Draft { sessionID: string; files: DraftFile[]; importing: boolean }

export interface MessagePayload {
  id: string
  role: 'user' | 'assistant'
  text: string
  state: MessageState
  createdAt: number
  actualModels?: string[]
  attachments?: string[]
  contextSources?: string[]
}

export interface SessionDetail { id: string; messages: MessagePayload[] }

export interface TextAppend { sessionID: string; messageID: string; text: string }

export interface StatePayload {
  type: 'state'
  reset?: boolean
  boards?: BoardSummary[]
  board?: BoardPayload
  summaries?: SessionSummary[]
  removedSessions?: string[]
  details?: SessionDetail[]
  appends?: TextAppend[]
  models?: Partial<Record<Provider, ModelOption[]>>
  quotas?: Partial<Record<Provider, Quota>>
  drafts?: Draft[]
  chain: Chain
  running: string[]
  error: string
  focusNodeID?: string
}

export interface ComposerInsert { type: 'composer.insert'; sessionID: string; text: string }

/** Swift asks for an explicit yes before a destructive or call-spending action. */
export interface ConfirmShow { type: 'confirm.show'; id: string; title: string; detail: string; action: string }

/** Height of the transparent title bar and where the traffic lights end, in CSS px (0 in full screen). */
export interface ChromeInsets { type: 'chrome'; top: number; left: number }

export interface Region { x: number; y: number; w: number; h: number }

export type Incoming = StatePayload | ComposerInsert | ConfirmShow | ChromeInsets

export type Command =
  | { type: 'ready' }
  | { type: 'board.create' }
  | { type: 'board.select'; boardID: string }
  | { type: 'board.rename'; boardID: string; title: string }
  | { type: 'board.delete'; boardID: string }
  | { type: 'node.create'; boardID: string; provider: Provider; x: number; y: number; connectFrom?: string }
  | { type: 'node.move'; boardID: string; positions: { nodeID: string; x: number; y: number }[] }
  | { type: 'node.delete'; boardID: string; nodeIDs: string[] }
  | { type: 'node.rename'; sessionID: string; title: string }
  | { type: 'node.branch'; boardID: string; nodeID: string; messageID: string }
  | { type: 'edge.create'; boardID: string; source: string; target: string }
  | { type: 'edge.delete'; boardID: string; edgeIDs: string[] }
  | { type: 'session.watch'; sessionIDs: string[] }
  | { type: 'chat.send'; boardID: string; nodeID: string; text: string }
  | { type: 'chat.stop'; sessionID: string }
  | { type: 'viewport.save'; boardID: string; x: number; y: number; zoom: number }
  | { type: 'clipboard.copy'; text: string }
  | { type: 'app.open'; window: 'settings' | 'classic' | 'mcp'; sessionID?: string }
  | { type: 'error.dismiss' }
  | { type: 'session.setModel'; sessionID: string; modelID: string }
  | { type: 'session.setEffort'; sessionID: string; effort: string | null }
  | { type: 'provider.refresh'; provider: Provider }
  | { type: 'attachment.choose'; sessionID: string }
  | { type: 'attachment.remove'; sessionID: string; attachmentID: string }
  | { type: 'node.merge'; boardID: string; nodeIDs: string[]; provider: Provider; template: MergeTemplate }
  | { type: 'node.rerun'; boardID: string; nodeID: string }
  | { type: 'chain.downstream'; boardID: string; nodeID: string }
  | { type: 'chain.stop' }
  | { type: 'confirm.answer'; id: string; ok: boolean }
  | { type: 'chrome.regions'; drag: Region[]; noDrag: Region[] }

export interface AppState {
  ready: boolean
  boards: BoardSummary[]
  board: BoardPayload | null
  summaries: Record<string, SessionSummary>
  details: Record<string, SessionDetail>
  running: Set<string>
  error: string
  focusNodeID?: string
  models: Partial<Record<Provider, ModelOption[]>>
  quotas: Partial<Record<Provider, Quota>>
  drafts: Record<string, Draft>
  chain: Chain
}
