import { afterEach, beforeEach, expect, test } from 'vitest'
import { ai, doc, mountEditor, p, type Mounted } from './helpers'

let ed: Mounted

const note = doc(
  p('p1', ai('First')),
  p('p2', ai('Second')),
  {
    type: 'taskList',
    content: [{ type: 'taskItem', attrs: { blockId: 't1', checked: false }, content: [p('t1p', ai('Follow up'))] }],
  },
)

beforeEach(() => {
  ed = mountEditor()
  ed.send('load', { doc: note, mode: 'edit' })
})

afterEach(() => ed.destroy())

const buttonOwners = () =>
  Array.from(ed.scroller.querySelectorAll('.source-button'), button => button.closest('[data-block-id]')?.getAttribute('data-block-id'))

test('setSources shows a button only on the listed blocks', () => {
  expect(ed.send('setSources', { blockIds: ['p2'] })).toEqual({ ok: true })
  expect(buttonOwners()).toEqual(['p2'])
})

test('a list item’s button sits at the end of its first line', () => {
  ed.send('setSources', { blockIds: ['t1'] })
  expect(buttonOwners()).toEqual(['t1p'])
  expect(ed.scroller.querySelector('.source-button')?.closest('li')?.getAttribute('data-block-id')).toBe('t1')
})

test('clicking the button posts sourceClicked with that block ID and the button’s rect', () => {
  ed.send('setSources', { blockIds: ['p1', 'p2'] })
  const button = ed.scroller.querySelector('[data-block-id="p2"] .source-button')
  button?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }))
  expect(ed.sent('sourceClicked').map(m => m.payload)).toEqual([{ blockId: 'p2', rect: { x: 0, y: 0, width: 0, height: 0 } }])
})

test('an empty list removes every button, and unknown IDs show none', () => {
  ed.send('setSources', { blockIds: ['p1', 'p2'] })
  ed.send('setSources', { blockIds: [] })
  expect(buttonOwners()).toEqual([])
  ed.send('setSources', { blockIds: ['missing'] })
  expect(buttonOwners()).toEqual([])
})

test('sources stay on their blocks while content streams in', () => {
  ed.send('setSources', { blockIds: ['p2'] })
  ed.send('streamUpdate', { doc: doc(p('p1', ai('First')), p('p2', ai('Second, longer'))) })
  expect(buttonOwners()).toEqual(['p2'])
})

test('the button is not part of the document', () => {
  ed.send('setSources', { blockIds: ['p1'] })
  expect(ed.getDoc()).toEqual(note)
  expect(ed.editor.state.doc.child(0).textContent).toBe('First')
})
