// The app window has a transparent title bar and this page runs under it.
// Swift sends the title-bar height and where the traffic lights end; the page
// keeps clear of them and reports which top-strip areas ([data-drag]) move the
// window, minus the controls inside them.
import { send } from './bridge'
import type { ChromeInsets, Region } from './types'

const interactive = 'button, input, textarea, select, a, [role="button"], .dropdown'
let observing = false
let last = ''
let frame = 0

export function applyChrome({ top, left }: ChromeInsets) {
  const root = document.documentElement
  root.style.setProperty('--chrome-top', `${top}px`)
  root.style.setProperty('--chrome-left', `${left}px`)
  root.classList.toggle('chrome-inset', top > 0)
  if (!observing) {
    observing = true
    new ResizeObserver(schedule).observe(root)
    new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] })
  }
  schedule()
}

const box = (e: Element): Region => {
  const r = e.getBoundingClientRect()
  return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) }
}

function schedule() {
  cancelAnimationFrame(frame)
  frame = requestAnimationFrame(() => {
    const drag = [...document.querySelectorAll('[data-drag]')].map(box).filter(r => r.w > 0 && r.h > 0)
    const noDrag = [...document.querySelectorAll(`[data-drag] :is(${interactive})`)].map(box).filter(r => r.w > 0 && r.h > 0)
    const key = JSON.stringify([drag, noDrag])
    if (key === last) return
    last = key
    send({ type: 'chrome.regions', drag, noDrag })
  })
}
