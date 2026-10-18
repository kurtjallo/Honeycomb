import { isHistoryTransaction } from '@tiptap/pm/history'
import type { Transaction } from '@tiptap/pm/state'

type Origin = 'swift' | 'history' | 'user'

const swiftMeta = 'honeycomb.swift'

export function fromSwift(tr: Transaction): Transaction {
  // Otherwise autolink adds links to URLs in Swift's text, and clearDocument turns an empty
  // heading into a paragraph when the old selection covered everything.
  return tr.setMeta(swiftMeta, true).setMeta('preventAutolink', true).setMeta('preventClearDocument', true)
}

export function originOf(tr: Transaction): Origin {
  const root = (tr.getMeta('appendedTransaction') as Transaction | undefined) ?? tr
  if (root.getMeta(swiftMeta) === true) return 'swift'
  return isHistoryTransaction(root) ? 'history' : 'user'
}
