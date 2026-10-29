import assert from 'node:assert/strict';
import test from 'node:test';
import { BRIDGE_METHODS, createDemoBridge, validateBridge } from './bridge.js';

test('demo bridge exposes the bounded adapter surface', async () => {
  const bridge = createDemoBridge({ agents: [{ id: 'claude', provider: 'claude', name: 'Claude' }] });
  assert.equal(bridge.isDemo, true);
  assert.deepEqual((await bridge.listAgents())[0].id, 'claude');
  for (const method of BRIDGE_METHODS) assert.equal(typeof bridge[method], 'function');
  const tokens = [];
  const response = await bridge.sendMessage({ agentId: 'claude', text: 'hello', onToken: (token) => tokens.push(token) });
  assert.equal(typeof response, 'string');
  assert.ok(tokens.length > 1);
  assert.match(response, /本地演示回复/);
});

test('demo bridge aborts a stream without replacing it with a fallback', async () => {
  const bridge = createDemoBridge();
  const controller = new AbortController();
  const pending = bridge.sendMessage({ signal: controller.signal, text: 'cancel me', onToken: () => { controller.abort(); } });
  await assert.rejects(pending, (error) => error.name === 'AbortError');
});

test('invalid injected bridge fails closed and reports missing methods', async () => {
  const bridge = validateBridge({ listAgents() {} });
  assert.equal(bridge.unavailable, true);
  assert.match(bridge.error, /getPortfolio/);
  await assert.rejects(bridge.getPortfolio(), /桥接缺少方法/);
});

test('class-based host adapters retain methods and their receiver', async () => {
  class Host {
    constructor() { this.label = 'host'; }
    listAgents() { return [{ id: this.label }]; }
    getPortfolio() { return { source: this.label }; }
    sendMessage() { return this.label; }
    sendDiscussion() { return this.label; }
    subscribe() { return () => {}; }
  }
  const adapter = validateBridge(new Host());
  assert.equal((await adapter.getPortfolio()).source, 'host');
  assert.equal(await adapter.sendMessage(), 'host');
});

test('discussion streams identify each participating agent', async () => {
  const bridge = createDemoBridge({agents:[{id:'claude',name:'Claude'},{id:'codex',name:'Codex'}]});
  const speakers = new Set(); const text = new Map();
  await bridge.sendDiscussion({agentIds:['claude','codex'],text:'计划',onToken: chunk => { speakers.add(chunk.agentId); text.set(chunk.agentId,(text.get(chunk.agentId)||'')+chunk.text); }});
  assert.deepEqual([...speakers],['claude','codex']);
  assert.match(text.get('claude'), /Claude/); assert.match(text.get('codex'), /Codex/);
});
