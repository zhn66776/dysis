import { useEffect, useRef } from 'react'
import type { ConfirmShow } from './types'

// Replaces the native NSAlert (design/CANVAS.md §4.2 `confirm.show`). The action
// runs only after a click on its button; Esc, Cancel and the backdrop decline.
// Focus starts on Cancel so Return or Space never confirms by accident.
export function ConfirmDialog({ request, onAnswer }: { request: ConfirmShow; onAnswer: (ok: boolean) => void }) {
  const cancelRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    cancelRef.current?.focus()
    const onKey = (e: KeyboardEvent) => {
      // While the dialog is open no key reaches the canvas or the panel
      // (Delete, Esc, shortcuts); default actions such as Tab still work.
      e.stopPropagation()
      if (e.key === 'Escape' && !e.isComposing) { e.preventDefault(); onAnswer(false) }
    }
    document.addEventListener('keydown', onKey, true)
    return () => document.removeEventListener('keydown', onKey, true)
  }, [request.id, onAnswer])

  return (
    <div className="modal-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) onAnswer(false) }}>
      <div className="modal" role="alertdialog" aria-modal="true" aria-labelledby="confirm-title" aria-describedby="confirm-detail">
        <div id="confirm-title" className="modal-title">{request.title}</div>
        <div id="confirm-detail" className="modal-detail">{request.detail}</div>
        <div className="modal-actions">
          <button ref={cancelRef} className="btn" onClick={() => onAnswer(false)}>取消</button>
          <button className="btn danger" onClick={() => onAnswer(true)}>{request.action}</button>
        </div>
      </div>
    </div>
  )
}
