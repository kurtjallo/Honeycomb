import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { ai, doc, mountEditor, p, text, typeText, type Mounted } from './helpers'

let ed: Mounted

beforeEach(() => {
  vi.useFakeTimers()
  ed = mountEditor()
})

afterEach(() => {
  ed.destroy()
  vi.useRealTimers()
})

const everything = doc(
  { type: 'heading', attrs: { blockId: 'h1', level: 2 }, content: [ai('Decisions')] },
  p(
    'p1',
    ai('We will ship '),
    text('Friday', 'bold', 'ai'),
    { type: 'hardBreak' },
    text('see ', 'italic'),
    { type: 'text', text: 'the doc', marks: [{ type: 'link', attrs: { href: 'https://example.com/a' } }, { type: 'ai' }] },
    text(' and ', 'ai'),
    text('npm test', 'code', 'ai'),
  ),
  {
    type: 'bulletList',
    content: [
      {
        type: 'listItem',
        attrs: { blockId: 'li1' },
        content: [
          p('li1p', ai('Budget')),
          { type: 'bulletList', content: [{ type: 'listItem', attrs: { blockId: 'li2' }, content: [p('li2p', text('nested'))] }] },
        ],
      },
    ],
  },
  { type: 'orderedList', attrs: { start: 3 }, content: [{ type: 'listItem', attrs: { blockId: 'li3' }, content: [p('li3p', ai('Third'))] }] },
  {
    type: 'taskList',
    content: [
      { type: 'taskItem', attrs: { blockId: 't1', checked: true }, content: [p('t1p', ai('Send notes'))] },
      { type: 'taskItem', attrs: { blockId: 't2', checked: false }, content: [p(null, text('Book room'))] },
    ],
  },
)

describe('handshake', () => {
  test('sends ready once with the schema and bundle versions', () => {
    expect(ed.sent('ready')).toEqual([{ v: 1, type: 'ready', payload: { schemaVersion: 1, bundleVersion: '1.0.0' } }])
  })
})

describe('load and getDoc', () => {
  test('a document with ai marks and block IDs round-trips unchanged', () => {
    expect(ed.send('load', { doc: everything, mode: 'edit' })).toEqual({ ok: true })
    expect(ed.getDoc()).toEqual(everything)
  })

  test('loading over a fully selected note keeps Swift’s empty blocks as they are', () => {
    const emptyHeading = doc({ type: 'heading', attrs: { blockId: 'h1', level: 1 } })
    for (const next of [doc(p('p1')), emptyHeading]) {
      ed.send('load', { doc: doc(p('a', text('Old note'))), mode: 'edit' })
      ed.editor.commands.setTextSelection({ from: 1, to: 1 + 'Old note'.length })
      ed.send('load', { doc: next, mode: 'edit' })
      expect(ed.getDoc()).toEqual(next)
    }
  })

  test('URLs in Swift text are not turned into links', () => {
    for (const withUrl of [doc(p('a', ai('Agenda at https://example.com '))), doc(p('a', ai('See https://example.org ')), p('b', text('Later')))]) {
      ed.send('load', { doc: withUrl, mode: 'edit' })
      expect(ed.getDoc()).toEqual(withUrl)
      ed.send('streamDone', { doc: withUrl })
      expect(ed.getDoc()).toEqual(withUrl)
    }
  })

  test('a null document loads as one empty paragraph and shows the placeholder', () => {
    ed.send('load', { doc: null, mode: 'edit', placeholder: 'Write notes' })
    expect(ed.getDoc()).toEqual(doc(p(null)))
    expect(ed.scroller.querySelector('p')?.dataset.placeholder).toBe('Write notes')
  })

  test('the mode decides whether the page is editable', () => {
    ed.send('load', { doc: everything, mode: 'readonly' })
    expect(ed.editor.isEditable).toBe(false)
    expect(ed.editor.view.dom.getAttribute('contenteditable')).toBe('false')
    ed.send('load', { doc: everything, mode: 'edit' })
    expect(ed.editor.isEditable).toBe(true)
  })
})

describe('streaming', () => {
  test('streamUpdate is read-only and keeps its marks', () => {
    ed.send('load', { doc: null, mode: 'edit' })
    expect(ed.send('streamUpdate', { doc: everything })).toEqual({ ok: true })
    expect(ed.editor.isEditable).toBe(false)
    expect(ed.getDoc()).toEqual(everything)
  })

  test('streamDone replaces the content and switches to edit mode', () => {
    ed.send('streamUpdate', { doc: doc(p('a', ai('Partial'))) })
    expect(ed.send('streamDone', { doc: everything })).toEqual({ ok: true })
    expect(ed.editor.isEditable).toBe(true)
    expect(ed.getDoc()).toEqual(everything)
  })
})

