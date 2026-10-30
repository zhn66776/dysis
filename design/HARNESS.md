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

> **状态（2026-10-30，分支 `claude/harness-rules-memory-dd7429`）：已实现，离线测试通过；实际调用待验证（见下面“待实测”）。**

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

**实施记录**（以 Claude Code 2.1.308、codex-cli 0.165.0-alpha.1.2、Cursor agent 2026.10.22 的 `--help`、schema 和安装包为准）：

| | 全局规则 + 节点规则 | 项目规则 `AGENTS.md` |
|---|---|---|
| Claude Code | `--append-system-prompt`，并加 `--system-prompt-snapshot off`（默认会把第一轮的系统提示词记下来，改过的规则要等压缩后才生效） | 项目模式：`--settings '{"instructionFiles":"claude-md-and-agents-md"}'`，`AGENTS.md` 和 `CLAUDE.md` 一起加载；`CLAUDE.md` 已经引用它时不重复加载。聊天模式（`--safe-mode`）：AgentDesk 注入 |
| Codex | `thread/start`、`thread/resume`、`thread/fork` 的 `developerInstructions`；不再传 `baseInstructions`。聊天模式的“不用工具”说明放在规则前面 | Codex 自己读（project doc） |
| Cursor | 消息前面的 `<agentdesk-rules>…</agentdesk-rules>` 一段，每轮都带 | Cursor 自己读（安装包里按 `AGENTS.md` 加载规则） |

- 全局规则存在数据目录的 `rules.md`，在设置里编辑；节点规则存在会话的 `rules` 字段，在面板底部“节点规则”里编辑。注入文字的顺序：全局 → （需要注入时）项目 → 节点。
- 项目设置（侧栏项目行的“规则与设置…”）：编辑 `AGENTS.md`；没有 `CLAUDE.md` 时提供“新建只含 `@AGENTS.md` 的 CLAUDE.md”；已有 `CLAUDE.md` 但没引用时只给出那一行让用户自己加，从不修改；列出始终允许的命令，可以删除。
- 聊天模式的“不用工具”从 `baseInstructions` 移到 `developerInstructions` 后，离线能确认的部分没有变：shell 关闭、沙箱只读、`approval_policy="never"`、所有审批请求都拒绝（测试覆盖）。模型是否仍然不去尝试工具，需要实测。
- 规则读取都以项目文件夹（`CanvasProject.path`）为准；H2 改用 worktree 后，Claude 和 Codex、Cursor 自己读的是 worktree 里的 `AGENTS.md`（已提交的版本）。

**命令许可（与 H1 约定的存储格式）**：
- 位置：数据目录 `project-policies/<项目路径 SHA-256 前 12 字节的 hex>.json`，不放在项目里，避免 agent 改自己的权限。读写用 `CommandPolicyStore`（`AgentDeskCore/HarnessRules.swift`）。
- 格式：`{"version":1,"projectPath":"/abs/path","commands":[{"id":"UUID","provider":"codex","prefix":["git","status"],"createdAt":"ISO8601","sourceSessionID":"UUID?","sourceTitle":"节点标题?"}]}`。命令的 argv 以 `prefix` 开头即匹配（`ProjectCommandPolicy.allows(argv)`），对项目里所有 provider 生效。
- H1 的接法：用户选“以后这类命令都允许”时，用 Codex 的 `proposedExecpolicyAmendment`（或 Claude 命令的前几个词）调用 `CommandPolicyStore.add`，然后只回 `accept`。**不要**回 `acceptWithExecpolicyAmendment`：Codex 会把它写进用户级的 `~/.codex/rules`，对所有项目生效，AgentDesk 也看不到。之后同一项目的审批请求先查 `allows(argv)`，匹配就自动同意；Claude 可以把规则转成 `--allowedTools`（`CommandPolicyRule.claudeAllowedTool`，形如 `Bash(git status:*)`）。
- 显示与删除：项目设置里已经接好（H4）。

**待实测**（各 1 回合）：三家各问一次“你现在要遵守哪些规则”，确认全局、项目、节点三层都在；Codex 聊天模式下问一个需要命令才能回答的问题，确认它仍然只用文字回答；改一条全局规则后在同一会话继续，确认 Claude（snapshot off）和 Codex（resume 时的 `developerInstructions`）用上新规则。

验收：
- 离线测试：注入参数的组合、`CLAUDE.md` 的创建与检测（不覆盖已有内容）。
- 实际调用：每家 1 回合，问“你现在要遵守哪些项目规则”。

### H5 · 项目记忆

> **状态（2026-10-30，分支 `claude/harness-rules-memory-dd7429`）：已实现，离线测试通过；实际调用待验证（见下面“待实测”）。**

原则：记忆**看得见、改得了、按项目隔离、由用户批准**。各家 CLI 藏在自己目录里的记忆继续关闭：Codex 保持 `features.memories=false`，Claude 在项目模式下通过 `--settings` 关掉自动记忆，避免三家各记一套、互相矛盾。

- **存储**：项目根目录的 `.agentdesk/memory.md`，按条目组织，每条带来源节点、日期、作者（用户或模型）。项目被版本控制时，由用户决定是否提交它。
- **写入**：
  - 用户在任意回复上点“记住这个”，或者直接编辑记忆文件；
  - 模型在回合末尾提出“建议记住”的条目（通过 AgentDesk MCP 的 `memory.propose` 工具），以草稿形式显示在面板里，用户确认后才写入。这和画布的“模型建议的草稿节点”是同一种交互。
