import { combineTransactionSteps, Extension } from '@tiptap/core'
import type { Node as PMNode } from '@tiptap/pm/model'
import { Plugin, PluginKey } from '@tiptap/pm/state'
import type { Mapping } from '@tiptap/pm/transform'
import { originOf } from './origin'

const blockTypes = ['paragraph', 'heading', 'listItem', 'taskItem']

export const BlockIds = Extension.create({
  name: 'blockIds',

  addGlobalAttributes() {
    return [
      {
        types: blockTypes,
        attributes: {
          blockId: {
            default: null,
            validate: 'string|null',
            keepOnSplit: false,
            // Pasted blocks are new blocks, so they never bring an ID along.
            parseHTML: () => null,
            renderHTML: ({ blockId }) => (blockId ? { 'data-block-id': blockId } : {}),
          },
        },
      },
    ]
  },

  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: new PluginKey('blockIds'),
        appendTransaction(transactions, oldState, state) {
          const first = transactions[0]
          if (!first || !transactions.some(tr => tr.docChanged)) return null
          // Swift's own blocks keep a null ID. Only duplicates are fixed for them.
          const fillMissing = originOf(first) !== 'swift'
          const owners = existingOwners(oldState.doc, state.doc, combineTransactionSteps(oldState.doc, [...transactions]).mapping)
          const seen = new Set<string>()
          const tr = state.tr
          state.doc.descendants((node, pos) => {
            if (!blockTypes.includes(node.type.name)) return
            const id: unknown = node.attrs.blockId
            if (typeof id === 'string') {
              const owner = owners.get(id)
              const keeps = owner === undefined ? !seen.has(id) : owner === pos
              seen.add(id)
              if (keeps) return
            } else if (!fillMissing) {
              return
            }
            tr.setNodeAttribute(pos, 'blockId', newBlockId())
          })
          return tr.steps.length > 0 ? tr : null
        },
      }),
    ]
  },
})

// Where each ID's block from before the change now sits, so a copy placed above it gets the new ID instead.
function existingOwners(oldDoc: PMNode, newDoc: PMNode, mapping: Mapping): Map<string, number> {
  const owners = new Map<string, number>()
  oldDoc.descendants((node, pos) => {
    const id: unknown = node.attrs.blockId
    if (typeof id !== 'string' || owners.has(id)) return
    const now = mapping.map(pos, 1)
    if (newDoc.nodeAt(now)?.attrs.blockId === id) owners.set(id, now)
  })
  return owners
}

// crypto.randomUUID needs a secure context, which a custom URL scheme may not be.
function newBlockId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16))
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}