describe('docChanged', () => {
  test('Swift-driven messages never emit it', () => {
    ed.send('load', { doc: everything, mode: 'edit' })
    ed.send('streamUpdate', { doc: doc(p('a', ai('Partial'))) })
    ed.send('streamDone', { doc: everything })
    ed.send('setSources', { blockIds: ['p1'] })
    ed.send('setTheme', { appearance: 'dark', fontSize: 16, underlineAI: true })
    vi.advanceTimersByTime(5000)
    expect(ed.sent('docChanged')).toEqual([])
  })

  test('a user edit emits exactly one docChanged after 500 ms', () => {
    ed.send('load', { doc: doc(p('a', text('Hello'))), mode: 'edit' })
    typeText(ed.editor, '!', 6)
    vi.advanceTimersByTime(300)
    typeText(ed.editor, '?', 7)
    vi.advanceTimersByTime(499)
    expect(ed.sent('docChanged')).toEqual([])
    vi.advanceTimersByTime(1)
    expect(ed.sent('docChanged')).toEqual([{ v: 1, type: 'docChanged', payload: { loadId: 1, doc: doc(p('a', text('Hello!?'))) } }])
    vi.advanceTimersByTime(5000)
    expect(ed.sent('docChanged')).toHaveLength(1)
  })

  test('a load reports an unreported edit at once, tagged with the load it belongs to', () => {
    ed.send('load', { doc: doc(p('a', text('Hello'))), mode: 'edit', loadId: 7 })
    typeText(ed.editor, '!', 6)
    vi.advanceTimersByTime(300)
    ed.send('load', { doc: doc(p('b', text('Other note'))), mode: 'edit', loadId: 8 })
    expect(ed.sent('docChanged').map(m => m.payload)).toEqual([{ loadId: 7, doc: doc(p('a', text('Hello!'))) }])
    typeText(ed.editor, '?', 11)
    vi.advanceTimersByTime(5000)
    expect(ed.sent('docChanged').map(m => m.payload)).toEqual([
      { loadId: 7, doc: doc(p('a', text('Hello!'))) },
      { loadId: 8, doc: doc(p('b', text('Other note?'))) },
    ])
  })

  test('flush reports an unreported edit at once, and nothing when there is none', () => {
    ed.send('load', { doc: doc(p('a', text('Hello'))), mode: 'edit' })
    expect(ed.send('flush')).toEqual({ ok: true })
    expect(ed.sent('docChanged')).toEqual([])
    typeText(ed.editor, '!', 6)
    ed.send('flush')
    expect(ed.sent('docChanged').map(m => m.payload)).toEqual([{ loadId: 1, doc: doc(p('a', text('Hello!'))) }])
    vi.advanceTimersByTime(5000)
    expect(ed.sent('docChanged')).toHaveLength(1)
  })

  test('undo never brings back a document that Swift replaced', () => {
    ed.send('load', { doc: doc(p('a', text('Note A'))), mode: 'edit' })
    ed.editor.chain().selectAll().deleteSelection().run()
    ed.send('load', { doc: doc(p('b', text('Note B'))), mode: 'edit' })
    expect(ed.editor.commands.undo()).toBe(false)
    ed.send('streamUpdate', { doc: doc(p('c', ai('Streaming'))) })
    ed.send('streamDone', { doc: doc(p('c', ai('Final notes'))) })
    expect(ed.editor.commands.undo()).toBe(false)
    expect(ed.getDoc()).toEqual(doc(p('c', ai('Final notes'))))
    vi.advanceTimersByTime(5000)
    expect(ed.sent('docChanged').map(m => m.payload)).toEqual([{ loadId: 1, doc: doc(p(null)) }])
  })

  test('undo still works for edits made after a load', () => {
    ed.send('load', { doc: doc(p('a', text('Hello'))), mode: 'edit' })
    typeText(ed.editor, '!', 6)
    expect(ed.editor.commands.undo()).toBe(true)
    expect(ed.getDoc()).toEqual(doc(p('a', text('Hello'))))
  })

  test('undo counts as a user edit', () => {
    ed.send('load', { doc: doc(p('a', text('Hello'))), mode: 'edit' })
    typeText(ed.editor, '!', 6)
    vi.advanceTimersByTime(500)
    ed.editor.commands.undo()
    vi.advanceTimersByTime(500)
    expect(ed.sent('docChanged').map(m => m.payload.doc)).toEqual([doc(p('a', text('Hello!'))), doc(p('a', text('Hello')))])
  })
})

