import { Extension } from '@tiptap/core'
import type { Node as PMNode } from '@tiptap/pm/model'
import { Plugin, PluginKey, type Transaction } from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import { post } from './bridge'

type SourcesState = { blockIds: ReadonlySet<string>; buttons: DecorationSet }

const sourcesKey = new PluginKey<SourcesState>('sources')

export function setSources(tr: Transaction, blockIds: readonly string[]): Transaction {
  return tr.setMeta(sourcesKey, new Set(blockIds))
}

export const Sources = Extension.create({
  name: 'sources',

  addProseMirrorPlugins() {
    return [
      new Plugin<SourcesState>({
        key: sourcesKey,
        state: {
          init: () => ({ blockIds: new Set(), buttons: DecorationSet.empty }),
          apply(tr, current) {
            const blockIds = tr.getMeta(sourcesKey) as ReadonlySet<string> | undefined
            if (!blockIds && !tr.docChanged) return current
            const next = blockIds ?? current.blockIds
            return { blockIds: next, buttons: sourceButtons(tr.doc, next) }
          },
        },
        props: { decorations: state => sourcesKey.getState(state)?.buttons },
      }),
    ]
  },
})

function sourceButtons(doc: PMNode, blockIds: ReadonlySet<string>): DecorationSet {
  if (blockIds.size === 0) return DecorationSet.empty
  const widgets: Decoration[] = []
  doc.descendants((node, pos) => {
    const blockId: unknown = node.attrs.blockId
    if (typeof blockId !== 'string' || !blockIds.has(blockId)) return
    // List items start with a paragraph, so their button sits at the end of that first line.
    const end = node.isTextblock ? pos + node.nodeSize - 1 : pos + node.child(0).nodeSize
    widgets.push(
      Decoration.widget(end, () => sourceButton(blockId), {
        side: 1,
        key: `source:${blockId}`,
        ignoreSelection: true,
        stopEvent: () => true,
      }),
    )
  })
  return DecorationSet.create(doc, widgets)
}

function sourceButton(blockId: string): HTMLButtonElement {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'source-button'
  button.contentEditable = 'false'
  button.setAttribute('aria-label', 'Show sources')
  button.append(magnifyingGlass())
  button.addEventListener('mousedown', event => event.preventDefault())
  button.addEventListener('click', event => {
    event.preventDefault()
    const { x, y, width, height } = button.getBoundingClientRect()
    post('sourceClicked', { blockId, rect: { x: x + window.scrollX, y: y + window.scrollY, width, height } })
  })
  return button
}

function magnifyingGlass(): SVGSVGElement {
  const svgNS = 'http://www.w3.org/2000/svg'
  const svg = document.createElementNS(svgNS, 'svg')
  svg.setAttribute('viewBox', '0 0 16 16')
  svg.setAttribute('aria-hidden', 'true')
  const lens = document.createElementNS(svgNS, 'circle')
  lens.setAttribute('cx', '6.75')
  lens.setAttribute('cy', '6.75')
  lens.setAttribute('r', '4.5')
  const handle = document.createElementNS(svgNS, 'path')
  handle.setAttribute('d', 'M10.25 10.25 14 14')
  svg.append(lens, handle)
  return svg
}
