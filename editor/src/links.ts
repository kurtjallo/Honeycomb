import { Link } from '@tiptap/extension-link'
import type { MarkType } from '@tiptap/pm/model'
import { Plugin, PluginKey } from '@tiptap/pm/state'
import { post } from './bridge'

const allowedProtocols = new Set(['http:', 'https:', 'mailto:'])

function isAllowedHref(href: unknown): href is string {
  if (typeof href !== 'string') return false
  try {
    return allowedProtocols.has(new URL(href).protocol)
  } catch {
    return false
  }
}

export const SafeLink = Link.extend({
  addAttributes() {
    return {
      href: { default: null, parseHTML: element => element.getAttribute('href') },
    }
  },

  addProseMirrorPlugins() {
    return [...(this.parent?.() ?? []), removeUnsafeLinks(this.type), reportLinkClicks()]
  },
}).configure({ openOnClick: false, isAllowedUri: isAllowedHref })

// Covers Swift documents and autolinked text, neither of which passes through the paste filter.
function removeUnsafeLinks(link: MarkType): Plugin {
  return new Plugin({
    key: new PluginKey('removeUnsafeLinks'),
    appendTransaction(transactions, _oldState, state) {
      if (!transactions.some(tr => tr.docChanged)) return null
      const tr = state.tr
      state.doc.descendants((node, pos) => {
        for (const mark of node.marks) {
          if (mark.type === link && !isAllowedHref(mark.attrs.href)) tr.removeMark(pos, pos + node.nodeSize, mark)
        }
      })
      // Otherwise autolink sees this step and links the removed link's text again when it looks like a URL.
      return tr.steps.length > 0 ? tr.setMeta('preventAutolink', true) : null
    },
  })
}

function reportLinkClicks(): Plugin {
  const handle = (event: MouseEvent): boolean => {
    const anchor = event.target instanceof Element ? event.target.closest('a') : null
    if (!anchor) return false
    event.preventDefault()
    const href = anchor.getAttribute('href')
    if (event.type === 'click' && isAllowedHref(href)) post('linkClicked', { href })
    return true
  }
  return new Plugin({
    key: new PluginKey('reportLinkClicks'),
    props: { handleDOMEvents: { click: (_view, event) => handle(event), auxclick: (_view, event) => handle(event) } },
  })
}
