import Markdown from 'react-markdown'
import remarkGfm from 'remark-gfm'

export function Reply({ text }: { text: string }) {
  return <div className="reply"><Markdown remarkPlugins={[remarkGfm]} components={{ a: ({ href, children }) => <a href={href} target="_blank" rel="noreferrer">{children}</a> }}>{text}</Markdown></div>
}
