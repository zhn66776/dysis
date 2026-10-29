import assert from 'node:assert/strict';
import test from 'node:test';
import { createRunController, createIdleSchedule } from './session-utils.js';

function fakeClock() {
  let now = 0; let id = 0; const timers = new Map(); const intervals = new Map();
  const setTimeoutFn = (fn, delay) => { const key = ++id; timers.set(key, { fn, at: now + delay }); return key; };
  const setIntervalFn = (fn, delay) => { const key = ++id; intervals.set(key, { fn, at: now + delay, delay }); return key; };
  const clearTimeoutFn = (key) => timers.delete(key); const clearIntervalFn = (key) => intervals.delete(key);
  const tick = (duration) => { const target = now + duration; while (true) { let next = null; for (const [key, item] of timers) if (item.at <= target && (!next || item.at < next.at)) next = { type: 'timeout', key, ...item }; for (const [key, item] of intervals) if (item.at <= target && (!next || item.at < next.at)) next = { type: 'interval', key, ...item }; if (!next) break; now = next.at; if (next.type === 'timeout') { timers.delete(next.key); next.fn(); } else { const item = intervals.get(next.key); if (item) { item.at += item.delay; next.fn(); } } } now = target; };
  return { setTimeoutFn, setIntervalFn, clearTimeoutFn, clearIntervalFn, tick };
}

test('idle schedule emits a countdown and expires with a fake clock', () => {
  const clock = fakeClock(); const ticks = []; let expired = 0;
  const schedule = createIdleSchedule({ delay: 3_000, tickMs: 1_000, ...clock, onTick: (seconds) => ticks.push(seconds), onExpire: () => { expired += 1; } });
  schedule.start(); clock.tick(2_000); assert.deepEqual(ticks, [3, 2, 1]); assert.equal(expired, 0); clock.tick(1_000); assert.equal(expired, 1); assert.equal(schedule.running, false);
});

test('new action invalidates a stale async action', () => {
  const gate = createRunController(); const first = gate.begin(); const second = gate.begin();
  assert.equal(first.controller.signal.aborted, true); assert.equal(gate.current(first.token), false); assert.equal(gate.current(second.token), true); gate.cancel(); assert.equal(gate.current(second.token), false);
});

test('default idle deadline is 60 seconds and activity restarts it', () => {
  const clock = fakeClock(); let expired = 0;
  const schedule = createIdleSchedule({ ...clock, onExpire: () => { expired++; } });
  schedule.start(); clock.tick(59_999); assert.equal(expired, 0);
  schedule.start(); clock.tick(59_999); assert.equal(expired, 0);
  clock.tick(1); assert.equal(expired, 1);
  schedule.start(); clock.tick(30_000); schedule.stop(); clock.tick(90_000); assert.equal(expired, 1);
});
