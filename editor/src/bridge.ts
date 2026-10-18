import type { JSONContent } from '@tiptap/core'
import type { Attrs, Node as PMNode, Schema } from '@tiptap/pm/model'

type Mode = 'edit' | 'readonly'

type Inbound = {
  load: { loadId: number; doc: PMNode; mode: Mode; placeholder: string }
  streamUpdate: { doc: PMNode }
  streamDone: { doc: PMNode }
  setTheme: { appearance: 'light' | 'dark'; fontSize: number; underlineAI: boolean }
  setSources: { blockIds: string[] }
  getDoc: Record<string, never>
  flush: Record<string, never>
  focus: Record<string, never>
}

type Outbound = {
  ready: { schemaVersion: 1; bundleVersion: string }
  docChanged: { loadId: number; doc: JSONContent }
  sourceClicked: { blockId: string; rect: { x: number; y: number; width: number; height: number } }
  linkClicked: { href: string }
}

type ErrorCode = 'badEnvelope' | 'badVersion' | 'unknownType' | 'badPayload'
type Reply = { ok: true; doc?: JSONContent } | { ok: false; error: ErrorCode }
export type Handlers = { [T in keyof Inbound]: (payload: Inbound[T]) => Reply }

declare global {
  interface Window {
    honeycomb?: { receive(envelope: unknown): Reply }
    webkit?: { messageHandlers?: { bridge?: { postMessage(message: unknown): unknown } } }
  }
}

type Parser<T> = (raw: Record<string, unknown>, schema: Schema) => T | undefined

const parsers: { [T in keyof Inbound]: Parser<Inbound[T]> } = {
  load: ({ loadId, doc, mode, placeholder }, schema) => {
    if (!Number.isInteger(loadId)) return undefined
    if (mode !== 'edit' && mode !== 'readonly') return undefined
    if (placeholder !== undefined && typeof placeholder !== 'string') return undefined
    const parsed = doc === null ? (schema.topNodeType.createAndFill() ?? undefined) : parseDoc(doc, schema)
    return parsed && { loadId: loadId as number, doc: parsed, mode, placeholder: placeholder ?? '' }
  },
  streamUpdate: ({ doc }, schema) => {
    const parsed = parseDoc(doc, schema)
    return parsed && { doc: parsed }
  },
  streamDone: ({ doc }, schema) => {
    const parsed = parseDoc(doc, schema)
    return parsed && { doc: parsed }
  },
  setTheme: ({ appearance, fontSize, underlineAI }) => {
    if (appearance !== 'light' && appearance !== 'dark') return undefined
    if (typeof fontSize !== 'number' || !Number.isFinite(fontSize) || fontSize <= 0) return undefined
    if (typeof underlineAI !== 'boolean') return undefined
    return { appearance, fontSize, underlineAI }
  },
  setSources: ({ blockIds }) =>
    Array.isArray(blockIds) && blockIds.every((id): id is string => typeof id === 'string')
      ? { blockIds }
      : undefined,
  getDoc: () => ({}),
  flush: () => ({}),
  focus: () => ({}),
}

// The schema takes any value for these attributes, so the contract's limits are checked here.
const attributeRules: Partial<Record<string, (attrs: Attrs) => boolean>> = {
  heading: ({ level }) => level === 1 || level === 2 || level === 3,
  orderedList: ({ start }) => Number.isInteger(start),
  taskItem: ({ checked }) => typeof checked === 'boolean',
}

function parseDoc(raw: unknown, schema: Schema): PMNode | undefined {
  if (!isRecord(raw) || raw.type !== 'doc') return undefined
  let doc: PMNode
  try {
    doc = schema.nodeFromJSON(raw)
    doc.check()
  } catch {
    return undefined
  }
  let valid = true
  doc.descendants(node => {
    if (attributeRules[node.type.name]?.(node.attrs) === false) valid = false
  })
  return valid ? doc : undefined
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isInboundType(type: string): type is keyof Inbound {
  return Object.hasOwn(parsers, type)
}

function receive(envelope: unknown, schema: Schema, handlers: Handlers): Reply {
  if (!isRecord(envelope)) return { ok: false, error: 'badEnvelope' }
  if (envelope.v !== 1) return { ok: false, error: 'badVersion' }
  const { type, payload } = envelope
  if (typeof type !== 'string' || !isInboundType(type)) return { ok: false, error: 'unknownType' }
  if (!isRecord(payload)) return { ok: false, error: 'badPayload' }
  return dispatch(type, payload, schema, handlers)
}

function dispatch<T extends keyof Inbound>(
  type: T,
  raw: Record<string, unknown>,
  schema: Schema,
  handlers: Handlers,
): Reply {
  const payload = parsers[type](raw, schema)
  return payload === undefined ? { ok: false, error: 'badPayload' } : handlers[type](payload)
}

export function listen(schema: Schema, handlers: Handlers): void {
  window.honeycomb = { receive: envelope => receive(envelope, schema, handlers) }
}

export function post<T extends keyof Outbound>(type: T, payload: Outbound[T]): void {
  window.webkit?.messageHandlers?.bridge?.postMessage({ v: 1, type, payload })
}
