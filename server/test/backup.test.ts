// Fictional Null Island fixtures; dates and identities are synthetic.
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { Readable } from 'node:stream'
import test from 'node:test'
import { gzipSync } from 'node:zlib'
import pg from 'pg'
import { normalizeTimelineSync, TimelineDeviceConflictError } from '../src/backup.js'
import { PostgresTimelineDatabase } from '../src/database.js'
import { createHandler } from '../src/http.js'

function fixture(revision = 1) {
  return {
    sourceDeviceID: 'original-phone',
    generation: 1,
    revision,
    updatedAt: '2000-10-05T16:00:00Z',
    days: [
      {
        dateKey: '2000-10-05',
        timeZoneIdentifier: 'Europe/Stockholm',
        coverage: 'partial',
        entries: [
          {
            id: 'visit-home',
            kind: 'visit',
            title: 'Home',
            confidence: 'observed',
            startDate: '2000-10-05T14:00:00Z',
            coordinate: { latitude: 0, longitude: 0 },
          },
        ],
        updatedAt: '2000-10-05T16:00:00Z',
        sourceDeviceID: 'original-phone',
      },
    ],
    deletedDateKeys: [] as string[],
    deleteAll: false,
    ledger: {
      observations: [
        {
          id: randomUUID(),
          timestamp: '2000-10-05T14:00:00Z',
          coordinate: { latitude: 0, longitude: 0 },
          horizontalAccuracy: 10,
          speedMetersPerSecond: 0,
          timeZoneIdentifier: 'Europe/Stockholm',
          motion: 'stationary',
        },
      ],
      visits: [
        {
          id: randomUUID(),
          arrivalDate: '2000-10-05T14:00:00Z',
          departureDate: null,
          coordinate: { latitude: 0, longitude: 0 },
          horizontalAccuracy: 10,
          timeZoneIdentifier: 'Europe/Stockholm',
          departureWasReported: false,
        },
      ],
      manuallyEditedDateKeys: ['2000-10-05'],
      homeCoordinate: { latitude: 0, longitude: 0 },
      placeLabels: [],
      savedPlaces: [
        {
          id: 'home',
          title: 'Home',
          coordinate: { latitude: 0, longitude: 0 },
          isHome: true,
          recognitionRadiusMeters: 65,
          residentContacts: [
            { id: 'alice', displayName: 'Alice', contactIdentifier: 'device-only-secret' },
          ],
        },
      ],
      visitPlaceAssignments: {},
      residentCloudSchemaVersion: 1,
      trackingEnabled: true,
      pendingDeleteAll: true,
    },
  }
}

test('backup preserves real capture evidence and edits, stripping device controls and contact IDs', () => {
  const input = fixture()
  const backup = normalizeTimelineSync(input)
  assert.equal((backup.ledger.observations as unknown[]).length, 1)
  assert.equal((backup.ledger.visits as unknown[]).length, 1)
  assert.deepEqual(backup.ledger.manuallyEditedDateKeys, ['2000-10-05'])
  assert.equal(backup.ledger.trackingEnabled, undefined)
  assert.equal(backup.ledger.pendingDeleteAll, undefined)
  assert.doesNotMatch(JSON.stringify(backup), /device-only-secret|contactIdentifier/)
  assert.throws(() => normalizeTimelineSync({ ...input, revision: 1.5 }), /invalid_backup_revision/)
  assert.throws(
    () => normalizeTimelineSync({ ...input, deletedDateKeys: ['2000-10-05'] }),
    /conflicting_sync_day/,
  )
  const observation = input.ledger.observations[0]
  assert.ok(observation)
  observation.coordinate.latitude = 91
  assert.throws(() => normalizeTimelineSync(input), /invalid_timeline_coordinate/)
})

test('backup and restore endpoints remain inaccessible to both MCP tokens', async () => {
  const db = new PostgresTimelineDatabase('postgresql://unused')
  const handler = createHandler(db, { deviceWrite: 'device', mcpRead: 'read', mcpDetail: 'detail' })
  for (const token of ['read', 'detail']) {
    for (const path of ['sync', 'restore', 'register']) {
      const request = Readable.from([]) as IncomingMessage
      request.url = `/native/v1/timeline/${path}`
      request.method = 'POST'
      request.headers = { authorization: `Bearer ${token}` }
      let status = 0
      const response = {
        writeHead(code: number) {
          status = code
        },
        end() {},
      } as unknown as ServerResponse
      await handler(request, response)
      assert.equal(status, 403)
    }
  }
  await db.close()
})

