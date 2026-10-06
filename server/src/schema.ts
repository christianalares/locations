export type TimelineCoverage = 'untracked' | 'partial' | 'complete'

export interface TimelineCoordinate {
  latitude: number
  longitude: number
}

export interface TimelineResidentReference {
  id: string
  displayName: string
  contactMatchTokens: string[]
}

export interface TimelineEntry {
  id: string
  kind: 'visit' | 'journey'
  title: string
  subtitle?: string | null
  startDate: string
  endDate?: string | null
  coordinate?: TimelineCoordinate | null
  route?: TimelineCoordinate[]
  distanceMeters?: number | null
  transportMode?: string | null
  confidence: 'observed' | 'inferred' | 'uncertain'
  isHome?: boolean
  placeID?: string | null
  placeCoordinate?: TimelineCoordinate | null
  mapItemIdentifier?: string | null
  placeCategory?: string | null
  placeIcon?: string | null
  residentContacts?: TimelineResidentReference[]
}

export interface TimelineMetrics {
  distanceMeters: number
  movingDuration: number
  awayFromHomeDuration: number
  meaningfulPlaceCount: number
}

export interface TimelineDay {
  dateKey: string
  timeZoneIdentifier: string
  coverage: TimelineCoverage
  entries: TimelineEntry[]
  metrics: TimelineMetrics | null
  updatedAt: string
  sourceDeviceID: string
}

const DATE_KEY = /^\d{4}-\d{2}-\d{2}$/
const COVERAGES = new Set<TimelineCoverage>(['untracked', 'partial', 'complete'])
const ENTRY_KINDS = new Set(['visit', 'journey'])
const CONFIDENCES = new Set(['observed', 'inferred', 'uncertain'])
const TRANSPORT_MODES = new Set([
  'walking',
  'cycling',
  'driving',
  'transit',
  'train',
  'ferry',
  'flight',
  'unknown',
])
const MAX_ENTRIES_PER_DAY = 512
const MAX_ROUTE_POINTS_PER_ENTRY = 5_000
const MAX_RESIDENTS_PER_PLACE = 32
const MAX_CONTACT_MATCH_TOKENS = 32
const MAX_DAY_JSON_BYTES = 3_500_000

export class InvalidTimelineDayError extends Error {}

export function normalizeTimelineDay(value: unknown, expectedDateKey?: string): TimelineDay {
  if (!isRecord(value)) throw new InvalidTimelineDayError('invalid_timeline_day')
  const dateKey = cleanDateKey(value.dateKey)
  if (expectedDateKey !== undefined && dateKey !== expectedDateKey) {
    throw new InvalidTimelineDayError('timeline_date_mismatch')
  }
  const timeZoneIdentifier = cleanTimeZone(value.timeZoneIdentifier)
  if (typeof value.coverage !== 'string' || !COVERAGES.has(value.coverage as TimelineCoverage)) {
    throw new InvalidTimelineDayError('invalid_timeline_coverage')
  }
  if (!Array.isArray(value.entries) || value.entries.length > MAX_ENTRIES_PER_DAY) {
    throw new InvalidTimelineDayError('invalid_timeline_entries')
  }
  const entries = value.entries.map(normalizeEntry)
  const metrics = value.metrics == null ? null : normalizeMetrics(value.metrics)
  const updatedAtMS = parseDate(value.updatedAt, 'invalid_timeline_updated_at')
  const sourceDeviceID = cleanText(value.sourceDeviceID, 128, 'invalid_timeline_device')
  const day: TimelineDay = {
    dateKey,
    timeZoneIdentifier,
    coverage: value.coverage as TimelineCoverage,
    entries,
    metrics,
    updatedAt: new Date(updatedAtMS).toISOString(),
    sourceDeviceID,
  }
  if (new TextEncoder().encode(JSON.stringify(day)).byteLength > MAX_DAY_JSON_BYTES) {
    throw new InvalidTimelineDayError('timeline_day_too_large')
  }
  return day
}

