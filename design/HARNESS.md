# AgentDesk Harness 改造方案 · v1

> 整理日期：2026-10-30　｜　状态：方案，尚未实施
> 依据的版本：Claude Code 2.1.308，codex-cli 0.165.0-alpha.1.2（ChatGPT.app 内置），AgentDesk main `b21c4ae`。
> 本文只讨论“画布节点背后怎么跑 agent”。画布交互见 `CANVAS.md`。

## 1. 目标与原则

目标：让多个 agent 在同一个项目里，作为画布上的不同对话**安全地、并行地、可追溯地**写代码；规则和记忆对用户看得见、改得了。

原则：

1. **执行交给官方 harness。** agent 循环、工具、上下文压缩仍由 Claude Code、Codex、Cursor 自己负责。AgentDesk 只管四件事：
   - 编排：画布、连线、合流、重跑；
   - 隔离：工作目录、worktree；
   - 审批：哪些操作需要用户点头；
   - 规则与记忆：写在哪里，怎么交给各家。
2. **不碰凭据。** 登录、额度仍由官方 CLI 管（见 `AGENTS.md`）。
3. **默认安全，放权要明说。** 能写文件、能运行命令的模式必须由用户主动打开，而且要能分档。
4. **看得见。** 模型做过的每一个动作，都能在面板里看到、能撤销。
5. **各家一致。** 同一个项目里，三家 CLI 读到的是同一份规则、同一份记忆。

## 2. 现状

### 2.1 节点背后是谁

| 界面名称 | 实际 harness | 账号 |
|---|---|---|
| Claude | Claude Code（`claude -p`，stream-json） | Claude 订阅 |
| ChatGPT | Codex CLI（`codex app-server`，JSON-RPC） | ChatGPT 账号 |
| Grok / Gemini | Cursor agent CLI（`--print`，stream-json） | Cursor 订阅 |

“ChatGPT”节点用的是 Codex 的 agent 循环、shell 和 `apply_patch`，与 ChatGPT App 里的云端 agent 无关。

### 2.2 两种模式

| | 普通画布（聊天） | 信任的项目 |
|---|---|---|
| Claude | `--safe-mode --restricted --tools ""`，单轮；开放 MCP 时最多 12 轮 | 全部内置工具，`--permission-mode bypassPermissions`，最多 100 轮，加载用户和项目设置 |
| Codex | shell 关闭，`sandbox_mode="read-only"`，`baseInstructions` 换成“不用工具” | shell 打开，`workspace-write` 并且可以联网，`approval_policy="never"`，审批请求自动同意 |
| Cursor | `--mode ask --sandbox enabled`，用 `cli.json` 拒绝读、写、shell | `--force --sandbox disabled` |
| 工作目录 | AgentDesk 数据目录里的会话目录 | 项目文件夹，**所有节点共用** |

信任的项目由 `CanvasProject.trusted` 决定，`AppModel.send` 里根据它设置 `projectAccess`。

### 2.3 一个 agent 的组成和缺口

| 组成 | 现在由谁负责 | 缺口 |
|---|---|---|
| 模型 | 三家官方 | — |
| 规则 / 指令 | 项目模式下各读各的：`CLAUDE.md`、`AGENTS.md` 加 `~/.codex/rules`、`.cursor/` | 没有统一的项目规则，也没有 AgentDesk 级的全局规则 |
| 短期记忆（对话历史） | 官方会话，可恢复、可分叉 | — |
| 长期记忆 | Codex 的记忆被关闭（`features.memories=false`）；Claude 的自动记忆在项目模式下是否生效，取决于用户设置（未验证） | 没有一份看得见、改得了的项目记忆 |
| 节点之间共享信息 | 画布的继承线、数据线、合流 | — |
| 工具 | 只在项目模式下开放 | — |
| 权限 / 审批 | 项目模式全部放行 | **缺审批** |
| 并行隔离 | 共用一个目录 | **缺 worktree** |
| 过程可见 | 工具调用只变成一行 `.status` 文字 | **缺命令、输出、diff、撤销** |
| 上下文压缩 | 各家 CLI 自己处理 | 可以加手动压缩按钮（Codex `thread/compact/start`） |
| 子 agent | Codex `multi_agent` 已关闭；Claude 的子 agent 在项目模式下可用 | 先靠画布，暂不需要 |

