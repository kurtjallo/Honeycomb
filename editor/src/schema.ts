import type { Extensions } from '@tiptap/core'
import { Code } from '@tiptap/extension-code'
import { OrderedList } from '@tiptap/extension-list'
import { Placeholder } from '@tiptap/extension-placeholder'
import { TaskItem } from '@tiptap/extension-task-item'
import { TaskList } from '@tiptap/extension-task-list'
import { StarterKit } from '@tiptap/starter-kit'
import { Ai } from './aiMark'
import { BlockIds } from './blockIds'
import { SafeLink } from './links'
import { Sources } from './sources'

// TipTap's code mark excludes every other mark, but Markdown from Swift can put code inside bold, a link, or AI text.
const CombinableCode = Code.extend({ excludes: 'code' })

// The shared schema gives ordered lists only `start`. TipTap's extra `type` would come back in every document.
const StartOnlyOrderedList = OrderedList.extend({
  addAttributes() {
    return {
      start: {
        default: 1,
        parseHTML: element => Number.parseInt(element.getAttribute('start') ?? '', 10) || 1,
      },
    }
  },
})

export function extensions(placeholder: () => string): Extensions {
  return [
    StarterKit.configure({
      blockquote: false,
      codeBlock: false,
      horizontalRule: false,
      strike: false,
      underline: false,
      code: false,
      link: false,
      orderedList: false,
      // It appends an empty paragraph to documents that end in a list, so Swift's documents would not round-trip.
      trailingNode: false,
      heading: { levels: [1, 2, 3] },
    }),
    CombinableCode,
    StartOnlyOrderedList,
    TaskList,
    TaskItem.configure({ nested: true }),
    SafeLink,
    Placeholder.configure({ placeholder }),
    Ai,
    BlockIds,
    Sources,
  ]
}
