import type { Provider } from './types'

export const providers: Provider[] = ['claude', 'codex', 'grok', 'gemini']

/** The harness that runs the node (design/HARNESS.md H0), not the chat product. */
export const providerName: Record<Provider, string> = {
  claude: 'Claude Code', codex: 'Codex', grok: 'Cursor · Grok', gemini: 'Cursor · Gemini',
}

/** The subscription the official CLI signs in with. */
export const providerAccount: Record<Provider, string> = {
  claude: 'Claude 订阅', codex: 'ChatGPT 账号', grok: 'Cursor 订阅', gemini: 'Cursor 订阅',
}

/** e.g. "Codex · ChatGPT 账号". */
export const providerSubtitle = (p: Provider) => `${providerName[p]} · ${providerAccount[p]}`

/** Main colour per provider; head tints live in styles.css (--p-<id>-tint). */
export const providerColor: Record<Provider, string> = {
  claude: '#C96442', codex: '#10A37F', grok: '#3B3B3B', gemini: '#4B6BEA',
}

// The bundled marks; ChatGPT and Grok ship separate light and dark files.
const hasDarkVariant: Record<Provider, boolean> = { claude: false, codex: true, grok: true, gemini: false }

export function ProviderMark({ provider, size = 16 }: { provider: Provider; size?: number }) {
  return (
    <picture className="provider-mark" style={{ width: size, height: size }}>
      {hasDarkVariant[provider] && <source srcSet={`icons/${provider}-dark.svg`} media="(prefers-color-scheme: dark)" />}
      <img src={`icons/${provider}.svg`} width={size} height={size} alt={providerName[provider]} draggable={false} />
    </picture>
  )
}
