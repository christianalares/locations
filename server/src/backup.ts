import {
  InvalidTimelineDayError,
  normalizeCoordinate,
  normalizeResidentContacts,
  normalizeTimelineDay,
  type TimelineDay,
} from './schema.js'
import { cleanDateKey } from './timeline.js'

export interface TimelineSync {
  sourceDeviceID: string
  generation: number
  revision: number
  updatedAt: string
  days: TimelineDay[]
  deletedDateKeys: string[]
  deleteAll: boolean
  ledger: Record<string, unknown>
}

export interface TimelineRestore {
  generation: number
  updatedAt: string | null
  days: TimelineDay[]
  ledger: Record<string, unknown> | null
}

export class TimelineDeviceConflictError extends Error {}

export function deviceID(value: unknown): string {
  return text(value, 128)
}

export function normalizeTimelineSync(value: unknown): TimelineSync {
  const input = record(value)
  const sourceDeviceID = deviceID(input.sourceDeviceID)
  const days = array(input.days, 10).map((day) => normalizeTimelineDay(day))
  const deletedDateKeys = array(input.deletedDateKeys, 20_000).map((key) =>
    cleanDateKey(text(key, 10)),
  )
  if (new Set(days.map((day) => day.dateKey)).size !== days.length) {
    throw new InvalidTimelineDayError('duplicate_sync_day')
  }
  if (days.some((day) => deletedDateKeys.includes(day.dateKey))) {
    throw new InvalidTimelineDayError('conflicting_sync_day')
  }
  if (typeof input.deleteAll !== 'boolean') {
    throw new InvalidTimelineDayError('invalid_sync_deletion')
  }

  return {
    sourceDeviceID,
    generation: integer(input.generation, 1),
    revision: integer(input.revision, 1),
    updatedAt: date(input.updatedAt),
    days,
    deletedDateKeys,
    deleteAll: input.deleteAll,
    ledger: normalizeBackupLedger(input.ledger),
  }
}

// Raw capture records are backed up verbatim in meaning. Day routes are never
// used to manufacture missing observations or visits during restoration.
export function normalizeBackupLedger(value: unknown): Record<string, unknown> {
  const input = record(value)
  const observations = array(input.observations, 8_000).map((value) => {
    const item = record(value)
    if (
      !['stationary', 'walking', 'cycling', 'automotive', 'unknown'].includes(String(item.motion))
    ) {
      throw new InvalidTimelineDayError('invalid_backup_motion')
    }

    return {
      id: text(item.id, 100),
      timestamp: date(item.timestamp),
      coordinate: normalizeCoordinate(item.coordinate),
      horizontalAccuracy: number(item.horizontalAccuracy, -1, 100_000),
      speedMetersPerSecond: number(item.speedMetersPerSecond, -1, 10_000),
      timeZoneIdentifier: timeZone(item.timeZoneIdentifier),
      motion: item.motion,
    }
  })
  const visits = array(input.visits, 10_000).map((value) => {
    const item = record(value)
    const arrivalDate = date(item.arrivalDate)
    const departureDate = optionalDate(item.departureDate)
    if (departureDate && departureDate < arrivalDate) {
      throw new InvalidTimelineDayError('invalid_backup_visit_dates')
    }

    return {
      id: text(item.id, 100),
      arrivalDate,
      departureDate,
      coordinate: normalizeCoordinate(item.coordinate),
      horizontalAccuracy: number(item.horizontalAccuracy, -1, 100_000),
      timeZoneIdentifier: timeZone(item.timeZoneIdentifier),
      inferredDepartureUpperBound: optionalDate(item.inferredDepartureUpperBound),
      departureWasReported:
        item.departureWasReported == null ? null : boolean(item.departureWasReported),
    }
  })
  const assignments = record(input.visitPlaceAssignments)
  if (Object.keys(assignments).length > 10_000) {
    throw new InvalidTimelineDayError('invalid_backup_assignments')
  }
  const visitPlaceAssignments = Object.fromEntries(
    Object.entries(assignments).map(([id, value]) => {
      const assignment = record(value)
      return [
        text(id, 100),
        {
          place: savedPlace(assignment.place),
          remembersPlace: boolean(assignment.remembersPlace),
        },
      ]
    }),
  )

  return {
    observations,
    visits,
    manuallyEditedDateKeys: array(input.manuallyEditedDateKeys, 20_000).map((key) =>
      cleanDateKey(text(key, 10)),
    ),
    homeCoordinate: input.homeCoordinate == null ? null : normalizeCoordinate(input.homeCoordinate),
    placeLabels: array(input.placeLabels, 10_000).map((value) => {
      const label = record(value)
      return {
        coordinate: normalizeCoordinate(label.coordinate),
        title: text(label.title, 500),
        subtitle: optionalText(label.subtitle, 500),
        isHome: boolean(label.isHome),
      }
    }),
    savedPlaces: array(input.savedPlaces, 10_000).map(savedPlace),
    visitPlaceAssignments,
    residentCloudSchemaVersion: integer(input.residentCloudSchemaVersion ?? 0, 0),
  }
}