## 3. 分阶段方案

按依赖排序：H0 → H1 → H2 → H3 是“多 agent 在一个项目里写代码”的必要条件；H4、H5 是规则和记忆；H6 以后再做。

### H0 · 名称与透明（小）

- provider 显示名改成实际的 harness：“Claude Code”、“Codex”、“Cursor · Grok”、“Cursor · Gemini”。账号写在副标题里，例如“Codex · ChatGPT 账号”。
- 节点卡片和面板头部显示当前模式：`聊天` / `项目 · 询问` / `项目 · 自动`（见 H1）。
- 上下文预览里加一节“本轮的 harness 设置”，列出模式、沙箱、工作目录和已加载的规则文件，只读。

验收：界面上不再出现“ChatGPT 写代码”这种说法。前端测试覆盖显示名映射。

> **状态：已实现**（分支 `claude/harness-approvals-8d42e0`，2026-10-30）。
> - `ProviderID.name` 改成 harness 名称，另加 `account`、`subtitle`。原生界面（设置、错误提示、信任对话框）和画布（新节点菜单、面板副标题、合流选择）都用新名称。
> - 模式只在 `HarnessMode.resolve`（`Harness.swift`）里计算一次，发送、节点卡片、面板和上下文预览共用。H2 换工作目录时只需要改这一处。
> - “本轮的 harness 设置”由 `HarnessSummary` 生成，列出 harness 和账号、模式、权限、工作目录，以及在文件夹里实际找到的规则文件。
> - 测试：`HarnessApprovalTests`，以及前端的 `harness.test.ts`。

### H1 · 权限审批（必要）

**三档模式**，按项目设置，节点可以单独调低：

| 档位 | 读文件 | 写文件 | 运行命令 | 联网 |
|---|---|---|---|---|
| 只读 | 允许 | 询问 | 询问 | 询问 |
| 询问（新项目的默认） | 允许 | worktree 内允许，外面询问 | 询问；本会话内可以“以后都允许” | 询问 |
| 自动（现状） | 允许 | 允许 | 允许 | 允许 |

**Codex**：`answerServerRequest` 不再自动同意，而是转给 App。
- 能拿到的信息：
  - `item/commandExecution/requestApproval` 带 `command`、`cwd`、`reason`、`commandActions`、`networkApprovalContext`、`proposedExecpolicyAmendment`；
  - `item/fileChange/requestApproval` 带 `grantRoot` 和 `reason`，具体改动内容来自同一 item 和 `turn/diff/updated`。
- 可回的答复：`accept`、`acceptForSession`、`decline`，以及带 execpolicy 修订的同意（对应“以后这类命令都允许”，写进项目规则，见 H4）。
- 线程设置：`approvalPolicy` 按档位改成按需询问（具体取值实施时以 schema 为准），`sandbox` 保持 `workspace-write`，worktree 之外的写入由沙箱拦下，再走审批。

**Claude Code**：`bypassPermissions` 换成 `--permission-mode default`，加 `--permission-prompts host` 和 `--permission-prompt-tool mcp__agentdesk__approve`。
- 审批工具放进现有的 `agentdesk-files` 辅助程序（它已经是每个会话一个 stdio MCP 服务器），复用 `FolderAccessExchange` 那套“请求文件 → App 回答 → 返回给模型”的通道。
- 档位里写明“允许”的部分，用 `--allowedTools` 预先放行：只读工具，以及限定在 worktree 内的 `Edit` / `Write`。
- 超时就当作拒绝。超时时长沿用 `FolderAccessPolicy.toolTimeoutSeconds`，`MCP_TOOL_TIMEOUT` 已经比它长。

