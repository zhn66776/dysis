// Mirrors the Swift bridge payloads (Sources/AgentDesk/CanvasBridge.swift).
// Protocol: design/CANVAS.md §4.2.

export type Provider = 'claude' | 'codex' | 'grok' | 'gemini'
export type SessionState = 'empty' | 'running' | 'complete' | 'failed' | 'cancelled'
export type MessageState = 'complete' | 'streaming' | 'failed' | 'cancelled'

/** A board's project folder; trusted is null until asked. */
export interface BoardProject { path: string; name: string; trusted: boolean | null; missing: boolean }
export interface BoardSummary { id: string; title: string; nodeCount: number; project?: BoardProject | null }

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
  /** The node's own rules (third rule layer), sent after the global ones. */
  rules?: string | null
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
/** One active rule source this turn: injected by AgentDesk or read by the CLI itself. */
export interface RuleSourcePayload { title: string; characters: number; delivery: 'injected' | 'native'; path?: string; note?: string }
export interface ContextPreview {
  type: 'context.preview'; id: string; nodeID: string; text: string; notes: string[]
  rules?: RuleSourcePayload[]
  /** The injected rules exactly as sent; empty when nothing is injected. */
  rulesText?: string
  /** Where the injected rules go for this provider. */
  rulesChannel?: string
}
export type Incoming = StatePayload | ComposerInsert | ConfirmShow | ChromeInsets | SearchResults | ContextPreview

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
  | { type: 'app.open'; window: 'project'; boardID: string }
  | { type: 'session.setRules'; sessionID: string; text: string }
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
