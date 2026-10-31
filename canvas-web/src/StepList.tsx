import { useEffect, useState } from 'react'
import { send, subscribe } from './bridge'
import { diffLabel, diffLineClass, exitLabel, splitDiff, stepKindLabel, stepStateLabel, stepsSummary } from './steps'
import type { DiffStat, StepPayload } from './types'

/** A diff with added and removed lines coloured. */
export function DiffText({ text }: { text: string }) {
  return (
    <pre className="diff-text">
      {text.split('\n').map((line, i) => <div key={i} className={diffLineClass(line)}>{line || ' '}</div>)}
    </pre>
  )
}

function Step({ step }: { step: StepPayload }) {
  const [open, setOpen] = useState(false)
  const expandable = Boolean(step.output || step.diff || step.detail)
  return (
    <div className={`step step-${step.state}`}>
      <button className="step-head" disabled={!expandable} aria-expanded={open} onClick={() => setOpen(o => !o)}>
        <span className="step-caret">{expandable ? (open ? '▾' : '▸') : '·'}</span>
        <span className={`step-kind k-${step.kind}`}>{stepKindLabel[step.kind]}</span>
        <span className="step-title" title={step.title}>{step.title}</span>
        {exitLabel(step) && <span className={`step-exit${step.exitCode ? ' bad' : ''}`}>{exitLabel(step)}</span>}
        <span className="step-state">{stepStateLabel[step.state]}</span>
      </button>
      {open && (
        <div className="step-body">
          {step.detail && <div className="step-detail">{step.detail}</div>}
          {step.diff && <DiffText text={step.diff} />}
          {step.output && <pre className="step-output">{step.output}</pre>}
        </div>
      )}
    </div>
  )
}

/** Collapsible tool steps above a reply; open while the reply streams. */
export function StepList({ steps, streaming }: { steps: StepPayload[]; streaming: boolean }) {
  const [open, setOpen] = useState<boolean | null>(null)
  const shown = open ?? streaming
  return (
    <div className="steps">
      <button className="link steps-toggle" aria-expanded={shown} onClick={() => setOpen(!shown)}>{shown ? '▾' : '▸'} {stepsSummary(steps)}</button>
      {shown && steps.map(s => <Step key={s.id} step={s} />)}
    </div>
  )
}

/** "本回合改动": the turn's diff from Swift, one collapsible section per file. */
export function TurnChanges({ sessionID, messageID, stat, onClose }: { sessionID: string; messageID: string; stat: DiffStat; onClose(): void }) {
  const [diff, setDiff] = useState<string | null>(null)
  const [openFiles, setOpenFiles] = useState<Set<string>>(new Set())
  useEffect(() => {
    const id = crypto.randomUUID()
    const off = subscribe(p => { if (p.type === 'turn.diff' && p.id === id) setDiff(p.diff) })
    send({ type: 'turn.diff', id, sessionID, messageID })
    return off
  }, [sessionID, messageID])
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape' && !e.isComposing) { e.stopPropagation(); onClose() } }
    document.addEventListener('keydown', onKey, true)
    return () => document.removeEventListener('keydown', onKey, true)
  }, [onClose])
  const files = diff ? splitDiff(diff) : []
  const toggle = (path: string) => setOpenFiles(s => { const n = new Set(s); if (n.has(path)) n.delete(path); else n.add(path); return n })
  return (
    <div className="modal-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) onClose() }}>
      <div className="modal changes-modal" role="dialog" aria-modal="true" aria-label="本回合改动">
        <div className="changes-head">
          <span className="modal-title">本回合改动 · {diffLabel(stat)}</span>
          <button className="icon-btn" aria-label="关闭" onClick={onClose}>✕</button>
        </div>
        <div className="changes-list">
          {diff === null && <div className="muted">正在读取 diff…</div>}
          {diff !== null && files.length === 0 && <div className="muted">没有保存这一回合的 diff。</div>}
          {files.map(f => (
            <div key={f.path} className="changes-file">
              <button className="changes-file-head" aria-expanded={openFiles.has(f.path)} onClick={() => toggle(f.path)}>
                <span>{openFiles.has(f.path) ? '▾' : '▸'}</span>
                <span className="changes-path">{f.path}</span>
                <span className="dl-add">+{f.added}</span>
                <span className="dl-del">−{f.removed}</span>
              </button>
              {openFiles.has(f.path) && <DiffText text={f.body} />}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