function normalizeEntry(value: unknown): TimelineEntry {
  if (!isRecord(value)) throw new InvalidTimelineDayError('invalid_timeline_entry')
  const kind =
    typeof value.kind === 'string' && ENTRY_KINDS.has(value.kind)
      ? (value.kind as TimelineEntry['kind'])
      : null
  const confidence =
    typeof value.confidence === 'string' && CONFIDENCES.has(value.confidence)
      ? (value.confidence as TimelineEntry['confidence'])
      : null
  if (!kind || !confidence) throw new InvalidTimelineDayError('invalid_timeline_entry')
  const startDate = new Date(parseDate(value.startDate, 'invalid_timeline_entry_date'))
  const endDate =
    value.endDate == null ? null : new Date(parseDate(value.endDate, 'invalid_timeline_entry_date'))
  if (endDate && endDate < startDate) {
    throw new InvalidTimelineDayError('invalid_timeline_entry_date')
  }
  const route = value.route == null ? [] : normalizeRoute(value.route)
  const transportMode =
    value.transportMode == null
      ? null
      : typeof value.transportMode === 'string' && TRANSPORT_MODES.has(value.transportMode)
        ? value.transportMode
        : invalid('invalid_timeline_transport')
  return {
    id: cleanText(value.id, 100, 'invalid_timeline_entry_id'),
    kind,
    title: cleanText(value.title, 500, 'invalid_timeline_entry_title'),
    subtitle: value.subtitle == null ? null : cleanTimelineSubtitle(value.subtitle),
    startDate: startDate.toISOString(),
    endDate: endDate?.toISOString() ?? null,
    coordinate: value.coordinate == null ? null : normalizeCoordinate(value.coordinate),
    route,
    distanceMeters:
      value.distanceMeters == null
        ? null
        : cleanNumber(value.distanceMeters, 0, 100_000_000, 'invalid_timeline_distance'),
    transportMode,
    confidence,
    isHome: value.isHome === true,
    placeID:
      value.placeID == null ? null : cleanText(value.placeID, 160, 'invalid_timeline_place_id'),
    placeCoordinate:
      value.placeCoordinate == null ? null : normalizeCoordinate(value.placeCoordinate),
    mapItemIdentifier:
      value.mapItemIdentifier == null
        ? null
        : cleanText(value.mapItemIdentifier, 512, 'invalid_timeline_map_item_id'),
    placeCategory:
      value.placeCategory == null
        ? null
        : cleanText(value.placeCategory, 160, 'invalid_timeline_place_category'),
    placeIcon:
      value.placeIcon == null
        ? null
        : cleanText(value.placeIcon, 100, 'invalid_timeline_place_icon'),
    residentContacts:
      value.residentContacts == null ? [] : normalizeResidentContacts(value.residentContacts),
  }
}

export function normalizeResidentContacts(value: unknown): TimelineResidentReference[] {
  if (!Array.isArray(value) || value.length > MAX_RESIDENTS_PER_PLACE) {
    throw new InvalidTimelineDayError('invalid_timeline_residents')
  }
  const seen = new Set<string>()
  return value.map((resident) => {
    if (!isRecord(resident)) {
      throw new InvalidTimelineDayError('invalid_timeline_resident')
    }
    const id = cleanText(resident.id, 100, 'invalid_timeline_resident_id')
    if (seen.has(id)) throw new InvalidTimelineDayError('duplicate_timeline_resident')
    seen.add(id)
    const tokens = resident.contactMatchTokens == null ? [] : resident.contactMatchTokens
    if (!Array.isArray(tokens) || tokens.length > MAX_CONTACT_MATCH_TOKENS) {
      throw new InvalidTimelineDayError('invalid_timeline_resident_tokens')
    }
    return {
      id,
      displayName: cleanText(resident.displayName, 300, 'invalid_timeline_resident_name'),
      contactMatchTokens: [
        ...new Set(tokens.map((token) => cleanText(token, 100, 'invalid_timeline_resident_token'))),
      ],
    }
  })
}

