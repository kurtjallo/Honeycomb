import { afterEach, beforeEach, expect, test } from 'vitest'
import { ai, aiRuns, doc, mountEditor, pasteHTML, p, text, typeKeys, typeText, type Mounted } from './helpers'

let ed: Mounted

beforeEach(() => {
  ed = mountEditor()
  ed.send('load', { doc: doc(p('a', ai('Discuss the budget')), p('b', ai('Ship it'))), mode: 'edit' })
})

afterEach(() => ed.destroy())

const firstBlock = () => aiRuns(ed.editor.state.doc.child(0))

// Positions count from the start of the first paragraph's text, which is position 1.
const at = (offset: number) => 1 + offset

test('typing inside an AI word removes the mark from the typed text and the whole word', () => {
  typeText(ed.editor, 'X', at('Discuss the bud'.length))
  expect(firstBlock()).toBe('[Discuss the ]budXget')
})

test('typing a space inside an AI word removes the mark from both halves', () => {
  typeText(ed.editor, ' ', at('Discuss the bud'.length))
  expect(firstBlock()).toBe('[Discuss the ]bud get')
})

test('typing after the end of AI text gives unmarked text and keeps the AI text', () => {
  typeText(ed.editor, ' now', at('Discuss the budget'.length))
  expect(firstBlock()).toBe('[Discuss the budget] now')
})

test('typing before the start of AI text gives unmarked text and keeps the AI text', () => {
  typeText(ed.editor, 'Please ', at(0))
  expect(firstBlock()).toBe('Please [Discuss the budget]')
})

test('typing between AI words gives unmarked text and keeps both words', () => {
  typeText(ed.editor, 'whole ', at('Discuss the '.length))
  expect(firstBlock()).toBe('[Discuss the ]whole [budget]')
})

test('typing a letter onto the end of an AI word leaves the word as AI text', () => {
  typeText(ed.editor, 's', at('Discuss the budget'.length))
  expect(firstBlock()).toBe('[Discuss the budget]s')
})

test('typing key by key before AI text never strips the AI word it touches', () => {
  typeKeys(ed.editor, 'Please ', at(0))
  expect(firstBlock()).toBe('Please [Discuss the budget]')
})

test('typing key by key between AI words never strips either word', () => {
  typeKeys(ed.editor, 'whole ', at('Discuss the '.length))
  expect(firstBlock()).toBe('[Discuss the ]whole [budget]')
})

test('typing key by key inside an AI word strips that word only', () => {
  typeKeys(ed.editor, 'XY', at('Discuss the bud'.length))
  expect(firstBlock()).toBe('[Discuss the ]budXYget')
})

test('words without spaces between them, as in Japanese, are found by the word segmenter', () => {
  ed.send('load', { doc: doc(p('a', ai('会議の予算を確認する'))), mode: 'edit' })
  typeText(ed.editor, 'X', at('会議の予'.length))
  expect(firstBlock()).toBe('[会議の]予X算[を確認する]')
})

test('replacing a selection inside AI text removes the mark from the new text and its word', () => {
  typeText(ed.editor, 'ou', at('Discuss the b'.length), at('Discuss the bud'.length))
  expect(firstBlock()).toBe('[Discuss the ]bouget')
})

test('deleting inside an AI word removes the mark from what is left of that word', () => {
  const from = at('Discuss the bud'.length)
  ed.editor.view.dispatch(ed.editor.state.tr.delete(from, from + 1))
  expect(firstBlock()).toBe('[Discuss the ]budet')
})

test('deleting a whole AI word with its space leaves the neighbors as AI text', () => {
  const from = at('Discuss '.length)
  ed.editor.view.dispatch(ed.editor.state.tr.delete(from, from + 'the '.length))
  expect(firstBlock()).toBe('[Discuss budget]')
})

test('pasted text is never AI text, even when copied from AI text', () => {
  ed.editor.commands.setTextSelection({ from: at('Discuss '.length), to: at('Discuss the'.length) })
  pasteHTML(ed.editor, '<span class="ai" data-author="ai">our</span>')
  expect(firstBlock()).toBe('[Discuss ]our[ budget]')
})

test('making AI text bold keeps it AI text', () => {
  ed.editor.chain().setTextSelection({ from: at(0), to: at('Discuss'.length) }).toggleBold().run()
  expect(firstBlock()).toBe('[Discuss][ the budget]')
  expect(ed.editor.state.doc.child(0).child(0).marks.map(mark => mark.type.name)).toEqual(['bold', 'ai'])
})

test('undo brings the AI mark back', () => {
  typeText(ed.editor, 'X', at('Discuss the bud'.length))
  ed.editor.commands.undo()
  expect(firstBlock()).toBe('[Discuss the budget]')
})

test('edits in one block leave AI text in other blocks alone', () => {
  typeText(ed.editor, 'X', at('Discuss the bud'.length))
  expect(aiRuns(ed.editor.state.doc.child(1))).toBe('[Ship it]')
})

test('a stream update after user edits keeps Swift’s marks exactly', () => {
  typeText(ed.editor, 'X', at('Discuss the bud'.length))
  const streamed = doc(p('a', ai('Discuss the '), text('budXget'), ai(' today')))
  ed.send('streamUpdate', { doc: streamed })
  expect(ed.getDoc()).toEqual(streamed)
})
