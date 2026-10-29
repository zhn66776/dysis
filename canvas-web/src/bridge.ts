import type { Command, Incoming } from './types'

declare global {
  interface Window {
    webkit?: { messageHandlers?: { agentDesk?: { postMessage(message: unknown): void } } }
    agentDesk?: { receive(payload: unknown): void }
  }
}

type Listener = (payload: Incoming) => void
const listeners = new Set<Listener>()

// Swift calls window.agentDesk.receive(...) only after the page sends `ready`,
// so this must exist before the first command goes out.
window.agentDesk = { receive: payload => listeners.forEach(l => l(payload as Incoming)) }

export const isNative = Boolean(window.webkit?.messageHandlers?.agentDesk)

let mock: Promise<(command: Command) => void> | null = null

export function send(command: Command) {
  const native = window.webkit?.messageHandlers?.agentDesk
  if (native) { native.postMessage(command); return }
  // Browser preview only: a local simulation that never calls a model.
  mock ??= import('./mock').then(m => m.createMockHost(payload => window.agentDesk!.receive(payload)))
  void mock.then(handle => handle(command))
}

export function subscribe(listener: Listener) {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}