function normalizeMetrics(value: unknown): TimelineMetrics {
  if (!isRecord(value)) throw new InvalidTimelineDayError('invalid_timeline_metrics')
  return {
    distanceMeters: cleanNumber(value.distanceMeters, 0, 100_000_000, 'invalid_timeline_metrics'),
    movingDuration: cleanNumber(value.movingDuration, 0, 172_800, 'invalid_timeline_metrics'),
    awayFromHomeDuration: cleanNumber(
      value.awayFromHomeDuration,
      0,
      172_800,
      'invalid_timeline_metrics',
    ),
    meaningfulPlaceCount: Math.floor(
      cleanNumber(value.meaningfulPlaceCount, 0, 512, 'invalid_timeline_metrics'),
    ),
  }
}

function normalizeRoute(value: unknown): TimelineCoordinate[] {
  if (!Array.isArray(value) || value.length > MAX_ROUTE_POINTS_PER_ENTRY) {
    throw new InvalidTimelineDayError('invalid_timeline_route')
  }
  return value.map(normalizeCoordinate)
}

export function normalizeCoordinate(value: unknown): TimelineCoordinate {
  if (!isRecord(value)) throw new InvalidTimelineDayError('invalid_timeline_coordinate')
  return {
    latitude: cleanNumber(value.latitude, -90, 90, 'invalid_timeline_coordinate'),
    longitude: cleanNumber(value.longitude, -180, 180, 'invalid_timeline_coordinate'),
  }
}

function cleanDateKey(value: unknown): string {
  if (typeof value !== 'string' || !DATE_KEY.test(value)) {
    throw new InvalidTimelineDayError('invalid_timeline_date')
  }
  const parsed = new Date(`${value}T00:00:00.000Z`)
  if (!Number.isFinite(parsed.valueOf()) || utcDateKey(parsed) !== value) {
    throw new InvalidTimelineDayError('invalid_timeline_date')
  }
  return value
}

function cleanTimeZone(value: unknown): string {
  const zone = cleanText(value, 80, 'invalid_timeline_time_zone')
  try {
    new Intl.DateTimeFormat('en', { timeZone: zone }).format()
    return zone
  } catch {
    throw new InvalidTimelineDayError('invalid_timeline_time_zone')
  }
}

function cleanTimelineSubtitle(value: unknown): string {
  // Apple place addresses can contain multiple lines. Keep them readable in
  // the subtitle instead of rejecting a captured day and blocking its sync.
  const singleLine = typeof value === 'string' ? value.replace(/[\r\n\t]+/g, ' ') : value
  return cleanText(singleLine, 500, 'invalid_timeline_entry_subtitle', true)
}

function cleanText(value: unknown, maximum: number, code: string, allowsEmpty = false): string {
  if (typeof value !== 'string') throw new InvalidTimelineDayError(code)
  const text = value.trim()
  const hasControlCharacter = [...text].some((character) => character.charCodeAt(0) < 32)
  if ((!text && !allowsEmpty) || text.length > maximum || hasControlCharacter) {
    throw new InvalidTimelineDayError(code)
  }
  return text
}

function cleanNumber(value: unknown, minimum: number, maximum: number, code: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) {
    throw new InvalidTimelineDayError(code)
  }
  return value
}

function parseDate(value: unknown, code: string): number {
  if (typeof value !== 'string') throw new InvalidTimelineDayError(code)
  const parsed = Date.parse(value)
  if (!Number.isFinite(parsed)) throw new InvalidTimelineDayError(code)
  return parsed
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function invalid(code: string): never {
  throw new InvalidTimelineDayError(code)
}

function utcDateKey(date: Date): string {
  return date.toISOString().slice(0, 10)
}