function savedPlace(value: unknown): Record<string, unknown> {
  const place = record(value)

  return {
    id: text(place.id, 160),
    title: text(place.title, 500),
    subtitle: optionalText(place.subtitle, 500),
    coordinate: normalizeCoordinate(place.coordinate),
    mapCoordinate: place.mapCoordinate == null ? null : normalizeCoordinate(place.mapCoordinate),
    mapItemIdentifier: optionalText(place.mapItemIdentifier, 512),
    pointOfInterestCategory: optionalText(place.pointOfInterestCategory, 160),
    iconSystemName: optionalText(place.iconSystemName, 100),
    isHome: boolean(place.isHome),
    recognitionRadiusMeters: number(place.recognitionRadiusMeters, 20, 120),
    residentContacts: normalizeResidentContacts(place.residentContacts ?? []),
  }
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new InvalidTimelineDayError('invalid_backup_object')
  }

  return value as Record<string, unknown>
}

function array(value: unknown, maximum: number): unknown[] {
  if (!Array.isArray(value) || value.length > maximum) {
    throw new InvalidTimelineDayError('invalid_backup_array')
  }

  return value
}

function text(value: unknown, maximum: number): string {
  if (typeof value !== 'string' || !value || value.length > maximum) {
    throw new InvalidTimelineDayError('invalid_backup_text')
  }

  return value
}

function optionalText(value: unknown, maximum: number): string | null {
  return value == null ? null : value === '' ? '' : text(value, maximum)
}

function date(value: unknown): string {
  const parsed = Date.parse(text(value, 40))
  if (!Number.isFinite(parsed)) {
    throw new InvalidTimelineDayError('invalid_backup_date')
  }

  return new Date(parsed).toISOString()
}

function optionalDate(value: unknown): string | null {
  return value == null ? null : date(value)
}

function timeZone(value: unknown): string {
  const zone = text(value, 80)
  try {
    new Intl.DateTimeFormat('en', { timeZone: zone })
  } catch {
    throw new InvalidTimelineDayError('invalid_backup_time_zone')
  }

  return zone
}

function number(value: unknown, minimum: number, maximum: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) {
    throw new InvalidTimelineDayError('invalid_backup_number')
  }

  return value
}

function integer(value: unknown, minimum: number): number {
  if (!Number.isSafeInteger(value)) {
    throw new InvalidTimelineDayError('invalid_backup_revision')
  }

  return number(value, minimum, Number.MAX_SAFE_INTEGER)
}

function boolean(value: unknown): boolean {
  if (typeof value !== 'boolean') {
    throw new InvalidTimelineDayError('invalid_backup_boolean')
  }

  return value
}
