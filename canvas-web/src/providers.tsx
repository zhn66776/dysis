import type { Provider } from './types'

export const providers: Provider[] = ['claude', 'codex', 'grok', 'gemini']

export const providerName: Record<Provider, string> = {
  claude: 'Claude', codex: 'ChatGPT', grok: 'Grok', gemini: 'Gemini',
}

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
