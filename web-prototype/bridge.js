/*
 * Optional AgentDesk bridge boundary.
 *
 * The browser demo never reads credentials and never launches a provider.  A
 * host may inject window.agentDeskBridge before app.js loads; the adapter is
 * deliberately small so the UI can fail closed when a method is missing.
 */

export const BRIDGE_METHODS = ['listAgents', 'getPortfolio', 'sendMessage', 'sendDiscussion', 'subscribe'];

export const DEFAULT_PORTFOLIO = Object.freeze({
  isDemo: true,
  source: '未连接',
  totalValue: null,
  dayChange: null,
  positions: [],
  series: [],
});

function abortError() {
  const error = new Error('操作已取消');
  error.name = 'AbortError';
  return error;
}

function assertNotAborted(signal) {
  if (signal?.aborted) throw abortError();
}

async function emitText(text, { signal, onToken } = {}) {
  const tokens = String(text).match(/.{1,7}/gu) || [];
  for (const token of tokens) {
    assertNotAborted(signal);
    if (typeof onToken === 'function') await onToken(token);
    await new Promise((resolve) => setTimeout(resolve, 26));
  }
  return String(text);
}

export function createDemoBridge({ agents = [] } = {}) {
  const listeners = new Set();
  const metadata = agents.map((agent) => ({ ...agent, model: agent.model ?? null, isDemo: true }));
  return {
    isDemo: true,
    methods: [...BRIDGE_METHODS, 'cancel'],
    async listAgents() { return metadata.map((agent) => ({ ...agent })); },
    async getPortfolio() { return { ...DEFAULT_PORTFOLIO }; },
    async sendMessage({ agentId, text, signal, onToken } = {}) {
      assertNotAborted(signal);
      const response = `本地演示回复（${agentId || '伙伴'}）：已收到“${String(text || '').slice(0, 80)}”。接入官方桥接后，这里会显示真实会话内容。`;
      await emitText(response, { signal, onToken });
      return response;
    },
    async sendDiscussion({ agentIds = [], text, signal, onToken } = {}) {
      assertNotAborted(signal);
      const contributions = [];
      for (const id of agentIds) {
        const name = metadata.find(item => item.id === id)?.name || id;
        const response = `${name} 的演示发言：我们一起讨论“${String(text || '').slice(0, 45)}”。真实回答会由接入的 Agent 提供。`;
        await emitText(response, { signal, onToken: token => onToken?.({ agentId: id, text: token }) });
        contributions.push(response);
      }
      return contributions.join('\n');
    },
    subscribe(listener) { if (typeof listener !== 'function') return () => {}; listeners.add(listener); return () => listeners.delete(listener); },
    cancel() { listeners.forEach((listener) => listener({ type: 'cancelled' })); },
  };
}

export function validateBridge(candidate) {
  const missing = BRIDGE_METHODS.filter((method) => typeof candidate?.[method] !== 'function');
  if (!candidate || missing.length) {
    return {
      isDemo: false,
      unavailable: true,
      error: `桥接缺少方法：${missing.join('、') || '未知错误'}`,
      methods: Object.keys(candidate || {}).filter((key) => typeof candidate[key] === 'function'),
      async listAgents() { throw new Error(this.error); },
      async getPortfolio() { throw new Error(this.error); },
      async sendMessage() { throw new Error(this.error); },
      async sendDiscussion() { throw new Error(this.error); },
      subscribe() { return () => {}; },
    };
  }
  const adapter = { isDemo: candidate.isDemo === true, methods: candidate.methods || BRIDGE_METHODS };
  for (const method of [...BRIDGE_METHODS, 'cancel']) if (typeof candidate[method] === 'function') adapter[method] = candidate[method].bind(candidate);
  return adapter;
}

export function resolveBridge({ agents = [] } = {}) {
  const injected = typeof window !== 'undefined' ? window.agentDeskBridge : undefined;
  return injected ? validateBridge(injected) : createDemoBridge({ agents });
}

export function setAgentDeskBridge(bridge) {
  if (typeof window === 'undefined') return false;
  window.agentDeskBridge = bridge;
  return true;
}
