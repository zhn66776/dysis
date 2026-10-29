import { createOfficeScene } from './scene.js';
import { BRIDGE_METHODS, DEFAULT_PORTFOLIO, resolveBridge } from './bridge.js';
import { createRunController, createIdleSchedule } from './session-utils.js';

const OWNER_ID = 'owner';
const AGENTS = [
  { id: 'claude', provider: 'claude', name: 'Claude', role: '工作台伙伴', model: null, color: '#b88c73', icon: '◌' },
  { id: 'codex', provider: 'codex', name: 'Codex', role: '工作台伙伴', model: null, color: '#7c9d84', icon: '✦' },
  { id: 'grok', provider: 'grok', name: 'Grok', role: '工作台伙伴', model: null, color: '#586874', icon: '↗' },
  { id: 'gemini', provider: 'gemini', name: 'Gemini', role: '工作台伙伴', model: null, color: '#9a98bd', icon: '✳' },
];
const VALID_PROVIDERS = new Set(AGENTS.map((item) => item.provider));
const DEFAULT_AGENTS = AGENTS.map((item) => ({ ...item }));
const PERIOD_NAMES = { dawn: '清晨', morning: '上午', noon: '中午', afternoon: '下午', dusk: '黄昏', night: '夜晚' };
const $ = (id) => document.getElementById(id);
const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
const agentMap = new Map(AGENTS.map((agent) => [agent.id, agent]));
const conversations = new Map();
const groupConversations = new Map();
const idleTimers = new Map();
const locations = new Map(AGENTS.map((agent) => [agent.id, 'desk']));
const runController = createRunController();
let bridge = resolveBridge({ agents: AGENTS });
let scene = null;
let ready = false;
let selectedId = null;
let ownerPanel = false;
let busy = false;
let periodChoice = 'auto';
let actionGeneration = 0;
let activeRun = null;
let transitioning = false;
let groupState = { active: false, ready: false, busy: false, ids: new Set(), conversation: [] };
let portfolio = { ...DEFAULT_PORTFOLIO };

const statusText = { arriving: '正在到达', ready: '已在办公室', thinking: '正在思考', answering: '正在回复', desk: '已回到工位', failed: '连接失败' };
const agent = (id) => agentMap.get(id);

