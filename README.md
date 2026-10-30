# AgentDesk

A personal, native macOS SwiftUI chat app. Each conversation belongs to one provider and keeps its own official session ID, local transcript and working directory.

## Included in 0.3.0

- Claude through the official Claude Code CLI, using Claude subscription login.
- ChatGPT through the official Codex app-server, using managed ChatGPT login.
- Grok and Gemini through the official Cursor CLI and the user's existing Cursor plan. Gemini here does not consume Google AI Pro quota.
- Streaming responses, stop generation, separate concurrent conversations, local history, rename, search and delete local records.
- Provider settings, connection checks and model discovery. Connection checks do not start model turns.

AgentDesk adds a bounded Plaza discussion coordinator and a user-operated MCP workbench to the existing private chats. Model execution and subscription authentication still belong to the official CLIs. Trading execution, automatic model-directed MCP calls, and DeepSeek are not implemented. It does not collect OAuth tokens or API keys. Official tools remain responsible for authentication. Keep additional/overage usage disabled in each provider's billing settings if you only want included usage; this app cannot enforce a provider's server-side billing switch.

## Build and run

Requires macOS 14 or later, an installed Xcode/Swift toolchain and Node.js with npm (for the canvas page). No third-party Swift dependencies; the canvas page uses React, React Flow and react-markdown (MIT).

```sh
swift test
bash scripts/build-app.sh
open build/AgentDesk.app
```

CI (`.github/workflows/ci.yml`) runs `swift test` and the canvas page's `npm ci`, `npm test` and `npm run build` on a macOS runner for every push and pull request; tests use fixture CLIs only, with no official CLI, login or model call.

Open `Package.swift` in Xcode to develop the app. The build script produces a locally ad-hoc-signed `.app`, not a notarized distribution.

## Official login

Developer mode in Settings shows commands using the actual configured executable paths. Press Cmd+Shift+D to show those controls. Complete login in your terminal and browser:

```sh
~/.local/bin/claude auth login
codex login
~/.local/bin/agent login
```

Do not use Console/API-key login for the subscription-only routes. Grok/Gemini models are explicitly selected, with no fallback to another provider. Use Settings → Discover Models to choose IDs available to the signed-in account. Existing conversations retain their model; settings affect new conversations.

For Claude, Settings → Select Version lists documented full model IDs, including Opus 5.5 (`claude-opus-5-5`) and Opus 5 (`claude-opus-5`), separately from floating `opus`/`sonnet`/`haiku` aliases. This bundled catalog is not a live account-entitlement check. The adapter forwards the chosen ID to the official CLI and shows actual model metadata returned in new replies. An unavailable version is reported by the CLI; AgentDesk does not silently replace your selection. Changing the default affects only newly created conversations, including when an older conversation is still empty.

## Canvas (0.4.0 – 0.5.0)

The main window is now an infinite canvas (design: [design/CANVAS.md](design/CANVAS.md)). A board is one larger goal; each node is one conversation with its own provider, model, official session ID and workspace. Existing conversations are placed on an "已有对话" board on first launch; layout is stored in `canvases.json` next to `sessions.json`.

