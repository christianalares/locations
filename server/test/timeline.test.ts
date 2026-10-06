// Fictional Null Island fixtures; dates and identities are synthetic.
import assert from 'node:assert/strict'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { Readable } from 'node:stream'
import test from 'node:test'
import type { TimelineRestore, TimelineSync } from '../src/backup.js'
import type { TimelineDatabase } from '../src/database.js'
import { createHandler } from '../src/http.js'
import { handleMcp } from '../src/mcp.js'
import { normalizeTimelineDay, type TimelineDay } from '../src/schema.js'

const route = Array.from({ length: 180 }, (_, index) => ({
  latitude: -0.03 + index * 0.0003,
  longitude: -0.03 + index * 0.0004,
}))

function fixture(updatedAt = '2000-10-04T18:00:00.000Z'): TimelineDay {
  return normalizeTimelineDay({
    dateKey: '2000-10-04',
    timeZoneIdentifier: 'Europe/Stockholm',
    coverage: 'complete',
    entries: [
      {
        id: 'visit-home',
        kind: 'visit',
        title: 'Home',
        startDate: '2000-10-04T06:00:00.000Z',
        endDate: '2000-10-04T08:00:00.000Z',
        coordinate: route[0],
        confidence: 'observed',
        isHome: true,
      },
      {
        id: 'dense-drive',
        kind: 'journey',
        title: 'Drive',
        startDate: '2000-10-04T08:00:00.000Z',
        endDate: '2000-10-04T09:30:00.000Z',
        route,
        distanceMeters: 14_800,
        transportMode: 'driving',
        confidence: 'observed',
      },
      {
        id: 'visit-work',
        kind: 'visit',
        title: 'Office',
        subtitle: 'Null Island',
        startDate: '2000-10-04T09:30:00.000Z',
        endDate: '2000-10-04T16:00:00.000Z',
        coordinate: route.at(-1),
        confidence: 'observed',
      },
    ],
    metrics: {
      distanceMeters: 14_800,
      movingDuration: 5_400,
      awayFromHomeDuration: 28_800,
      meaningfulPlaceCount: 2,
    },
    updatedAt,
    sourceDeviceID: 'iphone',
  })
}

class MemoryDatabase implements TimelineDatabase {
  readonly days = new Map<string, TimelineDay>()

  async registerDevice(): Promise<number> {
    return 1
  }

  async restoreDevice(): Promise<TimelineRestore> {
    return { generation: 1, updatedAt: null, days: await this.all(), ledger: null }
  }

  async sync(input: TimelineSync): Promise<boolean> {
    for (const day of input.days) {
      await this.upsert(day)
    }
    return true
  }

  async list(start: string, end: string, limit: number): Promise<TimelineDay[]> {
    return [...this.days.values()]
      .filter((day) => day.dateKey >= start && day.dateKey <= end)
      .sort((a, b) => b.dateKey.localeCompare(a.dateKey))
      .slice(0, limit)
  }

  async all(): Promise<TimelineDay[]> {
    return [...this.days.values()]
  }

  async upsert(day: TimelineDay): Promise<boolean> {
    const prior = this.days.get(day.dateKey)
    if (prior && prior.updatedAt > day.updatedAt) {
      return false
    }
    this.days.set(day.dateKey, day)
    return true
  }

  async deleteDay(dateKey: string): Promise<boolean> {
    return this.days.delete(dateKey)
  }

  async deleteAll(): Promise<number> {
    const count = this.days.size
    this.days.clear()
    return count
  }
}

test('normalization retains dense route geometry and rejects invalid coordinates', () => {
  const day = fixture()
  assert.equal(day.entries[1]?.route?.length, 180)
  assert.deepEqual(day.entries[1]?.route?.at(-1), route.at(-1))
  assert.equal(day.metrics?.distanceMeters, 14_800)

  const bad = structuredClone(day)
  const badPoint = bad.entries[1]?.route?.[10]
  assert.ok(badPoint)
  badPoint.latitude = 95
  assert.throws(() => normalizeTimelineDay(bad), /invalid_timeline_coordinate/)
})

test('MCP read scope omits geometry and detail scope includes requested drive route', async () => {
  const db = new MemoryDatabase()
  await db.upsert(fixture())

  const days = await handleMcp(
    db,
    {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: 'locations_days', arguments: {} },
    },
    'read',
  )
  assert.doesNotMatch(JSON.stringify(days), /latitude|longitude|residentContacts/)

  const readDrive = await handleMcp(
    db,
    {
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: { name: 'locations_drives', arguments: { includeRoute: true } },
    },
    'read',
  )
  assert.doesNotMatch(JSON.stringify(readDrive), /latitude|longitude/)

  const detailedDrive = await handleMcp(
    db,
    {
      jsonrpc: '2.0',
      id: 3,
      method: 'tools/call',
      params: { name: 'locations_drives', arguments: { includeRoute: true } },
    },
    'detail',
  )
  assert.match(JSON.stringify(detailedDrive), /latitude/)
})

test('HTTP prevents read tokens from changing data and ignores stale day uploads', async () => {
  const db = new MemoryDatabase()
  const handler = createHandler(db, {
    deviceWrite: 'device-token-with-at-least-32-characters',
    mcpRead: 'read-token-with-at-least-32-characters',
  })

  async function call(method: string, path: string, token: string, body?: unknown) {
    const request = Readable.from(
      body === undefined ? [] : [JSON.stringify(body)],
    ) as IncomingMessage
    request.url = path
    request.method = method
    request.headers = { authorization: `Bearer ${token}` }
    let status = 0
    let payload = ''
    const response = {
      writeHead(code: number) {
        status = code
        return this
      },
      end(value?: string) {
        payload = value ?? ''
        return this
      },
    } as unknown as ServerResponse

    await handler(request, response)
    return { status, body: payload ? (JSON.parse(payload) as Record<string, unknown>) : null }
  }

  const day = fixture()
  const denied = await call(
    'PUT',
    '/native/v1/timeline/days/2000-10-04',
    'read-token-with-at-least-32-characters',
    day,
  )
  assert.equal(denied.status, 403)

  const accepted = await call(
    'PUT',
    '/native/v1/timeline/days/2000-10-04',
    'device-token-with-at-least-32-characters',
    day,
  )
  assert.equal(accepted.status, 200)
  assert.equal(accepted.body?.accepted, true)

  const stale = await call(
    'PUT',
    '/native/v1/timeline/days/2000-10-04',
    'device-token-with-at-least-32-characters',
    fixture('2000-10-03T18:00:00.000Z'),
  )
  assert.equal(stale.body?.accepted, false)
  assert.equal(db.days.get('2000-10-04')?.entries[1]?.route?.length, 180)
})