**Cursor**：`--print` 模式没有审批回调（待验证）。
- 在“询问”档：用 `cli.json` 的 allow/deny 实现静态规则，只允许 worktree 内读写，拒绝 shell。
- 需要运行命令时，告诉用户“Cursor 在此档位不能运行命令”，建议改用 Codex 或 Claude 节点。
- 只有“自动”档才完全放开。

**界面**：
- 审批卡片出现在该节点的面板顶部，同时节点卡片上显示“等你确认”标记，侧栏计数。
- 卡片内容：命令和工作目录、文件 diff、模型给出的理由。按钮：允许一次 / 本会话内都允许 / 拒绝（可附理由）。
- 多个审批按顺序排队。等待期间整个回合暂停，节点状态是“等待确认”，不是“运行中”。
- 原生 `confirm.show` 只用于删除这类 App 级确认，审批走单独的 `approval.show` / `approval.answer` 桥接消息。

验收：
- 离线测试：每家 CLI 的参数组合、Codex 审批请求到答复的映射、Claude 审批工具的往返（用假的请求文件）。
- 实际调用（需要额度许可）：每家各 1 回合，触发一次命令审批，分别验证拒绝和允许。

> **状态：已实现，离线测试通过，尚未做实际调用**（分支 `claude/harness-approvals-8d42e0`，2026-10-30）。
>
> 离线查到的事实：
> - Codex 0.165（`codex app-server generate-json-schema`）：
>   - `AskForApproval` 的取值是 `untrusted | on-request | never`，或者 `granular`。
>   - 命令审批的答复是 `accept | acceptForSession | acceptWithExecpolicyAmendment | applyNetworkPolicyAmendment | decline | cancel`；文件审批是 `accept | acceptForSession | decline | cancel`。
>   - `approvalsReviewer` 可以是 `user | auto_review | guardian_subagent`。
>   - `item/fileChange/requestApproval` 只带 `itemId`、`reason`、`grantRoot`，diff 来自同一 item 的 `changes[].diff`。
> - Claude Code 2.1.308：`--permission-mode` 列出的是 `acceptEdits | auto | bypassPermissions | manual | dontAsk | plan`，`default` 仍然接受（`manual` 的旧名）。`--permission-prompts host|none` 已公开，`--permission-prompt-tool` 是隐藏参数但可用。
> - Cursor agent 2026.10.22：`--print` 没有审批回调，没有 prompt tool，也没有 stdin 审批；`--auto-review` 依赖服务器分类器，不能把问题交给 AgentDesk。
>
> 实现：
> - 档位：`CanvasProject.permissionLevel`，节点用 `CanvasNode.permissionLevel`。新信任的项目是“询问”；旧项目没有这个字段，读出来是“自动”。
> - Codex：
>   - 询问 = `workspace-write`、不联网、`approvalPolicy: "untrusted"`；
>   - 只读 = `read-only` 沙箱，加 `untrusted`；
>   - 自动 = 现状。
>   - 低于自动时同时发 `approvalsReviewer: "user"`。
>   - 注意：`untrusted` 下打补丁也会询问，所以在 Codex 上，“询问”档改 worktree 内的文件也会问。这比表格严格，因为 Codex 没有按类别区分的取值。
> - Claude：
>   - `--permission-mode default`，加上 `--allowedTools` 预先放行 `Read(./**)`、Glob、Grep、LS、TodoWrite，“询问”档再加 `Edit(./**)`，以及打开的 MCP 服务器；
>   - 其余操作走 `mcp__agentdesk_files__approve`。辅助程序带 `--approvals <目录>` 启动；文件夹访问关闭时再加 `--no-files`。
>   - 请求和答复放在数据目录的 `approval-requests/`，“本会话内都允许”记在 `approval-grants/`（同一条命令、同一个文件、同一个网站，其余按工具名）。
> - Cursor：
>   - 询问 = agent 模式、开沙箱，`cli.json` 允许 `Read(**)`、`Write(**)`，拒绝 `Shell(*)`；
>   - 只读 = `--mode ask`；
>   - 项目里已有自己的 `cli.json` 时不改它，这一轮按只读运行，并给出提示。
> - 界面：
>   - 桥接消息 `approval.show`、`approval.hide`、`approval.answer`；
>   - 卡片在节点面板顶部，节点上显示“等你确认”标记，状态是“等待确认”，侧栏按画布计数；
>   - 120 秒没有回答或停止回合，都算拒绝。
>   - 档位在侧栏切换，改成“自动”前会确认；节点在面板的模式菜单里调低。
>
> 还需要的实际调用（约 6 回合，需要额度许可）：
> 1. Claude，“询问”档：触发一次 `Bash` 审批并拒绝，确认模型继续回答、没有执行命令。
> 2. Claude，“询问”档：同一命令点“本会话内都允许”，确认第二次不再询问。另外确认 `--permission-prompt-tool` 在 `-p` 下确实被调用，超时设置也生效。
> 3. Codex，“询问”档：触发命令审批并拒绝，确认 `decline` 后回合继续。
> 4. Codex，“询问”档：触发文件改动审批并允许，确认补丁被应用、卡片里有 diff。
> 5. Cursor，“询问”档：让它运行命令，确认被 `Shell(*)` 拒绝、提示出现；再改一个项目文件，确认能写。
> 6. 任意一家，“自动”档的旧项目：确认行为和以前一样，不出现审批卡片。

