import { afterEach, beforeEach, expect, test } from 'vitest'
import { blockIds, doc, mountEditor, pasteHTML, p, text, typeText, type Mounted } from './helpers'

let ed: Mounted

beforeEach(() => {
  ed = mountEditor()
})

afterEach(() => ed.destroy())

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

function expectUnique(ids: Array<string | null>) {
  const present = ids.filter(id => id !== null)
  expect(new Set(present).size).toBe(present.length)
}

test('splitting a block keeps its ID in the first half and gives the second half a new one', () => {
  ed.send('load', { doc: doc(p('p1', text('Hello world'))), mode: 'edit' })
  ed.editor.chain().setTextSelection(1 + 'Hello'.length).splitBlock().run()
  const [first, second] = blockIds(ed.editor)
  expect(first).toBe('p1')
  expect(second).toMatch(uuid)
  expect(ed.editor.state.doc.child(1).textContent).toBe(' world')
})

test('splitting at the start of a block still keeps the ID in the first half', () => {
  ed.send('load', { doc: doc(p('p1', text('Hello'))), mode: 'edit' })
  ed.editor.chain().setTextSelection(1).splitBlock().run()
  const [first, second] = blockIds(ed.editor)
  expect(first).toBe('p1')
  expect(second).toMatch(uuid)
})

test('Enter in a list item gives the new item and its paragraph new IDs', () => {
  const list = doc({
    type: 'bulletList',
    content: [{ type: 'listItem', attrs: { blockId: 'li1' }, content: [p('li1p', text('First item'))] }],
  })
  ed.send('load', { doc: list, mode: 'edit' })
  ed.editor.chain().setTextSelection(3 + 'First'.length).splitListItem('listItem').run()
  const ids = blockIds(ed.editor)
  expect(ids.slice(0, 2)).toEqual(['li1', 'li1p'])
  expect(ids).toHaveLength(4)
  ids.slice(2).forEach(id => expect(id).toMatch(uuid))
  expectUnique(ids)
})

test('new blocks the user creates get IDs', () => {
  ed.send('load', { doc: doc(p('p1', text('Hello'))), mode: 'edit' })
  ed.editor.chain().setTextSelection(6).splitBlock().run()
  typeText(ed.editor, '- ', ed.editor.state.selection.from)
  const ids = blockIds(ed.editor)
  expect(ed.editor.state.doc.child(1).type.name).toBe('bulletList')
  expect(ids[0]).toBe('p1')
  ids.slice(1).forEach(id => expect(id).toMatch(uuid))
  expectUnique(ids)
})

test('pasted blocks get new IDs and the originals keep theirs', () => {
  ed.send('load', { doc: doc(p('p1', text('Original')), p('p2', text('Second'))), mode: 'edit' })
  ed.editor.commands.setTextSelection(1 + 'Original'.length)
  pasteHTML(ed.editor, '<p data-block-id="p1">Copy one</p><p data-block-id="p2">Copy two</p>')
  const blocks = ed.getDoc().content?.map(block => [block.attrs?.blockId, block.content?.[0]?.text])
  expect(blocks?.[0]).toEqual(['p1', 'OriginalCopy one'])
  expect(blocks?.[1]?.[0]).toMatch(uuid)
  expect(blocks?.[1]?.[1]).toBe('Copy two')
  expect(blocks?.[2]).toEqual(['p2', 'Second'])
})

test('duplicating a block node keeps the original ID and gives the copy a new one', () => {
  ed.send('load', { doc: doc(p('p1', text('Original'))), mode: 'edit' })
  const original = ed.editor.state.doc.child(0)
  ed.editor.view.dispatch(ed.editor.state.tr.insert(ed.editor.state.doc.content.size, original))
  const [first, second] = blockIds(ed.editor)
  expect(first).toBe('p1')
  expect(second).toMatch(uuid)
})

test('a block pasted from another note gets a fresh ID instead of that note’s ID', () => {
  ed.send('load', { doc: doc(p('p1', text('Here'))), mode: 'edit' })
  ed.editor.commands.setTextSelection(1 + 'Here'.length)
  pasteHTML(ed.editor, '<p>x</p><p data-block-id="from-other-note">Pasted</p>')
  const ids = blockIds(ed.editor)
  expect(ids).not.toContain('from-other-note')
  expect(ids[1]).toMatch(uuid)
})

test('a copy placed above the original gets the new ID and the original keeps its own', () => {
  ed.send('load', { doc: doc(p('p1', text('Original'))), mode: 'edit' })
  const original = ed.editor.state.doc.child(0)
  ed.editor.view.dispatch(ed.editor.state.tr.insert(0, original.copy(original.content.cut(0, 4))))
  const blocks = ed.getDoc().content?.map(block => [block.attrs?.blockId, block.content?.[0]?.text])
  expect(blocks?.[0]?.[0]).toMatch(uuid)
  expect(blocks?.[0]?.[1]).toBe('Orig')
  expect(blocks?.[1]).toEqual(['p1', 'Original'])
})

test('duplicate IDs from Swift are fixed on load, and the first one keeps its ID', () => {
  ed.send('load', { doc: doc(p('p1', text('One')), p('p1', text('Two')), p(null, text('Three'))), mode: 'edit' })
  const [first, second, third] = blockIds(ed.editor)
  expect(first).toBe('p1')
  expect(second).toMatch(uuid)
  expect(third).toBeNull()
})

test('the first user edit gives every block without an ID a new one', () => {
  ed.send('load', { doc: doc(p(null, text('One')), p(null, text('Two'))), mode: 'edit' })
  typeText(ed.editor, '!', 4)
  const ids = blockIds(ed.editor)
  ids.forEach(id => expect(id).toMatch(uuid))
  expectUnique(ids)
})

test('block IDs render as data-block-id', () => {
  ed.send('load', { doc: doc(p('p1', text('One'))), mode: 'edit' })
  expect(ed.scroller.querySelector('p')?.getAttribute('data-block-id')).toBe('p1')
})
