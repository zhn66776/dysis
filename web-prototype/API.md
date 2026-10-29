# AgentDesk 网页桥接边界

网页默认使用 `createDemoBridge()`，所有回答都会标记为本地演示。它不读取凭据、不启动官方 CLI，也不访问网络。宿主可以在加载 `app.js` 前注入 `window.agentDeskBridge`，页面会通过 `resolveBridge()` 使用它；缺少必需方法时，连接面板显示错误，消息会失败并保留在当前对话中，不会静默回退到演示回答。

桥接需要提供以下方法：

```js
{
  isDemo?: boolean,
  methods?: string[],
  listAgents(): Promise<AgentMetadata[]>,
  getPortfolio(): Promise<PortfolioSnapshot>,
  sendMessage(input): Promise<string | void>,
  sendDiscussion(input): Promise<string | void>,
  subscribe(listener): (() => void),
  cancel?: () => void,
}
```

`sendMessage` 的输入为 `{ agentId, text, conversationId, signal, onToken }`；`sendDiscussion` 的输入为 `{ agentIds, text, conversationId, signal, onToken }`。私聊的 `onToken` 接收字符串片段；群聊支持 `{ agentId, text }` 片段，按发言者分别展示，也兼容字符串片段。`signal` 是每次运行的 `AbortSignal`。宿主应在取消时停止自己的流，无法连接时抛出错误。

Agent 元数据只接受页面已知的 Provider ID：`claude`、`codex`、`grok`、`gemini`。`model` 可以是 `null`，页面不会猜测当前账户可用的模型，也不会显示额度或上下文占用的虚构数值。

投资组合快照可以包含：

```js
{
  connected: false,
  currency: 'GBP',
  source: '未连接',
  totalValue: null,
  dayChange: null,
  positions: [{ symbol, quantity, value }],
  series: [{ time, value }]
}
```

没有持仓或序列时，页面显示空状态。只有收到至少两个有效 `series` 点时才绘制价格序列。页面不会把 `null` 转成零，也不会把演示值当成账户数据。

场景由 `createOfficeScene(container, { agents, onAgentSelect, onLoungeSelect, onOwnerSelect, onPortfolioSelect })` 创建，返回：

```js
{
  moveActor(id, 'desk' | 'office' | 'lounge'): Promise<boolean>,
  moveActors(ids, destination): Promise<boolean[]>,
  select(id), setStatus(id, status),
  setPeriod(period), setTime(date), setPortfolio(snapshot), getSnapshot(), destroy()
}
```

`owner` 是场景中的当前用户。页面只在私密办公室或休息区到达后启用输入；私聊和群聊各自保留 transcript。页面内的 60 秒闲置回桌是内存定时器，不会创建操作系统计划任务。

场景使用固定俯视角。相机不会因点击伙伴、打开面板或关闭面板而移动；窗口尺寸变化只触发画布响应式调整，不改变互动状态。

`session-utils.js` 导出 `createIdleSchedule()` 和 `createRunController()`，分别负责可注入时钟的闲置倒计时与请求序号、取消控制。它们不依赖 DOM，便于离线行为测试。

Agent 元数据使用稳定的 `id` 和 `provider`。同一 Provider 的额外伙伴可使用 `codex-reviewer` 这样的 ID，页面最多接收 5 位。其余字段包括 `name`、`role`、`model`、`color`、`connected`、`capabilities`。官方 Session ID 和工作目录的映射由宿主分别维护；前端的 `conversationId` 只是对话键，不替代官方 Session ID。

订阅事件支持 `{type:'status',agentId,status}` 和 `{type:'portfolio',snapshot}`。状态包括 `idle/ready/thinking/working/answering/failed`。`dayChange` 使用百分数，例如 `1.2` 表示 `+1.2%`；资产和持仓金额使用 `currency` 指定的币种。

真实桥接由宿主在页面加载前注入。本原型没有官方 CLI 后端，也没有把浏览器连接到账户。缺失或失败的真实接口会显示错误。