### H2 · 每段对话一个 worktree（必要）

项目是 git 仓库时：
- **新建节点**：由 AgentDesk 自己执行 `git worktree add`。不用 Claude 的 `-w`，这样三家行为一致。
  - 位置：`~/AgentDesk Worktrees/<项目名>/<节点短 ID>`，放在项目外面，避免被各家 CLI 当作项目文件扫描。
  - 分支：`agentdesk/<画布短名>/<节点短 ID>`，从项目当前的 `HEAD` 切出。
  - 会话的 `workingDirectory` 指向 worktree。
- **分支节点（继承线）**：从父节点 worktree 的当前状态切出。父节点有未提交的改动时，先在父 worktree 上做一个快照提交（隐藏引用 `refs/agentdesk/snapshots/...`，不动父分支），子节点从快照切出。原生分叉照常进行，只有工作目录不同。
- **合流节点**：默认没有 worktree，只读上游的结论和 diff 摘要。用户要求“把这几个分支的改动合起来”时，再新建 worktree，依次 `git merge` 各个上游分支，冲突交给这个节点的 agent 解决。
- **数据线**：除了上游的回复，还可以选择传入“上游分支相对基点的 diff 摘要”（`git diff --stat` 加截断后的 patch）。
- **合并回主线**：节点菜单里加“合并到 <基础分支>”。
  - 先检查工作区是否干净，再执行 `git merge --no-ff`，提交信息由 AgentDesk 生成。
  - 有冲突时不自动处理：报告冲突文件，建议新建一个合流节点来解决。
  - 不推送。
- **删除节点**：确认后执行 `git worktree remove`；分支保留，除非用户勾选“同时删除分支”。
- **磁盘**：设置里显示 worktree 占用，提供“清理已合并节点的 worktree”。

项目不是 git 仓库时：提示“初始化 git 以并行工作”，可以一键 `git init`；不初始化的话，项目里同一时间只允许一个节点处于写入档位，其余节点自动降为只读。

验收：
- 离线测试：用临时仓库测创建、分支快照、合并、冲突报告、删除。
- 实际调用：同一项目两个节点各改一个文件，然后合并回主线。

### H3 · 过程可见与撤销（必要）

