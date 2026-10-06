import type { TimelineDatabase } from './database.js'
import { InvalidTimelineDayError, type TimelineDay } from './schema.js'

export interface RangeInput {
  start?: string
  end?: string
  limit?: number
}

export function cleanDateKey(value: string): string {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new InvalidTimelineDayError('invalid_timeline_date')
  }
  const parsed = new Date(`${value}T00:00:00.000Z`)
  if (!Number.isFinite(parsed.valueOf()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new InvalidTimelineDayError('invalid_timeline_date')
  }
  return value
}

export async function listDays(
  db: TimelineDatabase,
  input: RangeInput = {},
): Promise<TimelineDay[]> {
  const start = cleanDateKey(input.start ?? '2000-01-01')
  const end = cleanDateKey(input.end ?? new Date().toISOString().slice(0, 10))
  if (start > end) {
    throw new InvalidTimelineDayError('invalid_timeline_range')
  }
  const limit = Math.min(Math.max(input.limit ?? 10_000, 1), 10_000)
  return db.list(start, end, limit)
}

export function agentDay(day: TimelineDay): Record<string, unknown> {
  return {
    date: day.dateKey,
    timeZone: day.timeZoneIdentifier,
    coverage: day.coverage,
    metrics: day.metrics,
    entries: day.entries.map((entry) => ({
      kind: entry.kind,
      title: entry.title,
      subtitle: entry.subtitle ?? null,
      start: entry.startDate,
      end: entry.endDate ?? null,
      distanceMeters: entry.distanceMeters ?? null,
      transportMode: entry.transportMode ?? null,
      confidence: entry.confidence,
      isHome: entry.isHome ?? false,
    })),
  }
}