describe('envelopes', () => {
  const rejected: Array<[string, unknown, string]> = [
    ['not an object', 'load', 'badEnvelope'],
    ['version 2', { v: 2, type: 'load', payload: { loadId: 1, doc: null, mode: 'edit' } }, 'badVersion'],
    ['missing version', { type: 'load', payload: { loadId: 1, doc: null, mode: 'edit' } }, 'badVersion'],
    ['unknown type', { v: 1, type: 'deleteEverything', payload: {} }, 'unknownType'],
    ['inherited key as type', { v: 1, type: 'toString', payload: {} }, 'unknownType'],
    ['outbound type', { v: 1, type: 'docChanged', payload: { doc: everything } }, 'unknownType'],
    ['payload not an object', { v: 1, type: 'getDoc', payload: [] }, 'badPayload'],
    ['bad mode', { v: 1, type: 'load', payload: { loadId: 1, doc: null, mode: 'write' } }, 'badPayload'],
    ['missing load ID', { v: 1, type: 'load', payload: { doc: null, mode: 'edit' } }, 'badPayload'],
    ['fractional load ID', { v: 1, type: 'load', payload: { loadId: 1.5, doc: null, mode: 'edit' } }, 'badPayload'],
    ['missing doc', { v: 1, type: 'load', payload: { loadId: 1, mode: 'edit' } }, 'badPayload'],
    ['unknown node', { v: 1, type: 'load', payload: { loadId: 1, doc: doc({ type: 'image', attrs: { src: 'x' } }), mode: 'edit' } }, 'badPayload'],
    ['unknown mark', { v: 1, type: 'streamUpdate', payload: { doc: doc(p('a', text('x', 'strike'))) } }, 'badPayload'],
    ['invalid nesting', { v: 1, type: 'streamDone', payload: { doc: doc(text('loose')) } }, 'badPayload'],
    ['empty doc', { v: 1, type: 'load', payload: { loadId: 1, doc: { type: 'doc', content: [] }, mode: 'edit' } }, 'badPayload'],
    ['heading level 6', { v: 1, type: 'load', payload: { loadId: 1, doc: doc({ type: 'heading', attrs: { level: 6 }, content: [text('x')] }), mode: 'edit' } }, 'badPayload'],
    ['heading level as text', { v: 1, type: 'load', payload: { loadId: 1, doc: doc({ type: 'heading', attrs: { level: '2' }, content: [text('x')] }), mode: 'edit' } }, 'badPayload'],
    ['list start as text', { v: 1, type: 'load', payload: { loadId: 1, doc: doc({ type: 'orderedList', attrs: { start: 'abc' }, content: [{ type: 'listItem', content: [p('x')] }] }), mode: 'edit' } }, 'badPayload'],
    ['checked as text', { v: 1, type: 'load', payload: { loadId: 1, doc: doc({ type: 'taskList', content: [{ type: 'taskItem', attrs: { checked: 'false' }, content: [p('x')] }] }), mode: 'edit' } }, 'badPayload'],
    ['numeric block ID', { v: 1, type: 'load', payload: { loadId: 1, doc: doc(p(7 as unknown as string, text('x'))), mode: 'edit' } }, 'badPayload'],
    ['placeholder not a string', { v: 1, type: 'load', payload: { loadId: 1, doc: null, mode: 'edit', placeholder: 3 } }, 'badPayload'],
    ['bad appearance', { v: 1, type: 'setTheme', payload: { appearance: 'blue', fontSize: 15, underlineAI: false } }, 'badPayload'],
    ['bad font size', { v: 1, type: 'setTheme', payload: { appearance: 'dark', fontSize: '15', underlineAI: false } }, 'badPayload'],
    ['infinite font size', { v: 1, type: 'setTheme', payload: { appearance: 'dark', fontSize: Infinity, underlineAI: false } }, 'badPayload'],
    ['bad source IDs', { v: 1, type: 'setSources', payload: { blockIds: ['p1', 2] } }, 'badPayload'],
  ]

  test.each(rejected)('%s is rejected and changes nothing', (_name, envelope, error) => {
    ed.send('load', { doc: everything, mode: 'edit' })
    ed.send('setSources', { blockIds: ['p1'] })
    const root = document.documentElement
    const themeBefore = [root.dataset.theme, root.dataset.underlineAi, root.style.getPropertyValue('--font-size')]

    expect(window.honeycomb?.receive(envelope)).toEqual({ ok: false, error })

    expect(ed.getDoc()).toEqual(everything)
    expect(ed.editor.isEditable).toBe(true)
    expect([root.dataset.theme, root.dataset.underlineAi, root.style.getPropertyValue('--font-size')]).toEqual(themeBefore)
    expect(ed.scroller.querySelectorAll('.source-button')).toHaveLength(1)
  })
})

describe('setTheme', () => {
  test('sets the appearance, font size, and AI underline', () => {
    expect(ed.send('setTheme', { appearance: 'dark', fontSize: 17, underlineAI: true })).toEqual({ ok: true })
    const root = document.documentElement
    expect(root.dataset.theme).toBe('dark')
    expect(root.dataset.underlineAi).toBe('true')
    expect(root.style.getPropertyValue('--font-size')).toBe('17px')
  })
})
