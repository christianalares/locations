import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { PostgresTimelineDatabase } from './database.js'
import { normalizeTimelineDay, type TimelineDay } from './schema.js'

interface LegacyExport {
  format: string
  days: unknown[]
}

function isLegacyExport(value: unknown): value is LegacyExport {
  return (
    value !== null &&
    typeof value === 'object' &&
    'format' in value &&
    value.format === 'blip-timeline-v1' &&
    'days' in value &&
    Array.isArray(value.days)
  )
}

function summary(days: TimelineDay[]): Record<string, number> {
  const entries = days.flatMap((day) => day.entries)
  const drives = entries.filter(
    (entry) => entry.kind === 'journey' && entry.transportMode === 'driving',
  )
  return {
    days: days.length,
    entries: entries.length,
    visits: entries.filter((entry) => entry.kind === 'visit').length,
    journeys: entries.filter((entry) => entry.kind === 'journey').length,
    drives: drives.length,
    driveRoutePoints: drives.reduce((count, entry) => count + (entry.route?.length ?? 0), 0),
    driveDistanceMeters: Math.round(
      drives.reduce((distance, entry) => distance + (entry.distanceMeters ?? 0), 0),
    ),
  }
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(canonical).join(',')}]`
  }
  if (value && typeof value === 'object') {
    const record = value as Record<string, unknown>
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical(record[key])}`)
      .join(',')}}`
  }
  return JSON.stringify(value)
}

const args = process.argv.slice(2)
const filePath = args.find((arg) => !arg.startsWith('--'))
const apply = args.includes('--apply')
const verify = args.includes('--verify')
if (!filePath) {
  throw new Error('Usage: pnpm --dir server import:legacy <blip-timeline.json> [--apply|--verify]')
}
if (apply && verify) {
  throw new Error('Choose either --apply or --verify')
}

const bytes = await readFile(filePath)
const parsed: unknown = JSON.parse(bytes.toString('utf8'))
if (!isLegacyExport(parsed)) {
  throw new Error('Expected a blip-timeline-v1 cloud export')
}
const days = parsed.days.map((value) => normalizeTimelineDay(value))
const dateKeys = new Set(days.map((day) => day.dateKey))
if (dateKeys.size !== days.length) {
  throw new Error('Duplicate date keys in export')
}
console.log(
  JSON.stringify(
    {
      mode: apply ? 'apply' : verify ? 'verify' : 'dry-run',
      sha256: createHash('sha256').update(bytes).digest('hex'),
      ...summary(days),
    },
    null,
    2,
  ),
)

if (apply || verify) {
  const url = process.env.DATABASE_URL
  if (!url) {
    throw new Error('DATABASE_URL is required for --apply and --verify')
  }
  const db = new PostgresTimelineDatabase(url)
  try {
    await db.initialize()
    if (apply) {
      for (const day of days) {
        await db.upsert(day)
      }
    }
    const remote = new Map((await db.all()).map((day) => [day.dateKey, day]))
    const mismatches = days.filter((day) => canonical(day) !== canonical(remote.get(day.dateKey)))
    if (mismatches.length > 0) {
      throw new Error(
        `Verification failed for ${mismatches.length} dates: ${mismatches
          .slice(0, 10)
          .map((day) => day.dateKey)
          .join(', ')}`,
      )
    }
    console.log(`Verified ${days.length} full day snapshots, including route geometry`)
  } finally {
    await db.close()
  }
}
