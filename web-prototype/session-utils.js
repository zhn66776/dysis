/* Small, dependency-free lifecycle helpers used by the in-page controller. */
export function createRunController({ AbortControllerClass = AbortController } = {}) {
  let generation = 0;
  let controller = null;
  return {
    begin() {
      controller?.abort();
      controller = new AbortControllerClass();
      const token = ++generation;
      return { token, controller };
    },
    cancel() {
      controller?.abort(); controller = null; generation += 1;
    },
    current(token) { return generation === token && Boolean(controller) && !controller.signal.aborted; },
  };
}

export function createIdleSchedule({ delay = 60_000, tickMs = 1_000, setTimeoutFn = setTimeout, setIntervalFn = setInterval, clearTimeoutFn = clearTimeout, clearIntervalFn = clearInterval, onTick = () => {}, onExpire = () => {} } = {}) {
  let timeout = null;
  let interval = null;
  let running = false;
  const stop = () => { if (timeout !== null) clearTimeoutFn(timeout); if (interval !== null) clearIntervalFn(interval); timeout = null; interval = null; running = false; };
  const start = () => {
    stop(); running = true; let seconds = Math.ceil(delay / 1000); onTick(seconds);
    interval = setIntervalFn(() => { seconds -= Math.ceil(tickMs / 1000); onTick(Math.max(0, seconds)); }, tickMs);
    timeout = setTimeoutFn(() => { stop(); onExpire(); }, delay);
    return stop;
  };
  return { start, stop, get running() { return running; } };
}