- **Branch from a reply** creates a child node with an inherit edge. On the child's first send it inherits the parent's history: Claude → Claude forks natively with `--resume … --fork-session` when the fork point is the parent's latest message; Codex → Codex forks with app-server `thread/fork` through the recorded turn (`lastTurnId`). Otherwise (Grok/Gemini, cross-provider, a Claude parent that moved on, or a previous fork failure) the ancestors' text is replayed in front of the typed message (no tool calls or images). The panel shows which mode applies and why (0.4.1).
- **Data edges** (drag from a node's right port to another node) pass the source's latest complete reply once per new reply. Dragging to empty space creates a connected downstream node.
- Each send is still exactly one provider call. Deleting nodes or boards asks for confirmation and removes only local records.
- The page is a React + React Flow bundle in `canvas-web/`, loaded from the app bundle over `agentdesk://app/` with a CSP that blocks network access. It sends typed commands to Swift; sessions, files and model turns stay native.
- The panel header picks the node's **model** and **reasoning effort** for the next message (disabled while replying). Cursor efforts are effort-variant model IDs of the same family, as in the classic window.
- **Context** shows the tokens in the conversation after the latest reply, against the model's window: Claude from the result `usage`/`modelUsage.contextWindow`, Codex from `thread/tokenUsage/updated`. Cursor does not report it.
- **Remaining quota** shows the tightest subscription window (hover for all windows and reset times). Codex is read with app-server `account/rateLimits/read` when a Codex panel opens (an account query, no model turn; at most once a minute). Claude Code reports it as `rate_limit_event` during replies, so it appears after the first reply of the launch. Cursor does not report it. Quota is kept in memory only.
- The composer's **＋** menu adds images or documents (same limits and processing as the classic window) and opens the MCP workbench, whose result is inserted into the composer. Files can also be dropped onto the window; they go to the open conversation.
- **Merge nodes** (0.5.0): ⌘/Shift/Ctrl-click or Shift-drag to pick 2–8 nodes, then choose a provider and a template (对比 / 汇总 / 挑错). A new node with one data edge per source opens with the template in its composer; nothing is sent until you press send (one call).
- **Stale answers and downstream re-runs** (0.5.0): a node that answered before but has undelivered upstream output is marked “上游已更新”. Its panel offers “用新输入重新回答” (one call). A node whose direct downstream is stale shows “重跑下游 N”; after a native confirmation listing the N calls and their order, the nodes re-run one by one in dependency order, stopping at the first one that does not complete (at most 12, cancellable). Nothing re-runs on its own.
- Plaza, dictation and export remain in the **经典界面** window (sidebar button) until they move onto the canvas.

Frontend development: `cd canvas-web && npm ci && npm run dev` opens a browser preview with a local mock host (no model calls). `npm test` runs the frontend state tests. `scripts/build-app.sh` builds the page and copies it into `Contents/Resources/Canvas`.

## Canvas reading and context (0.6.0)

- **展开阅读 / 收起** reads the full latest reply on the canvas, including Markdown, tables and code. Up to six cards can stay expanded (opening a seventh folds the oldest); expanded cards scroll independently; expanding a card does not open a chat or start a model turn.
- Every card has **追问 / 分支 / 引用**. Follow-up opens the existing conversation and focuses its composer. Branch inherits history through the selected complete reply. Quote creates an independent conversation with one data edge fixed to that exact reply; subsequent source replies do not replace it. Branches and quotations copy the source model and reasoning setting. Both start only when the user sends a message. The same actions are available on individual replies in the panel.
- **预览本轮输入** (also available by clicking an upstream chip) uses the same native text and attachment assembly as sending. It shows the current additional prompt, truncation markers and source reply numbers, distinguishing fixed quotations from live inputs and newly delivered content from earlier deliveries. Existing official session history and native-fork internals are identified separately; image inputs are separate from the text preview. Preview does not call a model. Sending reads the inputs again, so refresh the preview after upstream changes. Disconnecting an edge stops future input; material already in a provider session remains in that session history.
- **搜索画布与历史** / **⌘F** searches titles and full local message history on the current board. Click a result (or use arrows and Enter) to locate its node and highlight the matching historical message. Search does not send material to a model or network service.

## Canvas organization (0.7.0)

- **小地图** shows conversations, file/MCP sources and groups. Drag it to pan or scroll to zoom; its toolbar button shows or hides it for the current board view.
- **自动布局** arranges the current board from inputs to outputs, using the rendered card sizes (including expanded replies). Group members stay together; independent nodes use a grid. Layout changes only positions and can be undone.
- Select nodes with ⌘/Shift-click or Shift-drag, then choose **分组 → 创建分组** or **加入…**. Groups can contain conversations and source nodes. Click a group title to rename it, drag its title bar to move every member, or choose **解散** to keep the nodes without the frame. Group membership is saved in the canvas file and does not add model context.
- **↶ / ↷**, **⌘Z / ⇧⌘Z** undo or redo node moves, layout, connections, group membership, group names and dissolution. A group move is one edit. Each board keeps up to 100 edits during the current app launch; switching boards keeps their separate histories. Text fields keep their normal text undo. Model runs, replies, source contents and viewport navigation remain independent of canvas edit history. Creating or deleting nodes starts a new edit history for that board; local record deletion still requires confirmation and is not restored by canvas undo.

## Chat bubbles, files, export and dictation (0.3.0)

Private chats and Plaza discussions use right-aligned user bubbles and left-aligned agent bubbles. Input supports the **附件** button and file drops; each conversation keeps its own pending selection. Files are copied into `Attachments/<UUID>/` under the app data directory and referenced by relative paths in saved history. Originals outside the app are not changed.

- Add up to six files per message (up to four images), with a 20 MB source-file limit. ImageIO validates images and creates a JPEG copy with longest edge at most 3072 px and size at most 4 MB for model input; the original is retained.
- Claude uses official Claude Code's stream-json input with the image content-block structure used by Anthropic's official Agent SDK. Codex uses app-server `localImage` inputs and checks advertised image capability. These routes have offline protocol tests; no new live inference requests were made during implementation.
- The current Cursor CLI route does not expose native image input, so Grok/Gemini reject image attachments explicitly. Select Claude/ChatGPT, or remove the image and send extracted document text. A mixed group will reject an image send if a selected member cannot receive it.
- PDF and Word (`.doc`/`.docx`) are locally converted to text using PDFKit/macOS importers. Text documents are also accepted. Embedded figures, document layout and scanned pages are not sent as document vision. PDFs without extractable text are rejected before sending with an OCR explanation. Long files/context are bounded and omissions are marked. Images must be attached separately when their visual content matters.
- Each reply has **导出** for PDF, PNG or text. A Plaza can also export its transcript. Export renders the response locally after a Save dialog; it is not a model-generated illustration or an autonomous arbitrary-file execution feature.
- **听写** uses Apple Speech on-device recognition with Chinese and English choices, a 60-second limit and explicit stop. Microphone/speech authorization is requested only after clicking. Audio is not silently sent to a cloud fallback. If the current language/device lacks local recognition, the app explains this. Text remains editable and is never automatically sent. Closing the composer or sending stops recording. Live microphone recognition has not been tested because no audio/permission was supplied during development.

In a group, new attachments go to the selected participants for that run. Members retain their own official histories; public cross-member history contains the textual transcript, not an automatic copy of every prior image. Reattach a prior image when bringing a new member into its visual analysis.

Image input references: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [Anthropic official streaming client](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/client.py). The app's existing read-only/tool-disabled provider policy and meeting limits remain in effect.

## Settings and provider marks (0.2.2)

Ordinary Settings shows model selection, reasoning strength, and connection/model discovery. Executable paths, terminal login commands and integration diagnostics are shown in **开发者模式**. Toggle it with **Cmd+Shift+D** or the AgentDesk application menu. The mode is shared by Settings windows during the current app launch and starts off after relaunch. Hiding these fields preserves their configured values; the mode controls presentation only.

Provider symbols now use bundled SVG marks across the sidebar, conversation avatars, member panels, Settings and new-chat menus. Assets are loaded locally with native macOS image rendering; the app makes no network request for icons. ChatGPT/OpenAI and Grok have light/dark variants. Source and attribution records are in [Claude/OpenAI sources](Resources/ProviderIcons/CLAUDE_OPENAI_SOURCES.md) and [Grok/Gemini sources](Resources/ProviderIcons/GROK_GEMINI_SOURCES.md).

## Reasoning effort (0.2.1)

Use **推理** in a private conversation's header, the member panel in a Plaza, or the new-room member form. Settings also has **默认推理强度** for new conversations. Existing conversations keep their own choices; changing an effort takes effect on the next message and is disabled during an active response/meeting. Older saved records without an effort value load normally.

- Claude forwards the selected `low`, `medium`, `high`, `xhigh` or `max` value to official Claude Code's `--effort`. The installed CLI advertises these values; the chosen model/account determines actual acceptance.
- Codex loads each model's supported/default effort from `model/list` and sends the selected value through `turn/start.effort`. Choosing **官方默认** resolves and sends the model's advertised default, including on resume, so a previous high/low override does not remain accidentally sticky. No model turn is needed to discover these options.
- Grok and Gemini use the exact effort-specific model IDs returned by Cursor's model discovery. The selector changes only the effort variant of the same family and preserves Fast mode. It does not fabricate model IDs or pass an unsupported `--effort` flag. Click **读取档位** / **刷新可用档位** when discovery has not run.

On this Mac, read-only checks on 2026-10-29 returned Claude Code 2.1.308's five values; GPT-6.1 Sol's `low / medium / high / xhigh / max / ultra` (default `low`); Grok 4.7's `low / medium / high / xhigh`; and Gemini 4 Argon's `low / medium / high`. These are observed catalog capabilities, not live inference tests. Higher efforts may take longer; the existing meeting call/time/output limits still apply. Codex's built-in member delegation remains disabled so effort selection cannot dispatch additional agents outside the room coordinator.

## Plaza: roles, mentions and bounded meetings

Choose **新建讨论** in the sidebar to create a room with 2–4 named members. Each member has a role, provider, model, dedicated local/official session ID and its own workspace. Configure a member to summarize the final round. Shared context is supplied explicitly; private chat transcripts are never imported automatically.

- **点名群聊** sends one turn to each selected member. Exact `@成员名` tokens override the selection; `@everyone` selects everyone. Unknown mentions do not broadcast. Only the human composer is routed; model-generated mentions never dispatch work.
- **召开会议** runs 1–3 rounds sequentially. A round means one turn per member. Round one has independent answers; later rounds receive the previous completed round. With two or more rounds, the designated final summarizer speaks last and uses its existing turn to report agreement, disagreement and next steps.
- The visible budget is members × rounds, at most 12 calls. Every started call consumes a slot, including a failed call. There are no retries or hidden host/summary calls. If everyone replies `[PASS]`, the run ends early.
- A failed/incomplete response, a 2-minute turn timeout, a 15-minute overall timeout or an 8,000-character reply limit stops the run. Output/context are bounded. Prior public messages are attributed and supplied as reference material, with explicit omission markers where bounded context is shortened.
- **停止全部** cancels the active stream and prevents further dispatch. Owned CLI processes have isolated process groups, so cancellation and app shutdown also clean up their child processes. The app never signals unrelated official CLI sessions.
- New meetings require an explicit human action. No background schedule or recurring automation is created.

Discussion runs accept text and supported image inputs. Members do not modify project files or launch experiments during meetings. Their roles and shared evidence support planning and review; they are not an autonomous training-job system.

## MCP tools

Open **MCP 工具** from the sidebar. Add a local stdio executable (absolute path, one argument per line) or a Streamable HTTP endpoint, then test the connection and discover tools. For stdio, install and authenticate the chosen server through its own supported setup first. AgentDesk does not install server packages automatically. Explicit environment-variable names may be passed from the app process; values are not stored in the configuration.

Select a tool, inspect its input schema, enter JSON arguments and click **运行工具**. The call happens only on that click. Results show the server, tool and time; **附加到…** copies the result into the selected private/group composer for review and manual sending. This supports all four chat providers without exposing the MCP server directly to an unattended model loop.

The workbench supports stdio JSON-RPC and Streamable HTTP JSON/SSE responses, including bounded tool-list pagination, timeouts and cancellation. Tool annotations are descriptive hints, not automatic permission. Server configuration is stored in `mcp-servers.json`; connection checks and discovery do not call a model or invoke tools. No server connects on application launch.

Remote MCP OAuth, credential entry, MCP sampling/elicitation and native model-directed tool calls are not provided by this release. Logging in through another app does not automatically authenticate a URL here. Use an already configured local stdio bridge or an endpoint that needs no OAuth; keep secrets out of commands, arguments and URLs. Concrete services, including IBKR, have not been configured or contacted.

## Storage and recovery

App data is in `~/Library/Application Support/AgentDesk/`: `sessions.json`, `settings.json`, `plazas.json`, `mcp-servers.json`, and a distinct `Workspaces/<UUID>/` per chat. These files contain conversations and paths, not authentication tokens. Writes are atomic. A conversation or meeting interrupted at app shutdown is restored as stopped, preserving partial text, consumed calls and session IDs; the app never automatically resends its last prompt. Official Claude/Codex/Cursor history remains in those tools' own storage. Deleting a local conversation does not delete provider history or workspace files. Provider retention settings may limit how long a remote session remains resumable.

For an isolated manual UI test, launch the executable with `--data-dir /absolute/test/directory`.

## Integration references

- [Claude CLI](https://code.claude.com/docs/en/headless)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server)
- [Cursor headless CLI](https://cursor.com/docs/cli/headless)
- [Cursor authentication](https://cursor.com/docs/cli/reference/authentication)
- [Cursor legacy plans](https://cursor.com/docs/account/pricing/legacy-cursor-plans)

Each adapter consumes the provider's public protocol. The subprocess transport keeps stdout/stderr separate, drains final output before observing exit, and terminates stopped requests. Offline tests cover persistence and protocol behavior without using model quota.

## Earlier live verification (0.1.0, 2026-10-29)

The release app was built and opened on this Mac. All 18 offline tests passed. With the user's explicit approval, the actual SwiftUI interface sent two short messages each through Claude, Codex, Cursor/Grok and Cursor/Gemini (8 messages total). All four returned real responses and recalled their own earlier message when the official session was resumed. The four official IDs and working directories were distinct. Local history also survived quitting and reopening the app. `VALIDATION.json` records the results without authentication data.

These live checks used `sonnet`, `gpt-6.1-sol`, `grok-4.7-medium` and `gemini-4-argon-medium`. Grok/Gemini IDs were taken from the signed-in Cursor account's model list. This does not guarantee future model availability or account billing; use model discovery when the provider changes its catalog.

## Validation of 0.2.0

The current work uses offline provider fixtures and local MCP fixtures, not subscription model calls. Tests cover budget limits, failures, cancellation, incomplete streams, output limits, context isolation, interrupted-session persistence, process-group cleanup, MCP JSON/SSE parsing and explicit tool invocation. See `VALIDATION.json` for the recorded build and UI checks. The earlier eight live messages verify the original adapters only; they are not a live validation of the new group scheduler or every external MCP service.

Protocol references: [MCP lifecycle](https://modelcontextprotocol.io/specification/2025-03-26/basic/lifecycle), [MCP transports](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports), [MCP tools](https://modelcontextprotocol.io/specification/2025-03-26/server/tools).