**事件**：`AgentEvent` 增加结构化的步骤事件，取代只有一行文字的 `.status`：

```
.step(StepEvent)
  StepEvent { id, kind: command | fileChange | mcp | read | search | web | other,
              title, detail?, state: running | done | failed | declined,
              output?: append-delta, exitCode?, diff? }
.turnDiff(String)   // 这一回合对工作区的累计 diff
```

各家的来源：

| | 步骤开始 / 结束 | 输出流 | diff |
|---|---|---|---|
| Codex | `item/started` / `item/completed`（`commandExecution`、`fileChange`、`mcpToolCall`） | `item/commandExecution/outputDelta`、`item/fileChange/outputDelta` | `turn/diff/updated` |
| Claude | `assistant` 里的 `tool_use` 和随后 `user` 里的 `tool_result` | 无（`tool_result` 一次性给出） | AgentDesk 在回合结束时对 worktree 执行 `git diff` |
| Cursor | stream-json 的工具调用事件 | 视 CLI 而定 | 同 Claude |

**存储**：`ChatMessage` 加 `steps: [Step]` 和 `diffStat`。输出截断保存（每步最多保留首尾各 4 KB），完整 diff 存成单独文件，不进主 JSON。

**界面**：
- 回复上方显示可折叠的步骤列表。命令显示退出码，文件改动可以展开看 diff。
- 节点卡片显示“改了 N 个文件 +a −b”。
- 面板里加“本回合改动”视图，按文件列出 diff。

**撤销**：
- 每个写入回合开始前，在 worktree 上记一个检查点（`git stash create` 生成的提交写进 `refs/agentdesk/checkpoints/<turn>`；工作区干净时就记 `HEAD`）。
- “撤销这一回合”把 worktree 恢复到检查点。
- 官方会话的历史同步回退：Codex 用 `thread/revert { beforeTurnId }`；Claude Code 没有对应接口，从检查点所在的那一轮重新原生分叉成新节点，并说明原因。

验收：
- 离线测试：三家事件解析器的样例（录制好的 JSONL），以及检查点和撤销。
- 实际调用：每家 1 回合，改一个文件，看到 diff 后撤销。

### H4 · 统一规则

**三层规则**，越往下优先级越高：

1. **AgentDesk 全局规则**：存在 App 数据目录里，在设置中编辑，适用于所有画布，包括聊天模式。注入方式：
   - Claude：`--append-system-prompt`；
   - Codex：`thread/start` 的 `developerInstructions`，不再覆盖 `baseInstructions`，聊天模式里“不用工具”的说明也移到这里；
   - Cursor：放在本轮消息前面，作为单独的一段。
2. **项目规则**：项目根目录的 `AGENTS.md`，在 AgentDesk 的项目设置里编辑（直接改这个文件）。
   - Codex 原生读取，Cursor 读取（待验证）。
   - Claude：如果项目没有 `CLAUDE.md`，经用户同意后创建一个只含 `@AGENTS.md` 的文件；已有 `CLAUDE.md` 但没有引用的，提示用户加上，不自动改。
3. **节点规则**：节点自己的说明，例如“只改 `src/api/`”。和全局规则走同一条注入通道，追加在全局规则之后。

另外：
- 审批里选“以后这类命令都允许”时，Codex 的 execpolicy 修订写进项目的 `.codex/rules`（若该 CLI 版本支持项目级规则）或 AgentDesk 的项目设置，界面上能看到、能删。
- 上下文预览里列出本轮生效的规则来源和字数。

验收：
- 离线测试：注入参数的组合、`CLAUDE.md` 的创建与检测（不覆盖已有内容）。
- 实际调用：每家 1 回合，问“你现在要遵守哪些项目规则”。

### H5 · 项目记忆

原则：记忆**看得见、改得了、按项目隔离、由用户批准**。各家 CLI 藏在自己目录里的记忆继续关闭：Codex 保持 `features.memories=false`，Claude 在项目模式下通过 `--settings` 关掉自动记忆，避免三家各记一套、互相矛盾。

