// Mirrors the Swift bridge payloads (Sources/AgentDesk/CanvasBridge.swift).
// Protocol: design/CANVAS.md §4.2.

export type Provider = 'claude' | 'codex' | 'grok' | 'gemini'
/** waiting: running, but paused on an approval only the user can answer. */
export type SessionState = 'empty' | 'running' | 'waiting' | 'complete' | 'failed' | 'cancelled'
export type MessageState = 'complete' | 'streaming' | 'failed' | 'cancelled'

/** Permission levels of a trusted project (design/HARNESS.md H1). */
export type PermissionLevel = 'readOnly' | 'ask' | 'auto'
/** What a conversation runs with: chat, or a project at a level. */
export type HarnessMode = 'chat' | PermissionLevel

/** A board's project folder; trusted is null until asked; level is set once trusted. */
export interface BoardProject { path: string; name: string; trusted: boolean | null; missing: boolean; level?: PermissionLevel | null }
/** waiting: nodes waiting for an approval. */
export interface BoardSummary { id: string; title: string; nodeCount: number; project?: BoardProject | null; waiting?: number }

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
  /** Files and MCP result nodes: read-only material, only ever a data-edge source. */
  source?: SourcePayload
  /** Chat nodes: the mode this node's next turn runs in. */
  mode?: HarnessMode
  /** The node's own lower level, when set. */
  nodeLevel?: PermissionLevel
}

export type FileKind = 'image' | 'pdf' | 'document' | 'text'

export interface SourceFile { id: string; name: string; kind: FileKind; bytes: number; note?: string }

export interface SourcePayload {
  kind: 'files' | 'mcp'
  title: string
  updatedAt: number
  /** Files are being copied and read. */
  importing: boolean
  files: SourceFile[]
  mcp?: { serverName: string; toolName: string; arguments: string; text: string; isError: boolean; calledAt: number }
}

export type MergeTemplate = 'compare' | 'summarize' | 'critique'

export interface Chain { boardID?: string; total: number; index: number; currentNodeID?: string }

export interface EdgePayload {
  id: string
  kind: 'inherit' | 'data'
  source: string
  target: string
  /** Data edges: the source has a reply the target has not received yet. */
  sourceMessageID?: string
  pending?: boolean
}

export interface CanvasGroup { id: string; title: string; nodeIDs: string[] }
export interface CanvasHistory { undoLabel?: string; redoLabel?: string }
export interface NodeSize { nodeID: string; width: number; height: number }

export interface BoardPayload {
  id: string
  title: string
  nodes: NodePayload[]
  edges: EdgePayload[]
  groups?: CanvasGroup[]
  history?: CanvasHistory
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
  latestReplyID?: string
  contextUsed?: number
  contextWindow?: number
}

export interface ModelOption { id: string; key: string; label: string }
export interface QuotaWindow { label: string; usedPercent: number; resetsAt?: number }
export interface Quota { windows: QuotaWindow[]; status?: string; updatedAt: number }
export interface DraftFile { id: string; name: string; kind: FileKind; bytes: number }
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
  fitBoardID?: string
  focusNodeID?: string
}

export interface ComposerInsert { type: 'composer.insert'; sessionID: string; text: string }

/** Swift asks for an explicit yes before a destructive or call-spending action. */
export interface ConfirmShow { type: 'confirm.show'; id: string; title: string; detail: string; action: string }

/** Height of the transparent title bar and where the traffic lights end, in CSS px (0 in full screen). */
export interface ChromeInsets { type: 'chrome'; top: number; left: number }

export interface Region { x: number; y: number; w: number; h: number }

export interface SearchHit { nodeID: string; messageID?: string; excerpt: string }
export interface SearchResults { type: 'search.results'; id: string; boardID: string; query: string; hits: SearchHit[] }
/** harness: the read-only "本轮的 harness 设置" lines. */
export interface ContextPreview { type: 'context.preview'; id: string; nodeID: string; text: string; notes: string[]; harness?: string[] }