function applyAgentMetadata(records) {
  const accepted = [];
  for (const record of Array.isArray(records) ? records : []) {
    const provider = String(record?.provider || record?.id || '').toLowerCase();
    const id = String(record?.id || provider).trim();
    if (!VALID_PROVIDERS.has(provider) || !/^(claude|codex|grok|gemini)(-[a-z0-9_-]{1,48})?$/.test(id) || accepted.some((item) => item.id === id)) continue;
    const fallback = DEFAULT_AGENTS.find((item) => item.provider === provider) || DEFAULT_AGENTS[0];
    accepted.push({ ...fallback, ...record, id, provider, name: record.name || fallback.name, color: /^#[0-9a-f]{6}$/i.test(record.color || '') ? record.color : fallback.color, icon: record.icon || fallback.icon, model: record.model ?? null });
    if (accepted.length >= 5) break;
  }
  if (!accepted.length) accepted.push(...DEFAULT_AGENTS.map((item) => ({ ...item })));
  AGENTS.splice(0, AGENTS.length, ...accepted);
  agentMap.clear(); locations.clear(); AGENTS.forEach((item) => { agentMap.set(item.id, item); locations.set(item.id, 'desk'); });
}

function groupConversationKey(ids) { return [...ids].sort().join('|'); }

function autoPeriod(date = new Date()) {
  const hour = date.getHours();
  return hour < 5 ? 'night' : hour < 8 ? 'dawn' : hour < 11 ? 'morning' : hour < 14 ? 'noon' : hour < 17 ? 'afternoon' : hour < 20 ? 'dusk' : 'night';
}

function updateClock() {
  const now = new Date();
  const formatter = new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', hour12: false });
  $('clock').textContent = formatter.format(now);
  $('timezone').textContent = Intl.DateTimeFormat().resolvedOptions().timeZone || '本地时区';
  if (periodChoice === 'auto') applyPeriod('auto', now);
}

function applyPeriod(choice, now = new Date()) {
  periodChoice = choice;
  const fallback = autoPeriod(now);
  let actual = choice === 'auto' ? fallback : choice;
  let label = `${choice === 'auto' ? '自动 · ' : ''}${PERIOD_NAMES[actual] || PERIOD_NAMES.afternoon}`;
  if (scene) {
    if (choice === 'auto' && typeof scene.setTime === 'function') {
      const result = scene.setTime(now) || {};
      actual = result.period || actual;
      label = result.label || `自动 · ${PERIOD_NAMES[actual] || PERIOD_NAMES.afternoon}`;
    } else scene.setPeriod?.(actual);
  }
  $('period-label').textContent = label;
  document.querySelectorAll('[data-period]').forEach((button) => button.classList.toggle('active', button.dataset.period === choice));
}

function updateBridgeBadge() {
  const demo = bridge.isDemo === true;
  $('bridge-badge').innerHTML = `<i></i> ${demo ? '本地演示' : bridge.unavailable ? '桥接不可用' : '页面桥接'}`;
  $('composer-status').textContent = demo ? '本地演示' : bridge.unavailable ? '桥接不可用' : '桥接已提供';
}

function renderRoster() {
  const list = $('roster-list');
  list.replaceChildren();
  AGENTS.forEach((item) => {
    const button = document.createElement('button');
    button.type = 'button'; button.className = 'roster-chip'; button.dataset.agentId = item.id; button.dataset.status = item.status || 'idle';
    button.style.setProperty('--agent-color', item.color); button.setAttribute('aria-label', `邀请 ${item.name} 到办公室`);
    button.innerHTML = `<span class="roster-avatar">${escapeHTML(item.icon)}</span><span><strong>${escapeHTML(item.name)}</strong><small>${escapeHTML(item.model || item.provider)}</small></span><i class="roster-state" aria-hidden="true" title="${statusText[item.status] || '在工位'}"></i>`;
    button.addEventListener('click', () => inviteAgent(item.id)); list.append(button);
  });
  $('agent-count').textContent = String(AGENTS.length).padStart(2, '0');
}

function renderGroupList() {
  const list = $('group-agent-list'); list.replaceChildren();
  AGENTS.forEach((item) => {
    const label = document.createElement('label'); label.className = 'group-agent-option';
    const checked = groupState.ids.size ? groupState.ids.has(item.id) : true;
    label.innerHTML = `<input type="checkbox" value="${item.id}" ${checked ? 'checked' : ''}><span class="roster-avatar" style="--agent-color:${item.color}">${escapeHTML(item.icon)}</span><span><strong>${escapeHTML(item.name)}</strong><small>${escapeHTML(item.provider)}</small></span>`;
    list.append(label);
  });
  list.querySelectorAll('input').forEach((input) => input.addEventListener('change', updateGroupSelection));
  updateGroupSelection();
}

function selectedGroupIds() { return [...$('group-agent-list').querySelectorAll('input:checked')].map((input) => input.value); }

function updateGroupSelection() {
  const count = selectedGroupIds().length;
  $('group-note').textContent = count < 2 ? '至少选择 2 位伙伴开始群聊。' : `${count} 位伙伴将留在休息区。`;
  $('apply-group').disabled = count < 2 || groupState.busy || busy || transitioning;
}

function renderConversation(target, messages) {
  const box = $(target); box.replaceChildren();
  if (!messages?.length) {
    const empty = document.createElement('div'); empty.className = 'conversation-empty';
    empty.innerHTML = '<span>✳</span><strong>从一个问题开始</strong><p>在下方写下你的想法。</p>'; box.append(empty); return;
  }
  messages.forEach((message) => {
    const wrap = document.createElement('div'); wrap.className = `message ${message.state || ''}`;
    const author = document.createElement('b'); author.textContent = message.author;
    const text = document.createElement('p'); text.textContent = message.text || (message.state === 'streaming' ? '…' : '');
    wrap.append(author, text); box.append(wrap);
  }); box.scrollTop = box.scrollHeight;
}

function activeConversation() { return selectedId ? conversations.get(selectedId) : null; }

function clearIdle(agentId) {
  if (selectedId === agentId) updateIdleUI(null);
  const current = idleTimers.get(agentId); if (!current) return;
  current.stop?.(); idleTimers.delete(agentId);
}

function updateIdleUI(seconds = null) {
  const visible = Number.isFinite(seconds) && selectedId && locations.get(selectedId) === 'office' && !busy;
  $('idle-line').hidden = !visible; $('composer-idle').hidden = !visible;
  if (visible) { $('idle-line').dataset.idleSeconds = String(seconds); $('idle-seconds').textContent = String(seconds); $('composer-idle-seconds').textContent = `${seconds}s 后回桌`; }
}

function armIdle(agentId) {
  clearIdle(agentId);
  if (locations.get(agentId) !== 'office' || busy || groupState.active) { updateIdleUI(null); return; }
  const schedule = createIdleSchedule({ onTick: (seconds) => { if (selectedId === agentId) updateIdleUI(seconds); }, onExpire: () => { idleTimers.delete(agentId); if (!busy && locations.get(agentId) === 'office') returnAgentToDesk(agentId); } });
  idleTimers.set(agentId, schedule); schedule.start();
}

function cancelActiveRun() {
  if (activeRun?.answer) { activeRun.answer.state = 'cancelled'; if (activeRun.messages) { activeRun.messages.forEach(message => { if (message.state === 'streaming') message.state = 'cancelled'; }); renderConversation(activeRun.target, activeRun.messages); } }
  runController.cancel();
  if (activeRun) activeRun.controller.abort();
  activeRun = null; busy = false; updateComposer();
}

function currentRun(token) { return activeRun?.generation === token && runController.current(token); }

function setAgentStatus(id, status) {
  scene?.setStatus?.(id, status);
  const chip = document.querySelector(`.roster-chip[data-agent-id="${id}"]`);
  if (chip) { chip.dataset.status = status; chip.querySelector('.roster-state')?.setAttribute('title', statusText[status] || status); }
  if (selectedId === id) $('agent-status').textContent = statusText[status] || status;
}

async function returnAgentToDesk(id) {
  if (busy || locations.get(id) !== 'office') return false;
  const token = ++actionGeneration; transitioning = true; clearIdle(id); setAgentStatus(id, 'arriving'); updateComposer();
  const result = await Promise.resolve(scene?.moveActor?.(id, 'desk'));
  if (token !== actionGeneration) return false;
  transitioning = false;
  if (result === false) { setAgentStatus(id, 'failed'); updateComposer(); return false; }
  locations.set(id, 'desk'); setAgentStatus(id, 'desk'); updateComposer(); if (selectedId === id) { updateIdleUI(null); $('panel-description').textContent = '伙伴已回到自己的工位。继续发送消息，会再次邀请他到办公室。'; } return true;
}

function showPanel(id) {
  document.querySelectorAll('.side-panel').forEach((panel) => { panel.hidden = panel.id !== id; });
}

function closePanel(panel = null) {
  if (panel) panel.hidden = true;
  else document.querySelectorAll('.side-panel').forEach((item) => { item.hidden = true; });
  // Closing a panel is a visual action only. Actors keep their physical place.
}

async function inviteAgent(id) {
  const next = agent(id); if (!next || !ready || !scene) return;
  if (groupState.active || groupState.busy) { const ended = await endDiscussion(); if (!ended) return false; }
  cancelActiveRun();
  const token = ++actionGeneration; transitioning = true;
  const priorIds = AGENTS.map((item) => item.id).filter((agentId) => agentId !== id);
  priorIds.forEach((agentId) => clearIdle(agentId));
  selectedId = id; ownerPanel = false; clearIdle(id); groupState = { active: false, ready: false, busy: false, ids: new Set(), conversation: [] };
  scene.select?.(id); setAgentStatus(id, 'arriving');
  showPanel('agent-panel'); renderAgentPanel(next); updateComposer();
  const moved = await Promise.all([Promise.resolve(scene.moveActors?.(priorIds, 'desk') || []), Promise.resolve(scene.moveActor?.(id, 'office')), Promise.resolve(scene.moveActor?.(OWNER_ID, 'office'))]);
  if (token !== actionGeneration) return false;
  const priorMoved = Array.isArray(moved[0]) ? moved[0] : [];
  if (priorMoved.some((value) => value === false) || moved.slice(1).some((value) => value === false)) { transitioning = false; setAgentStatus(id, 'failed'); $('panel-description').innerHTML = '无法完成这次移动。<br><span>请稍后重试。</span>'; updateComposer(); return false; }
  priorIds.forEach((agentId) => { locations.set(agentId, 'desk'); setAgentStatus(agentId, 'desk'); });
  locations.set(id, 'office'); transitioning = false; setAgentStatus(id, 'ready'); $('panel-description').innerHTML = '伙伴已经坐到你的桌边。<br><span>把一个问题放到桌面上，我们一起看清它。</span>'; armIdle(id); updateComposer(); return true;
}

function renderAgentPanel(next) {
  $('agent-name').textContent = next.name; $('agent-role').textContent = next.role; $('panel-avatar').textContent = next.icon; $('panel-avatar').style.setProperty('--agent-color', next.color);
  $('agent-provider').textContent = next.provider; $('agent-model').textContent = next.model || '模型未选择'; $('agent-capabilities').textContent = Array.isArray(next.capabilities) && next.capabilities.length ? next.capabilities.join(' · ') : (next.status || '能力未读取');
  $('agent-status').textContent = statusText.arriving; renderConversation('conversation', conversations.get(next.id));
}

async function openLounge() {
  if (!ready || !scene) return;
  cancelActiveRun(); ++actionGeneration; transitioning = true; selectedId = null; ownerPanel = false; idleTimers.forEach((_, id) => clearIdle(id));
  groupState = { active: false, ready: false, busy: true, ids: new Set(AGENTS.map((item) => item.id)), conversation: [] };
  AGENTS.forEach((item) => setAgentStatus(item.id, 'arriving'));
  scene.select?.(null); showPanel('group-panel'); renderGroupList(); $('apply-group').disabled = true; $('group-note').textContent = '正在邀请所有伙伴到休息区…'; updateComposer();
  const token = actionGeneration;
  const moved = await Promise.resolve(scene.moveActors?.([...AGENTS.map((item) => item.id), OWNER_ID], 'lounge'));
  if (token !== actionGeneration) return;
  if (Array.isArray(moved) && moved.some((value) => value === false)) { transitioning = false; groupState.busy = false; $('group-note').textContent = '有伙伴无法到达休息区，请重试。'; updateGroupSelection(); return; }
  AGENTS.forEach((item) => locations.set(item.id, 'lounge')); transitioning = false; groupState.active = true; groupState.ready = true; groupState.busy = false; groupState.ids = new Set(AGENTS.map((item) => item.id)); const allKey = groupConversationKey(groupState.ids); groupState.conversation = groupConversations.get(allKey) || []; groupConversations.set(allKey, groupState.conversation); renderGroupList(); renderConversation('group-conversation', groupState.conversation); updateComposer();
}

async function applyGroup() {
  const ids = selectedGroupIds(); if (ids.length < 2 || !groupState.ready || groupState.busy) return;
  const token = ++actionGeneration; transitioning = true; groupState.busy = true; groupState.ids = new Set(ids); updateGroupSelection();
  const excluded = AGENTS.map((item) => item.id).filter((id) => !groupState.ids.has(id));
  const [kept, sentBack] = await Promise.all([Promise.resolve(scene.moveActors?.([...ids, OWNER_ID], 'lounge')), Promise.resolve(scene.moveActors?.(excluded, 'desk'))]);
  if (token !== actionGeneration) return;
  if ([...(kept || []), ...(sentBack || [])].some((value) => value === false)) { transitioning = false; groupState.busy = false; $('group-note').textContent = '有伙伴无法完成移动，请重试。'; updateGroupSelection(); return; }
  excluded.forEach((id) => { locations.set(id, 'desk'); setAgentStatus(id, 'desk'); }); ids.forEach((id) => { locations.set(id, 'lounge'); setAgentStatus(id, 'ready'); }); transitioning = false; groupState.active = true; groupState.ready = true; groupState.busy = false; const membershipKey = groupConversationKey(ids); groupState.conversation = groupConversations.get(membershipKey) || []; groupConversations.set(membershipKey, groupState.conversation); renderGroupList(); renderConversation('group-conversation', groupState.conversation); updateComposer();
}

async function endDiscussion() {
  const token = ++actionGeneration; cancelActiveRun(); transitioning = true; groupState.busy = true;
  const moved = await Promise.resolve(scene?.moveActors?.([...AGENTS.map((item) => item.id), OWNER_ID], 'desk'));
  if (token !== actionGeneration) return false;
  if (Array.isArray(moved) && moved.some((value) => value === false)) { transitioning = false; groupState.busy = false; $('group-note').textContent = '有伙伴无法回到工位，请重试。'; return false; }
  AGENTS.forEach((item) => { locations.set(item.id, 'desk'); setAgentStatus(item.id, 'desk'); }); transitioning = false; groupState = { active: false, ready: false, busy: false, ids: new Set(), conversation: [] }; scene?.select?.(null); closePanel($('group-panel')); updateComposer(); return true;
}

async function showOwner() {
  if (groupState.active || groupState.busy) { const ended = await endDiscussion(); if (!ended) return; }
  const token = ++actionGeneration; transitioning = true;
  cancelActiveRun();
  const moved = await Promise.resolve(scene?.moveActor?.(OWNER_ID, 'office'));
  if (token !== actionGeneration || moved === false) { transitioning = false; updateComposer(); return; }
  locations.set(OWNER_ID, 'office');
  transitioning = false;
  selectedId = null; ownerPanel = true; scene?.select?.(OWNER_ID); showPanel('agent-panel'); $('panel-avatar').textContent = '○'; $('panel-avatar').style.setProperty('--agent-color', '#8ba88c'); $('agent-name').textContent = '你'; $('agent-role').textContent = '工作室主理人'; $('agent-provider').textContent = '当前空间'; $('agent-model').textContent = '本地界面'; $('agent-capabilities').textContent = '当前空间'; $('agent-status').textContent = '在办公室'; $('panel-description').innerHTML = '这是你的桌面。伙伴会在这里等你邀请。<br><span>点击关闭不会改变任何人的位置。</span>'; renderConversation('conversation', []); updateComposer(); }

function renderPortfolio() {
  const snapshot = portfolio || DEFAULT_PORTFOLIO;
  const formatMoney = (value) => { if (value === null || value === undefined || value === '') return '—'; const number = Number(value); if (!Number.isFinite(number)) return '—'; try { return new Intl.NumberFormat(undefined, { style: 'currency', currency: snapshot.currency || 'GBP', maximumFractionDigits: 0 }).format(number); } catch (_) { return String(value); } };
  const formatChange = (value) => { if (value === null || value === undefined || value === '') return '—'; const number = Number(value); return Number.isFinite(number) ? `${number > 0 ? '+' : ''}${number}%` : '—'; };
  $('portfolio-source').textContent = `来源 · ${snapshot.source || '未连接'}`; $('portfolio-total').textContent = formatMoney(snapshot.totalValue); $('portfolio-change').textContent = formatChange(snapshot.dayChange);
  const positions = Array.isArray(snapshot.positions) ? snapshot.positions : []; const validSeries = (Array.isArray(snapshot.series) ? snapshot.series : []).filter(point => point?.value !== null && point?.value !== undefined && point?.value !== '').map((point) => ({ ...point, value: Number(point.value) })).filter((point) => Number.isFinite(point.value)); const empty = $('portfolio-empty'); empty.hidden = positions.length > 0 || validSeries.length > 1; const positionBox = $('portfolio-positions'); positionBox.replaceChildren(); positions.forEach((position) => { const row = document.createElement('div'); row.className = 'portfolio-row'; const symbol = document.createElement('span'); symbol.textContent = position.symbol || '—'; const quantity = document.createElement('b'); quantity.textContent = position.quantity ?? '—'; const value = document.createElement('em'); value.textContent = formatMoney(position.value); row.append(symbol, quantity, value); positionBox.append(row); });
  const chart = $('portfolio-chart'); chart.hidden = validSeries.length < 2; chart.replaceChildren(); if (validSeries.length > 1) { const values = validSeries.map((point) => point.value); const min = Math.min(...values); const max = Math.max(...values); const span = max - min || 1; const points = values.map((value, i) => `${(i / Math.max(values.length - 1, 1)) * 100},${92 - ((value - min) / span) * 80}`).join(' '); const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); svg.setAttribute('viewBox', '0 0 100 100'); svg.setAttribute('preserveAspectRatio', 'none'); svg.setAttribute('aria-label', '投资组合价格序列'); const polyline = document.createElementNS('http://www.w3.org/2000/svg', 'polyline'); polyline.setAttribute('points', points); polyline.setAttribute('fill', 'none'); polyline.setAttribute('stroke', 'currentColor'); polyline.setAttribute('stroke-width', '1.8'); polyline.setAttribute('vector-effect', 'non-scaling-stroke'); svg.append(polyline); const caption = document.createElement('small'); caption.textContent = '已提供的序列'; chart.append(svg, caption); }
}

async function openPortfolio() { showPanel('portfolio-panel'); renderPortfolio(); try { const result = await bridge.getPortfolio(); if (result) { portfolio = result; scene?.setPortfolio?.(portfolio); renderPortfolio(); } } catch (error) { portfolio = { ...DEFAULT_PORTFOLIO, source: '读取失败' }; scene?.setPortfolio?.(portfolio); renderPortfolio(); } }

function renderConnection() {
  const status = $('connection-state'); status.className = `connection-state ${bridge.unavailable ? 'is-error' : ''}`; status.textContent = bridge.unavailable ? bridge.error : bridge.isDemo ? '本地演示桥接 · 未连接官方账户' : '已发现页面桥接 · Provider 状态仍需由桥接声明';
  $('provider-status-list').innerHTML = AGENTS.map((item) => `<div class="provider-status"><span class="roster-avatar" style="--agent-color:${item.color}">${escapeHTML(item.icon)}</span><span><strong>${escapeHTML(item.name)}</strong><small>${escapeHTML(item.provider)}</small></span><em>${item.connected === true ? '已连接' : '未连接'}</em></div>`).join('');
  const methods = bridge.methods || BRIDGE_METHODS; $('method-list').innerHTML = `<strong>可用方法</strong>${methods.map((method) => `<span>${escapeHTML(method)}</span>`).join('')}`;
}

function updateComposer() {
  if (groupState.active) updateGroupSelection();
  const privateReady = Boolean(selectedId && !transitioning && !busy && !ownerPanel);
  const groupReady = Boolean(groupState.active && groupState.ready && !groupState.busy && groupState.ids.size >= 2 && !transitioning && !busy);
  const canWrite = ready && (privateReady || groupReady);
  $('prompt-input').disabled = !canWrite; $('submit-button').disabled = !canWrite;
  $('composer-label').textContent = transitioning ? '正在调整座位…' : busy ? (groupState.active ? '伙伴正在讨论…' : '伙伴正在工作…') : groupReady ? `休息区讨论 · ${groupState.ids.size} 位伙伴` : selectedId ? (locations.get(selectedId) === 'office' ? `发消息给 ${agent(selectedId).name}` : `准备邀请 ${agent(selectedId).name}`) : ownerPanel ? '你的桌面 · 选择一位伙伴开始' : '选择一位伙伴，邀请到你的办公室';
  $('prompt-input').placeholder = groupReady ? '对大家说点什么…' : selectedId ? `告诉 ${agent(selectedId).name} 你的想法…` : '选择伙伴后，在这里写下你的想法…';
}

function registerActivity() { if (selectedId && locations.get(selectedId) === 'office' && !busy && !groupState.active) armIdle(selectedId); }

async function sendCurrent(event) {
  event.preventDefault(); const text = $('prompt-input').value.trim(); if (!text || busy || transitioning || (!selectedId && !groupState.active)) return;
  const isGroup = groupState.active && groupState.ready && groupState.ids.size >= 2; const agentId = selectedId;
  if (!isGroup && agentId && locations.get(agentId) !== 'office') { const draft = text; const entered = await inviteAgent(agentId); if (!entered) { $('prompt-input').value = draft; return; } }
  $('prompt-input').value = ''; const run = runController.begin(); const token = run.token; const controller = run.controller; activeRun = { controller, generation: token }; busy = true; if (agentId) clearIdle(agentId); updateComposer();
  const messages = isGroup ? groupState.conversation : (conversations.get(agentId) || []); if (isGroup) groupConversations.set(groupConversationKey(groupState.ids), messages); else conversations.set(agentId, messages); messages.push({ author: '你', text, state: 'complete' });
  if (isGroup) groupState.ids.forEach((id) => setAgentStatus(id, 'thinking')); else setAgentStatus(agentId, 'thinking');
  const answer = { author: isGroup ? `休息区${bridge.isDemo ? ' · 本地演示' : ''}` : `${agent(agentId).name}${bridge.isDemo ? ' · 本地演示' : ''}`, text: '', state: 'streaming' }; messages.push(answer); activeRun.answer = answer; activeRun.messages = messages; activeRun.target = isGroup ? 'group-conversation' : 'conversation'; renderConversation(isGroup ? 'group-conversation' : 'conversation', messages);
  let receivedToken = false; const speakerAnswers = new Map();
  const onToken = async (chunk) => {
    if (!currentRun(token)) return;
    if (isGroup && chunk && typeof chunk === 'object' && groupState.ids.has(chunk.agentId)) {
      let message = speakerAnswers.get(chunk.agentId);
      if (!message) {
        message = speakerAnswers.size ? { author: '', text: '', state: 'streaming' } : answer;
        message.author = `${agent(chunk.agentId).name}${bridge.isDemo ? ' · 演示' : ''}`;
        if (speakerAnswers.size) messages.push(message);
        speakerAnswers.forEach(item => { item.state = 'complete'; });
        speakerAnswers.set(chunk.agentId, message);
        groupState.ids.forEach(id => setAgentStatus(id, id === chunk.agentId ? 'answering' : 'ready'));
      }
      message.text += String(chunk.text || ''); receivedToken = true;
    } else {
      if (!receivedToken) { receivedToken = true; if (isGroup) groupState.ids.forEach(id => setAgentStatus(id, 'answering')); else setAgentStatus(agentId, 'answering'); }
      answer.text += typeof chunk === 'string' ? chunk : String(chunk?.text || '');
    }
    renderConversation(isGroup ? 'group-conversation' : 'conversation', messages);
  };
  try {
    const response = isGroup ? await bridge.sendDiscussion({ agentIds: [...groupState.ids], text, conversationId: `group:${[...groupState.ids].sort().join(',')}`, signal: controller.signal, onToken }) : await bridge.sendMessage({ agentId, text, conversationId: `agent:${agentId}`, signal: controller.signal, onToken });
    if (!currentRun(token)) return; if (!answer.text && response != null) answer.text = String(response); answer.state = 'complete'; speakerAnswers.forEach(message => { message.state = 'complete'; });
  } catch (error) {
    if (!currentRun(token)) return; answer.state = error?.name === 'AbortError' ? 'cancelled' : 'failed'; answer.text = error?.name === 'AbortError' ? '这次回复已取消。' : `连接失败：${error?.message || '无法读取桥接回复。'}`; if (agentId) setAgentStatus(agentId, 'failed');
  } finally {
    if (!currentRun(token)) return; busy = false; activeRun = null; renderConversation(isGroup ? 'group-conversation' : 'conversation', messages); if (isGroup) groupState.ids.forEach((id) => setAgentStatus(id, answer.state === 'complete' ? 'ready' : 'failed')); else if (agentId && locations.get(agentId) === 'office') { setAgentStatus(agentId, answer.state === 'complete' ? 'ready' : 'failed'); armIdle(agentId); } updateComposer();
  }
}

function onBridgeEvent(event) { if (event?.type === 'status' && event.agentId) { if (['thinking','working','answering'].includes(event.status)) clearIdle(event.agentId); else if (['ready','idle'].includes(event.status) && event.agentId === selectedId) armIdle(event.agentId); } if (event?.type === 'portfolio' && event.snapshot) { portfolio = event.snapshot; scene?.setPortfolio?.(portfolio); if (!$('portfolio-panel').hidden) renderPortfolio(); } if (event?.type === 'status' && event.agentId) setAgentStatus(event.agentId, event.status || 'ready'); }

async function bindBridge() {
  updateBridgeBadge(); renderConnection();
  try {
    const items = await Promise.race([Promise.resolve(bridge.listAgents?.()), new Promise((_, reject) => setTimeout(() => reject(new Error('metadata timeout')), 1500))]);
    applyAgentMetadata(items); renderRoster(); renderConnection();
  } catch (_) {
    applyAgentMetadata(DEFAULT_AGENTS); renderRoster(); renderConnection();
  }
  try { bridge.subscribe?.(onBridgeEvent); } catch (_) { /* unavailable subscriptions are shown in the connection panel */ }
}

function toggleLighting(force) { const menu = $('lighting-menu'); const open = typeof force === 'boolean' ? force : menu.hidden; menu.hidden = !open; $('lighting-button').setAttribute('aria-expanded', String(open)); }

function mountScene() {
  try {
    scene = createOfficeScene($('office-scene'), { agents: AGENTS, onAgentSelect: inviteAgent, onLoungeSelect: openLounge, onOwnerSelect: showOwner, onPortfolioSelect: openPortfolio }); ready = Boolean(scene); scene?.setPortfolio?.(portfolio); updateComposer(); applyPeriod(periodChoice);
  } catch (error) { console.error('Office scene failed to load', error); $('office-scene').innerHTML = '<div class="scene-error"><strong>空间暂时无法显示</strong><span>请刷新页面后再试一次。</span></div>'; }
}

renderRoster();
$('prompt-form').addEventListener('submit', sendCurrent); $('prompt-input').addEventListener('input', registerActivity);
$('connection-button').addEventListener('click', () => { renderConnection(); showPanel('connection-panel'); }); $('portfolio-button').addEventListener('click', openPortfolio);
document.querySelectorAll('[data-close-panel]').forEach((button) => button.addEventListener('click', () => closePanel(button.closest('.side-panel'))));
$('lighting-button').addEventListener('click', () => toggleLighting()); $('composer-lighting').addEventListener('click', () => toggleLighting(true));
document.querySelectorAll('[data-period]').forEach((button) => button.addEventListener('click', () => { applyPeriod(button.dataset.period); toggleLighting(false); }));
$('apply-group').addEventListener('click', applyGroup); $('end-discussion').addEventListener('click', () => endDiscussion());
$('office-scene').addEventListener('scene:actor', (event) => { const detail = event.detail || {}; if (detail.id && detail.location && locations.has(detail.id)) locations.set(detail.id, detail.location); updateComposer(); });
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') { if (!$('lighting-menu').hidden) toggleLighting(false); else closePanel(); } });
async function boot() { await bindBridge(); updateClock(); setInterval(updateClock, 30_000); mountScene(); }
boot();
