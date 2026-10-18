import { Editor } from '@tiptap/core'
import type { Node as PMNode } from '@tiptap/pm/model'
import { version } from '../package.json'
import { listen, post, type Handlers } from './bridge'
import { fromSwift, originOf } from './origin'
import { extensions } from './schema'
import { setSources } from './sources'

const docChangedDelayMs = 500

export function start(scroller: HTMLElement): Editor {
  let placeholder = ''
  const editor = new Editor({
    element: scroller,
    extensions: extensions(() => placeholder),
    injectCSS: false,
    editable: false,
    editorProps: { attributes: { 'aria-label': 'Notes' } },
  })

  let pendingDocChanged: ReturnType<typeof setTimeout> | undefined
  editor.on('update', ({ transaction }) => {
    if (originOf(transaction) === 'swift') return
    clearTimeout(pendingDocChanged)
    pendingDocChanged = setTimeout(() => post('docChanged', { doc: editor.getJSON() }), docChangedDelayMs)
  })

  const replaceDoc = (doc: PMNode) => {
    // An edit still waiting to be reported belongs to the document being replaced.
    clearTimeout(pendingDocChanged)
    const { tr } = editor.state
    editor.view.dispatch(fromSwift(tr.replaceWith(0, tr.doc.content.size, doc.content)))
    // Undo must never bring back the replaced document. prosemirror-history has no reset,
    // so the plugin is removed and added back, which starts it empty and keeps every other plugin's state.
    const { plugins } = editor.state
    editor.unregisterPlugin('history')
    editor.view.updateState(editor.state.reconfigure({ plugins }))
  }

  const handlers: Handlers = {
    load: ({ doc, mode, placeholder: text }) => {
      placeholder = text
      editor.setEditable(mode === 'edit', false)
      replaceDoc(doc)
      return { ok: true }
    },
    streamUpdate: ({ doc }) => {
      const atBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight <= 1
      editor.setEditable(false, false)
      replaceDoc(doc)
      if (atBottom) scroller.scrollTop = scroller.scrollHeight
      return { ok: true }
    },
    streamDone: ({ doc }) => {
      replaceDoc(doc)
      editor.setEditable(true, false)
      return { ok: true }
    },
    setTheme: ({ appearance, fontSize, underlineAI }) => {
      const root = scroller.ownerDocument.documentElement
      root.dataset.theme = appearance
      root.dataset.underlineAi = String(underlineAI)
      root.style.setProperty('--font-size', `${fontSize}px`)
      return { ok: true }
    },
    setSources: ({ blockIds }) => {
      editor.view.dispatch(setSources(editor.state.tr, blockIds))
      return { ok: true }
    },
    getDoc: () => ({ ok: true, doc: editor.getJSON() }),
    focus: () => {
      editor.commands.focus('end')
      return { ok: true }
    },
  }

  listen(editor.schema, handlers)
  post('ready', { schemaVersion: 1, bundleVersion: version })
  return editor
}
