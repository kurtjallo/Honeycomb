import type { Editor, JSONContent } from '@tiptap/core'
import type { Node as PMNode } from '@tiptap/pm/model'
import { vi } from 'vitest'
import { start } from '../src/app'

export type Sent = { v: number; type: string; payload: Record<string, unknown> }

export type Mounted = ReturnType<typeof mountEditor>

export function mountEditor() {
  const postMessage = vi.fn()
  window.webkit = { messageHandlers: { bridge: { postMessage } } }
  const scroller = document.createElement('div')
  document.body.append(scroller)
  const editor = start(scroller)
  const { honeycomb } = window
  if (!honeycomb) throw new Error('start() did not install window.honeycomb')
  let loads = 0
  return {
    editor,
    scroller,
    // Swift numbers every load, so this does too unless the test passes its own loadId.
    send: (type: string, payload: object = {}) =>
      honeycomb.receive({ v: 1, type, payload: type === 'load' ? { loadId: ++loads, ...payload } : payload }),
    sent: (type: string): Sent[] => postMessage.mock.calls.map(([message]) => message as Sent).filter(m => m.type === type),
    getDoc: () => {
      const reply = honeycomb.receive({ v: 1, type: 'getDoc', payload: {} })
      if (!reply.ok || !reply.doc) throw new Error('getDoc failed')
      return reply.doc
    },
    destroy: () => {
      editor.destroy()
      scroller.remove()
      delete window.honeycomb
      delete window.webkit
    },
  }
}

export const doc = (...content: JSONContent[]): JSONContent => ({ type: 'doc', content })

export const p = (blockId: string | null, ...content: JSONContent[]): JSONContent =>
  content.length > 0 ? { type: 'paragraph', attrs: { blockId }, content } : { type: 'paragraph', attrs: { blockId } }

export const text = (value: string, ...marks: string[]): JSONContent =>
  marks.length > 0 ? { type: 'text', text: value, marks: marks.map(type => ({ type })) } : { type: 'text', text: value }

export const ai = (value: string): JSONContent => text(value, 'ai')

// Types the way ProseMirror does for a keystroke, so input rules and inherited marks apply.
export function typeText(editor: Editor, value: string, from: number, to = from): void {
  const { view } = editor
  const deflt = () => view.state.tr.insertText(value, from, to)
  if (!view.someProp('handleTextInput', handle => handle(view, from, to, value, deflt))) view.dispatch(deflt())
}

export function typeKeys(editor: Editor, value: string, from: number): void {
  Array.from(value).forEach((char, index) => typeText(editor, char, from + index))
}

// Shows a block's text with AI runs in brackets, for example "[Discuss the ]budXget".
export function aiRuns(block: PMNode): string {
  let out = ''
  block.forEach(child => {
    const value = child.text ?? '\n'
    out += child.marks.some(mark => mark.type.name === 'ai') ? `[${value}]` : value
  })
  return out
}

export function blockIds(editor: Editor): Array<string | null> {
  const ids: Array<string | null> = []
  editor.state.doc.descendants(node => {
    if ('blockId' in node.attrs) ids.push(node.attrs.blockId as string | null)
  })
  return ids
}

// jsdom has no ClipboardEvent, which pasteHTML would otherwise construct.
export function pasteHTML(editor: Editor, html: string): void {
  editor.view.pasteHTML(html, new Event('paste') as ClipboardEvent)
}