test('HTTP accepts compressed backup batches and rejects malformed gzip', async () => {
  const db = new PostgresTimelineDatabase('postgresql://unused')
  db.sync = async (input) => {
    assert.equal(input.days.length, 1)
    assert.equal((input.ledger.observations as unknown[]).length, 1)
    return true
  }
  const handler = createHandler(db, { deviceWrite: 'device', mcpRead: 'read' })
  for (const [body, expectedStatus] of [
    [gzipSync(JSON.stringify(fixture())), 200],
    [Buffer.from('not gzip'), 400],
  ] as const) {
    const request = Readable.from([body]) as IncomingMessage
    request.url = '/native/v1/timeline/sync'
    request.method = 'POST'
    request.headers = { authorization: 'Bearer device', 'content-encoding': 'gzip' }
    let status = 0
    const response = {
      writeHead(code: number) {
        status = code
      },
      end() {},
    } as unknown as ServerResponse
    await handler(request, response)
    assert.equal(status, expectedStatus)
  }
  await db.close()
})

test('Postgres backup is atomic, repeatable, and fenced when a replacement phone restores', {
  skip: !process.env.LOCATIONS_TEST_DATABASE_URL,
}, async () => {
  const connectionString = process.env.LOCATIONS_TEST_DATABASE_URL
  assert.ok(connectionString)
  const schema = `locations_test_${randomUUID().replaceAll('-', '')}`
  const admin = new pg.Pool({ connectionString })
  await admin.query(`CREATE SCHEMA ${schema}`)
  const pool = new pg.Pool({ connectionString, options: `-c search_path=${schema}` })
  const db = new PostgresTimelineDatabase(connectionString, pool)
  try {
    await db.initialize()
    // Running additive initialization twice cannot replace existing history.
    const originalDay = normalizeTimelineSync(fixture()).days[0]
    assert.ok(originalDay)
    await db.upsert(originalDay)
    await db.initialize()
    assert.equal((await db.all()).length, 1)
    assert.equal(await db.registerDevice('original-phone'), 1)
    assert.equal(await db.registerDevice('original-phone'), 1)
    await assert.rejects(db.registerDevice('other-phone'), TimelineDeviceConflictError)

    const first = normalizeTimelineSync(fixture())
    assert.equal(await db.sync(first), true)
    assert.equal(await db.sync({ ...first, days: [], deleteAll: true }), true)
    assert.equal((await db.all()).length, 1)
    assert.equal(await db.sync({ ...first, revision: 0, days: [], deleteAll: true }), false)
    assert.equal((await db.all()).length, 1)

    await pool.query(`CREATE FUNCTION reject_test_backup() RETURNS trigger AS $$
      BEGIN IF NEW.revision = 2 THEN RAISE EXCEPTION 'injected_failure'; END IF; RETURN NEW; END;
      $$ LANGUAGE plpgsql`)
    await pool.query(
      'CREATE TRIGGER reject_test_backup BEFORE UPDATE ON timeline_backup FOR EACH ROW EXECUTE FUNCTION reject_test_backup()',
    )
    await assert.rejects(
      db.sync({ ...first, revision: 2, days: [], deleteAll: true }),
      /injected_failure/,
    )
    assert.equal((await db.all()).length, 1, 'failed backup rolls day deletions back too')

    const restored = await db.restoreDevice('replacement-phone')
    assert.equal(restored.generation, 2)
    assert.equal(restored.days.length, 1)
    assert.deepEqual(restored.ledger, first.ledger)
    await assert.rejects(db.sync({ ...first, revision: 3 }), /device_replaced/)
    const next = { ...first, sourceDeviceID: 'replacement-phone', generation: 2 }
    assert.equal(await db.sync(next), true)
    assert.equal(await db.deleteAll(), 1)
    const erased = await db.restoreDevice('third-phone')
    assert.deepEqual(erased.days, [])
    assert.equal(erased.ledger, null)
  } finally {
    await db.close()
    await admin.query(`DROP SCHEMA ${schema} CASCADE`)
    await admin.end()
  }
})
