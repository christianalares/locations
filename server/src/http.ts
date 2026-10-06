import { timingSafeEqual } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { createGunzip } from 'node:zlib'
import { deviceID, normalizeTimelineSync, TimelineDeviceConflictError } from './backup.js'
import type { TimelineDatabase } from './database.js'
import { handleMcp } from './mcp.js'
import { InvalidTimelineDayError, normalizeTimelineDay } from './schema.js'
import { cleanDateKey, listDays } from './timeline.js'

export interface Tokens {
  deviceWrite: string
  mcpRead: string
  mcpDetail?: string
}

function matchesToken(candidate: string, expected: string | undefined): boolean {
  if (!expected) {
    return false
  }
  const actual = Buffer.from(candidate)
  const wanted = Buffer.from(expected)
  return actual.length === wanted.length && timingSafeEqual(actual, wanted)
}

function accessFor(request: IncomingMessage, tokens: Tokens): 'device' | 'detail' | 'read' | null {
  const header = request.headers.authorization
  if (!header?.startsWith('Bearer ')) {
    return null
  }
  const value = header.slice(7)
  if (matchesToken(value, tokens.deviceWrite)) {
    return 'device'
  }
  if (matchesToken(value, tokens.mcpDetail)) {
    return 'detail'
  }
  if (matchesToken(value, tokens.mcpRead)) {
    return 'read'
  }
  return null
}

function send(response: ServerResponse, status: number, value: unknown): void {
  const body = JSON.stringify(value)
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'private, no-store',
    'content-length': Buffer.byteLength(body),
  })
  response.end(body)
}

async function readJson(request: IncomingMessage, maximum = 4_000_000): Promise<unknown> {
  const chunks: Buffer[] = []
  let size = 0
  const encoding = request.headers['content-encoding']
  if (encoding && encoding !== 'gzip' && encoding !== 'identity') {
    throw new InvalidTimelineDayError('unsupported_content_encoding')
  }
  const input = encoding === 'gzip' ? request.pipe(createGunzip()) : request
  try {
    for await (const chunk of input) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
      size += buffer.length
      if (size > maximum) {
        throw new InvalidTimelineDayError('payload_too_large')
      }
      chunks.push(buffer)
    }

    return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown
  } catch (error) {
    if (error instanceof InvalidTimelineDayError) {
      throw error
    }
    throw new InvalidTimelineDayError('invalid_json')
  }
}

function limitParameter(value: string | null): number | undefined {
  if (value === null) {
    return undefined
  }
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 10_000) {
    throw new InvalidTimelineDayError('invalid_timeline_limit')
  }
  return parsed
}

export function createHandler(db: TimelineDatabase, tokens: Tokens) {
  return async (request: IncomingMessage, response: ServerResponse): Promise<void> => {
    try {
      const url = new URL(request.url ?? '/', 'http://localhost')
      const method = request.method ?? 'GET'

      if (url.pathname === '/health' && method === 'GET') {
        send(response, 200, { status: 'ok', backupSchema: 1 })
        return
      }

      const access = accessFor(request, tokens)
      if (!access) {
        send(response, 401, { error: 'unauthorized' })
        return
      }

      if (url.pathname === '/mcp' && method === 'POST') {
        const message = await readJson(request)
        if (!message || typeof message !== 'object' || Array.isArray(message)) {
          send(response, 400, { error: 'invalid_jsonrpc' })
          return
        }
        const result = await handleMcp(
          db,
          message as Parameters<typeof handleMcp>[1],
          access === 'read' ? 'read' : 'detail',
        )
        if (result === null) {
          response.writeHead(202, { 'cache-control': 'private, no-store' })
          response.end()
        } else {
          send(response, 200, result)
        }
        return
      }

      if (access !== 'device') {
        send(response, 403, { error: 'insufficient_scope' })
        return
      }

      if (url.pathname === '/native/v1/timeline/sync' && method === 'POST') {
        const input = normalizeTimelineSync(await readJson(request, 32_000_000))
        send(response, 200, { accepted: await db.sync(input) })
        return
      }

      if (
        (url.pathname === '/native/v1/timeline/register' ||
          url.pathname === '/native/v1/timeline/restore') &&
        method === 'POST'
      ) {
        const body = await readJson(request)
        const sourceDeviceID = deviceID(
          body && typeof body === 'object'
            ? (body as Record<string, unknown>).sourceDeviceID
            : null,
        )
        const result = url.pathname.endsWith('/restore')
          ? await db.restoreDevice(sourceDeviceID)
          : { generation: await db.registerDevice(sourceDeviceID) }
        send(response, 200, result)
        return
      }

      if (url.pathname === '/native/v1/timeline/days' && method === 'GET') {
        const days = await listDays(db, {
          start: url.searchParams.get('start') ?? undefined,
          end: url.searchParams.get('end') ?? undefined,
          limit: limitParameter(url.searchParams.get('limit')),
        })
        send(response, 200, { days })
        return
      }

      const dayMatch = /^\/native\/v1\/timeline\/days\/([^/]+)$/.exec(url.pathname)
      if (dayMatch?.[1]) {
        const dateKey = cleanDateKey(dayMatch[1])
        if (method === 'PUT') {
          const day = normalizeTimelineDay(await readJson(request), dateKey)
          send(response, 200, { day, accepted: await db.upsert(day) })
          return
        }
        if (method === 'DELETE') {
          send(response, 200, { deleted: await db.deleteDay(dateKey) })
          return
        }
      }

      if (url.pathname === '/native/v1/timeline/export' && method === 'GET') {
        send(response, 200, {
          format: 'blip-timeline-v1',
          exportedAt: new Date().toISOString(),
          days: await db.all(),
        })
        return
      }

      if (url.pathname === '/native/v1/timeline' && method === 'DELETE') {
        send(response, 200, { deleted: await db.deleteAll() })
        return
      }

      send(response, 404, { error: 'not_found' })
    } catch (error) {
      if (error instanceof TimelineDeviceConflictError) {
        send(response, 409, { error: error.message })
        return
      }
      if (error instanceof InvalidTimelineDayError) {
        send(response, error.message === 'payload_too_large' ? 413 : 400, { error: error.message })
        return
      }
      console.error('request_failed', error)
      send(response, 500, { error: 'internal_error' })
    }
  }
}