- **读取**：在 `AGENTS.md` 末尾加一行引用 `@.agentdesk/memory.md`（Claude 会展开引用；Codex 和 Cursor 是否展开待验证，不展开的话就把记忆文件作为项目规则的附录注入）。记忆超过预算（例如 4,000 字）时提示用户整理，不自动删除。
- **跨项目**：只有全局规则（H4 第一层），没有跨项目记忆。

**实施记录**：
- 条目格式：`### 日期 · 作者 · 来自「节点标题」(会话 ID 前 8 位)`，下一行是 `<!-- agentdesk-memory: ID -->`，然后是正文。作者是“用户”或“模型（Claude Code，sonnet）”。文件里用户自己写的其他内容原样保留；手写的 `### ` 条目也能列出和删除（没有标记时 ID 由标题算出）。`ProjectMemory`（`AgentDeskCore/ProjectMemory.swift`）。
- “记住这个”：每条已完成的回复下面都有，只在项目画布上出现。点了之后在面板里生成一条可编辑的草稿，“保存到项目记忆”才写入。
- `memory_propose`（MCP 工具名不能带点，所以不叫 `memory.propose`）：在 `agentdesk-files` 里，项目画布上的节点启动它时带 `--project <文件夹>`；文件夹读取关闭时加 `--no-files`，只剩这个工具。它只把草稿写进数据目录的 `memory-proposals/`（带本次启动的 token），立刻返回，不等用户。App 每秒取一次，显示为面板里的草稿（标明哪个模型建议、理由），确认后才写入。草稿只保留到 App 退出。
- 第一次写入时，在 `AGENTS.md` 末尾加上 `@.agentdesk/memory.md`（没有 `AGENTS.md` 就新建）；用户删掉这一行后，项目设置里可以再加。
- 读取：Claude Code 在信任的项目里展开 `@` 引用（`AGENTS.md` 由 `instructionFiles` 加载）；Codex 和 Cursor 不展开（Codex 把 `AGENTS.md` 当作普通 project doc，Cursor 的安装包里也没有展开 `@` 的逻辑），记忆作为项目规则的附录注入；Claude 在聊天模式或 `AGENTS.md` 没有引用时也由 AgentDesk 注入。上下文预览标明是哪一种。
- 预算：整份文件超过 4,000 字时，面板和项目设置里提示整理，上下文预览里也标出；从不自动删除。项目设置里可以逐条删除。
- 各家自己的记忆：Codex 保持 `features.memories=false`；Claude Code 两种模式都加 `--settings '{"autoMemoryEnabled":false,…}'`（设置名取自 2.1.308 安装包里的 schema：“When false, Claude will not read from or write to the auto-memory directory”；也有环境变量 `CLAUDE_CODE_DISABLE_AUTO_MEMORY`，没有用）。

**界面检查**：网页部分（节点规则、“记住这个”、记忆草稿、上下文预览的规则列表）在浏览器预览（mock）里点过；`agentdesk-files --no-files --project` 用真实构建离线跑过一次 `initialize` / `tools/list` / `memory_propose`。原生部分（设置里的全局规则、项目设置面板）只编译通过，没有在运行中的 App 里看过。

**待实测**（约 2 回合）：在项目画布的一个节点里让模型调用 `memory_propose`，确认草稿出现在面板里；保存后在另一个节点（换一家 CLI）问这条信息，确认读到了。另外确认 Claude 在 `--safe-mode` 下 `--settings` 和 `--append-system-prompt` 仍然生效，以及 `instructionFiles` 加载的 `AGENTS.md` 会展开 `@.agentdesk/memory.md`。

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
| Codex 按需审批的取值 | `approvalPolicy` 的具体取值和沙箱的配合，各版本可能不同 | 读当前 schema，离线启动 app-server 的 `thread/start`（不发消息） |
| Claude `--permission-prompt-tool` 与 `--permission-prompts host` 的组合 | print 模式下的行为、超时、拒绝后模型是否继续 | 1 回合实际调用 |
| Cursor 审批 | `--print` 是否有审批回调；它是否读 `AGENTS.md` | 查文档和 `--help`，再用 1 回合实际调用 |
| worktree 与原生分叉 | 分叉的子会话换了工作目录后，官方 CLI 是否接受 | 两家各 1 回合 |
| 磁盘和性能 | 大仓库每个节点一个 worktree | 先只在“询问 / 自动”档的写入节点创建，只读节点直接用项目目录 |
| 记忆引用展开 | Codex 和 Cursor 是否展开 `@file`（安装包里没有展开逻辑，H5 按不展开处理，改为注入附录） | 各 1 回合 |

## 5. 实施顺序与额度

| 阶段 | 依赖 | 大小 | 实际调用（需许可） |
|---|---|---|---|
| H0 名称与透明 | — | 小 | 0 |
| H1 审批 | H0 | 中 | 约 6 回合 |
| H2 worktree | — | 中 | 约 4 回合 |
| H3 过程可见与撤销 | H2（检查点依赖 worktree） | 大 | 约 3 回合 |
| H4 统一规则（已实现，待实测） | — | 中 | 约 3 回合 |
| H5 项目记忆（已实现，待实测） | H4 | 中 | 约 2 回合 |

H1 和 H2 互不依赖，可以并行开发，例如放到两个分支或两个子会话；H3 在 H2 之后。每个阶段单独成一个分支，合进 `main` 前跑全部离线测试，并按 `AGENTS.md` 重新打包验证。