export type ApprovalKind = 'command' | 'fileChange' | 'network' | 'tool'
export type ApprovalDecision = 'once' | 'conversation' | 'deny'
/** A CLI asks before an action its permission level does not allow; the turn waits. */
export interface ApprovalShow {
  type: 'approval.show'; id: string; sessionID: string; kind: ApprovalKind; title: string
  command?: string; cwd?: string; files: string[]; diff?: string; reason?: string
  /** What "本会话内都允许" covers. */
  sessionScope?: string
  /** No answer by then is a no (ms since 1970). */
  expiresAt: number
}
/** Answered elsewhere, timed out, or the turn stopped. */
export interface ApprovalHide { type: 'approval.hide'; id: string }
export type Incoming = StatePayload | ComposerInsert | ConfirmShow | ChromeInsets | SearchResults | ContextPreview | ApprovalShow | ApprovalHide

export type Command =
  | { type: 'ready' }
  | { type: 'board.create' }
  | { type: 'board.layout'; boardID: string; sizes: NodeSize[] }
  | { type: 'board.undo' | 'board.redo'; boardID: string }
  | { type: 'group.create'; boardID: string; nodeIDs: string[] }
  | { type: 'group.add'; boardID: string; groupID: string; nodeIDs: string[] }
  | { type: 'group.rename'; boardID: string; groupID: string; title: string }
  | { type: 'group.dissolve'; boardID: string; groupID: string }
  | { type: 'board.select'; boardID: string }
  | { type: 'board.rename'; boardID: string; title: string }
  | { type: 'board.delete'; boardID: string }
  | { type: 'board.linkFolder' | 'board.reveal'; boardID: string }
  | { type: 'board.trust'; boardID: string; ok: boolean }
  | { type: 'node.create'; boardID: string; provider: Provider; x: number; y: number; connectFrom?: string }
  | { type: 'node.move'; boardID: string; positions: { nodeID: string; x: number; y: number }[] }
  | { type: 'node.delete'; boardID: string; nodeIDs: string[] }
  | { type: 'node.rename'; sessionID: string; title: string }
  | { type: 'board.search'; boardID: string; text: string; id: string }
  | { type: 'context.preview'; boardID: string; nodeID: string; text: string; id: string }
  | { type: 'node.quote'; boardID: string; nodeID: string; messageID: string }
  | { type: 'node.branch'; boardID: string; nodeID: string; messageID: string }
  | { type: 'edge.create'; boardID: string; source: string; target: string }
  | { type: 'edge.delete'; boardID: string; edgeIDs: string[] }
  | { type: 'session.watch'; sessionIDs: string[]; panelSessionID?: string }
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
  | { type: 'approval.answer'; id: string; decision: ApprovalDecision }
  | { type: 'board.setLevel'; boardID: string; level: PermissionLevel }
  | { type: 'node.setLevel'; boardID: string; nodeID: string; level: PermissionLevel | null }
  | { type: 'chrome.regions'; drag: Region[]; noDrag: Region[] }
  | { type: 'source.createFiles'; boardID: string; x: number; y: number }
  | { type: 'source.addFiles'; boardID: string; nodeID: string }
  | { type: 'source.removeFile'; boardID: string; nodeID: string; attachmentID: string }
  | { type: 'source.rename'; boardID: string; nodeID: string; title: string }
  | { type: 'source.rerunMCP'; boardID: string; nodeID: string }

export interface AppState {
  ready: boolean
  boards: BoardSummary[]
  board: BoardPayload | null
  summaries: Record<string, SessionSummary>
  details: Record<string, SessionDetail>
  running: Set<string>
  error: string
  fitBoardID?: string
  focusNodeID?: string
  models: Partial<Record<Provider, ModelOption[]>>
  quotas: Partial<Record<Provider, Quota>>
  drafts: Record<string, Draft>
  chain: Chain
}
