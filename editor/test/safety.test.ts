import type { JSONContent } from '@tiptap/core'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import { doc, mountEditor, pasteHTML, p, text, type Mounted } from './helpers'

let ed: Mounted

beforeEach(() => {
  ed = mountEditor()
})

afterEach(() => ed.destroy())

const link = (value: string, href: string): JSONContent => ({ type: 'text', text: value, marks: [{ type: 'link', attrs: { href } }] })

const realImages = () => ed.scroller.querySelectorAll('img:not(.ProseMirror-separator)')

describe('text that looks like HTML', () => {
  test('is shown as text and creates no elements', () => {
    const script = '<script>alert(1)</script>'
    const image = '<img src=x onerror=alert(1)>'
    ed.send('load', { doc: doc(p('a', text(script)), p('b', text(image, 'ai'))), mode: 'edit' })
    expect(ed.scroller.querySelectorAll('script')).toHaveLength(0)
    expect(realImages()).toHaveLength(0)
    expect(ed.editor.view.dom.textContent).toBe(script + image)
  })
})

describe('links', () => {
  test('links with other protocols are removed on load and their text is kept', () => {
    const unsafe = ['javascript:alert(1)', ' JavaScript:alert(1)', 'java\tscript:alert(1)', 'file:///etc/passwd', 'data:text/html,hi', 'relative/path']
    ed.send('load', { doc: doc(...unsafe.map((href, index) => p(`p${index}`, link('click', href)))), mode: 'edit' })
    expect(ed.getDoc()).toEqual(doc(...unsafe.map((_, index) => p(`p${index}`, text('click')))))
    expect(ed.scroller.querySelectorAll('a')).toHaveLength(0)
  })

  test('http, https, and mailto links are kept', () => {
    const safe = doc(p('a', link('web', 'http://example.com'), link('secure', 'https://example.com'), link('mail', 'mailto:kim@example.com')))
    ed.send('load', { doc: safe, mode: 'edit' })
    expect(ed.getDoc()).toEqual(safe)
  })

  test('removing an unsafe link never turns its text into a new link', () => {
    ed.send('load', { doc: doc(p('a', link('https://example.com ', 'javascript:alert(1)'))), mode: 'edit' })
    expect(ed.getDoc()).toEqual(doc(p('a', text('https://example.com '))))
  })

  test('streamed documents lose unsafe links too', () => {
    ed.send('streamUpdate', { doc: doc(p('a', link('click', 'javascript:alert(1)'))) })
    expect(ed.getDoc()).toEqual(doc(p('a', text('click'))))
  })

  test('typing a file URL does not leave a link behind', () => {
    ed.send('load', { doc: null, mode: 'edit' })
    ed.editor.commands.insertContent('file:///etc/passwd ')
    expect(ed.scroller.querySelectorAll('a')).toHaveLength(0)
  })

  test('typing a web address still autolinks it', () => {
    ed.send('load', { doc: null, mode: 'edit' })
    ed.editor.commands.insertContent('https://example.com ')
    expect(ed.scroller.querySelector('a')?.getAttribute('href')).toBe('https://example.com')
  })

  for (const mode of ['edit', 'readonly']) {
    test(`clicking a link in ${mode} mode posts linkClicked and never navigates`, () => {
      ed.send('load', { doc: doc(p('a', link('site', 'https://example.com/x'), text(' '), link('mail', 'mailto:kim@example.com'))), mode })
      const [web, mail] = Array.from(ed.scroller.querySelectorAll('a'))
      for (const anchor of [web, mail]) {
        const click = new MouseEvent('click', { bubbles: true, cancelable: true })
        anchor?.dispatchEvent(click)
        expect(click.defaultPrevented).toBe(true)
      }
      expect(ed.sent('linkClicked').map(m => m.payload)).toEqual([{ href: 'https://example.com/x' }, { href: 'mailto:kim@example.com' }])
    })
  }

  test('a middle click never navigates and posts nothing', () => {
    ed.send('load', { doc: doc(p('a', link('site', 'https://example.com/x'))), mode: 'edit' })
    const click = new MouseEvent('auxclick', { bubbles: true, cancelable: true, button: 1 })
    ed.scroller.querySelector('a')?.dispatchEvent(click)
    expect(click.defaultPrevented).toBe(true)
    expect(ed.sent('linkClicked')).toEqual([])
  })
})

describe('paste', () => {
  test('pasted HTML is reduced to the schema with no images, scripts, or unsafe links', () => {
    ed.send('load', { doc: doc(p('a', text('Start'))), mode: 'edit' })
    ed.editor.commands.setTextSelection(6)
    pasteHTML(ed.editor, 
      '<p>kept <img src="x" onerror="alert(1)"><script>alert(1)</script><a href="javascript:alert(1)">bad</a> ' +
        '<a href="https://example.com">good</a></p><blockquote>quoted</blockquote><pre><code>block</code></pre>',
    )
    const json = JSON.stringify(ed.getDoc())
    expect(json).not.toMatch(/image|img|script|javascript|blockquote|codeBlock/)
    expect(json).toContain('https://example.com')
    expect(ed.scroller.querySelectorAll('script')).toHaveLength(0)
    expect(realImages()).toHaveLength(0)
    expect(ed.editor.view.dom.textContent).toContain('kept')
    expect(ed.editor.view.dom.textContent).toContain('bad')
  })
})
