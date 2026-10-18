import { combineTransactionSteps, Mark } from '@tiptap/core'
import type { MarkType, Node as PMNode } from '@tiptap/pm/model'
import { Plugin, PluginKey } from '@tiptap/pm/state'
import type { Transform } from '@tiptap/pm/transform'
import { originOf } from './origin'

export const Ai = Mark.create({
  name: 'ai',
  inclusive: false,
  renderHTML: () => ['span', { class: 'ai', 'data-author': 'ai' }, 0],
  addProseMirrorPlugins() {
    return [userTextIsNeverAi(this.type)]
  },
})

function userTextIsNeverAi(ai: MarkType): Plugin {
  return new Plugin({
    key: new PluginKey('userTextIsNeverAi'),
    appendTransaction(transactions, oldState, newState) {
      const first = transactions[0]
      if (!first || originOf(first) !== 'user' || !transactions.some(tr => tr.docChanged)) return null
      const tr = newState.tr
      for (const { from, to } of editedRanges(combineTransactionSteps(oldState.doc, [...transactions]), ai)) {
        tr.removeMark(from, to, ai)
      }
      return tr.steps.length > 0 ? tr : null
    },
  })
}

type Range = { from: number; to: number }

// Each edit covers what it inserted, plus the whole AI word it cut into, if any.
// Typing next to an AI word leaves that word alone, even while the typed letters touch it.
function editedRanges(transform: Transform, ai: MarkType): Range[] {
  const ranges: Range[] = []
  transform.steps.forEach((step, index) => {
    const before = transform.docs[index]
    const stepMap = step.getMap()
    const later = transform.mapping.slice(index + 1)
    stepMap.forEach((oldStart, oldEnd, newStart, newEnd) => {
      const left = aiWordCutAt(before, oldStart, ai)
      const right = aiWordCutAt(before, oldEnd, ai)
      const from = later.map(left ? stepMap.map(left.from, -1) : newStart)
      const to = later.map(right ? stepMap.map(right.to, 1) : newEnd)
      if (from < to) ranges.push({ from, to })
    })
  })
  return ranges
}

const words = new Intl.Segmenter(undefined, { granularity: 'word' })

function aiWordCutAt(doc: PMNode, pos: number, ai: MarkType): Range | undefined {
  const $pos = doc.resolve(pos)
  const { parent, parentOffset: offset, nodeBefore, nodeAfter } = $pos
  if (!parent.inlineContent || !nodeBefore || !nodeAfter) return undefined
  if (!ai.isInSet(nodeBefore.marks) || !ai.isInSet(nodeAfter.marks)) return undefined
  const text = parent.textBetween(0, parent.content.size, undefined, '\n')
  const word = words.segment(text).containing(offset - 1)
  if (!word?.isWordLike || word.index + word.segment.length <= offset) return undefined
  return { from: $pos.start() + word.index, to: $pos.start() + word.index + word.segment.length }
}