- **存储**：项目根目录的 `.agentdesk/memory.md`，按条目组织，每条带来源节点、日期、作者（用户或模型）。项目被版本控制时，由用户决定是否提交它。
- **写入**：
  - 用户在任意回复上点“记住这个”，或者直接编辑记忆文件；
  - 模型在回合末尾提出“建议记住”的条目（通过 AgentDesk MCP 的 `memory.propose` 工具），以草稿形式显示在面板里，用户确认后才写入。这和画布的“模型建议的草稿节点”是同一种交互。
- **读取**：在 `AGENTS.md` 末尾加一行引用 `@.agentdesk/memory.md`（Claude 会展开引用；Codex 和 Cursor 是否展开待验证，不展开的话就把记忆文件作为项目规则的附录注入）。记忆超过预算（例如 4,000 字）时提示用户整理，不自动删除。
- **跨项目**：只有全局规则（H4 第一层），没有跨项目记忆。

验收：
- 离线测试：解析和写入记忆条目、确认草稿、引用的生成。
- 实际调用：一个节点让模型提出一条记忆，确认后，在另一个节点里能用上。

### H6 · 以后再做

- **Codex 的高级功能**：
  - `review/start` 代码审查，做成节点菜单里的“审查这个分支”，结果是一个新节点；
  - `thread/compact/start` 手动压缩上下文；
  - `skills/list` 列出可用技能。
- **再打开的功能**：子 agent（Codex `multi_agent`），浏览器、电脑操作。前提是 H1 的审批已经能覆盖它们。
- **Gemini**：改用 Google 官方的 Gemini CLI，不再经过 Cursor。
- **OpenCode 后端**：`opencode serve`，用来接没有官方 CLI 的模型（单独调研中）。
- **后台运行和通知**：节点在后台跑完或等待确认时，发系统通知。

## 4. 风险与待验证

| 项目 | 说明 | 怎么验证 |
|---|---|---|
| Codex 按需审批的取值 | `approvalPolicy` 的具体取值和沙箱的配合，各版本可能不同 | 已读 0.165 的 schema（见 H1 状态）；沙箱和 `untrusted` 的实际配合仍要 1 回合实际调用 |
| Claude `--permission-prompt-tool` 与 `--permission-prompts host` 的组合 | print 模式下的行为、超时、拒绝后模型是否继续 | 1 回合实际调用 |
| Cursor 审批 | `--print` 是否有审批回调；它是否读 `AGENTS.md` | 已查 `--help`（2026.10.22）：没有审批回调，H1 用静态规则；是否读 `AGENTS.md` 仍待 1 回合实际调用 |
| worktree 与原生分叉 | 分叉的子会话换了工作目录后，官方 CLI 是否接受 | 两家各 1 回合 |
| 磁盘和性能 | 大仓库每个节点一个 worktree | 先只在“询问 / 自动”档的写入节点创建，只读节点直接用项目目录 |
| 记忆引用展开 | Codex 和 Cursor 是否展开 `@file` | 各 1 回合 |

## 5. 实施顺序与额度

| 阶段 | 依赖 | 大小 | 实际调用（需许可） |
|---|---|---|---|
| H0 名称与透明 | — | 小 | 0 |
| H1 审批 | H0 | 中 | 约 6 回合 |
| H2 worktree | — | 中 | 约 4 回合 |
| H3 过程可见与撤销 | H2（检查点依赖 worktree） | 大 | 约 3 回合 |
| H4 统一规则 | — | 中 | 约 3 回合 |
| H5 项目记忆 | H4 | 中 | 约 2 回合 |

H1 和 H2 互不依赖，可以并行开发，例如放到两个分支或两个子会话；H3 在 H2 之后。每个阶段单独成一个分支，合进 `main` 前跑全部离线测试，并按 `AGENTS.md` 重新打包验证。
