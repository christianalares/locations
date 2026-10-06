import pg from 'pg'
import { TimelineDeviceConflictError, type TimelineRestore, type TimelineSync } from './backup.js'
import type { TimelineDay } from './schema.js'

const { Pool } = pg

export interface TimelineDatabase {
  list(start: string, end: string, limit: number): Promise<TimelineDay[]>
  all(): Promise<TimelineDay[]>
  upsert(day: TimelineDay): Promise<boolean>
  deleteDay(dateKey: string): Promise<boolean>
  deleteAll(): Promise<number>
  registerDevice(sourceDeviceID: string): Promise<number>
  restoreDevice(sourceDeviceID: string): Promise<TimelineRestore>
  sync(input: TimelineSync): Promise<boolean>
}

export class PostgresTimelineDatabase implements TimelineDatabase {
  private readonly pool: pg.Pool

  constructor(connectionString: string, pool?: pg.Pool) {
    this.pool = pool ?? new Pool({ connectionString, max: 5 })
  }

  async initialize(): Promise<void> {
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS timeline_days (
        date_key text PRIMARY KEY,
        day jsonb NOT NULL,
        updated_at timestamptz NOT NULL,
        source_device_id text NOT NULL,
        CONSTRAINT timeline_day_date_key CHECK (date_key ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')
      )
    `)
    await this.pool.query(`
      CREATE INDEX IF NOT EXISTS timeline_days_updated_at_idx
      ON timeline_days (updated_at DESC)
    `)
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS timeline_backup (
        id boolean PRIMARY KEY DEFAULT true CHECK (id),
        source_device_id text,
        generation bigint NOT NULL DEFAULT 0,
        revision bigint NOT NULL DEFAULT 0,
        updated_at timestamptz,
        ledger jsonb
      )
    `)
    await this.pool.query('INSERT INTO timeline_backup (id) VALUES (true) ON CONFLICT DO NOTHING')
  }

  async close(): Promise<void> {
    await this.pool.end()
  }

  async list(start: string, end: string, limit: number): Promise<TimelineDay[]> {
    const result = await this.pool.query<{ day: TimelineDay }>(
      `SELECT day FROM timeline_days
       WHERE date_key >= $1 AND date_key <= $2
       ORDER BY date_key DESC LIMIT $3`,
      [start, end, limit],
    )
    return result.rows.map((row) => row.day)
  }

  async all(): Promise<TimelineDay[]> {
    const result = await this.pool.query<{ day: TimelineDay }>(
      'SELECT day FROM timeline_days ORDER BY date_key ASC',
    )
    return result.rows.map((row) => row.day)
  }

  async upsert(day: TimelineDay): Promise<boolean> {
    const result = await this.pool.query(
      `INSERT INTO timeline_days (date_key, day, updated_at, source_device_id)
       VALUES ($1, $2::jsonb, $3, $4)
       ON CONFLICT (date_key) DO UPDATE SET
         day = EXCLUDED.day,
         updated_at = EXCLUDED.updated_at,
         source_device_id = EXCLUDED.source_device_id
       WHERE EXCLUDED.updated_at >= timeline_days.updated_at`,
      [day.dateKey, JSON.stringify(day), day.updatedAt, day.sourceDeviceID],
    )
    return (result.rowCount ?? 0) > 0
  }

  async deleteDay(dateKey: string): Promise<boolean> {
    const result = await this.pool.query('DELETE FROM timeline_days WHERE date_key = $1', [dateKey])
    return (result.rowCount ?? 0) > 0
  }

  async deleteAll(): Promise<number> {
    return this.transaction(async (client) => {
      await client.query('SELECT id FROM timeline_backup WHERE id = true FOR UPDATE')
      const result = await client.query('DELETE FROM timeline_days')
      await client.query(
        'UPDATE timeline_backup SET ledger = NULL, updated_at = NULL WHERE id = true',
      )

      return result.rowCount ?? 0
    })
  }

  async registerDevice(sourceDeviceID: string): Promise<number> {
    return this.claimDevice(sourceDeviceID, false).then((result) => result.generation)
  }

  async restoreDevice(sourceDeviceID: string): Promise<TimelineRestore> {
    return this.claimDevice(sourceDeviceID, true)
  }

  private async claimDevice(sourceDeviceID: string, restore: boolean): Promise<TimelineRestore> {
    return this.transaction(async (client) => {
      const result = await client.query<BackupRow>(
        'SELECT * FROM timeline_backup WHERE id = true FOR UPDATE',
      )
      const backup = result.rows[0]
      if (!backup) {
        throw new Error('missing_timeline_backup')
      }
      if (!restore && backup.source_device_id && backup.source_device_id !== sourceDeviceID) {
        throw new TimelineDeviceConflictError('restore_required')
      }
      let generation = Number(backup.generation)
      if (backup.source_device_id !== sourceDeviceID) {
        generation += 1
        await client.query(
          'UPDATE timeline_backup SET source_device_id = $1, generation = $2, revision = 0 WHERE id = true',
          [sourceDeviceID, generation],
        )
      }
      const days = restore
        ? (
            await client.query<{ day: TimelineDay }>(
              'SELECT day FROM timeline_days ORDER BY date_key ASC',
            )
          ).rows.map((row) => row.day)
        : []

      return {
        generation,
        updatedAt: backup.updated_at?.toISOString() ?? null,
        days,
        ledger: restore ? backup.ledger : null,
      }
    })
  }

  async sync(input: TimelineSync): Promise<boolean> {
    return this.transaction(async (client) => {
      const result = await client.query<BackupRow>(
        'SELECT * FROM timeline_backup WHERE id = true FOR UPDATE',
      )
      const backup = result.rows[0]
      if (
        !backup ||
        backup.source_device_id !== input.sourceDeviceID ||
        Number(backup.generation) !== input.generation
      ) {
        throw new TimelineDeviceConflictError('device_replaced')
      }
      // A retried request may have committed before its response was lost.
      // Never replay deletions or an older ledger on a delayed request.
      if (input.revision <= Number(backup.revision)) {
        return input.revision === Number(backup.revision)
      }

      if (input.deleteAll) {
        await client.query('DELETE FROM timeline_days')
      }
      if (input.deletedDateKeys.length > 0) {
        await client.query('DELETE FROM timeline_days WHERE date_key = ANY($1::text[])', [
          input.deletedDateKeys,
        ])
      }
      for (const day of input.days) {
        await client.query(
          `INSERT INTO timeline_days (date_key, day, updated_at, source_device_id)
           VALUES ($1, $2::jsonb, $3, $4)
           ON CONFLICT (date_key) DO UPDATE SET
             day = EXCLUDED.day, updated_at = EXCLUDED.updated_at, source_device_id = EXCLUDED.source_device_id
           WHERE EXCLUDED.updated_at >= timeline_days.updated_at`,
          [day.dateKey, JSON.stringify(day), day.updatedAt, day.sourceDeviceID],
        )
      }
      await client.query(
        'UPDATE timeline_backup SET revision = $1, updated_at = $2, ledger = $3::jsonb WHERE id = true',
        [input.revision, input.updatedAt, JSON.stringify(input.ledger)],
      )

      return true
    })
  }

  private async transaction<T>(work: (client: pg.PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect()
    try {
      await client.query('BEGIN')
      const result = await work(client)
      await client.query('COMMIT')

      return result
    } catch (error) {
      await client.query('ROLLBACK')
      throw error
    } finally {
      client.release()
    }
  }
}

interface BackupRow {
  source_device_id: string | null
  generation: string
  revision: string
  updated_at: Date | null
  ledger: Record<string, unknown> | null
}
