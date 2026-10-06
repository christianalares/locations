import { readFile } from 'node:fs/promises'

const [leftPath, rightPath] = process.argv.slice(2)
if (!leftPath || !rightPath) {
  throw new Error('Usage: node scripts/compare-snapshots.mjs <ledger-or-export.json> <export.json>')
}

async function load(path) {
  const value = JSON.parse(await readFile(path, 'utf8'))
  if (!Array.isArray(value.days)) {
    throw new Error(`${path} has no days array`)
  }
  const days = new Map()
  for (const day of value.days) {
    if (typeof day.dateKey !== 'string' || !Array.isArray(day.entries)) {
      throw new Error(`${path} has an invalid day`)
    }
    if (days.has(day.dateKey)) {
      throw new Error(`${path} has duplicate date ${day.dateKey}`)
    }
    days.set(day.dateKey, day)
  }
  return days
}

function summarize(days) {
  const entries = [...days.values()].flatMap((day) => day.entries)
  const drives = entries.filter(
    (entry) => entry.kind === 'journey' && entry.transportMode === 'driving',
  )
  return {
    days: days.size,
    visits: entries.filter((entry) => entry.kind === 'visit').length,
    journeys: entries.filter((entry) => entry.kind === 'journey').length,
    drives: drives.length,
    driveRoutePoints: drives.reduce((count, entry) => count + (entry.route?.length ?? 0), 0),
    driveDistanceMeters: Math.round(
      drives.reduce((sum, entry) => sum + (entry.distanceMeters ?? 0), 0),
    ),
  }
}

function journeySignature(entry) {
  return JSON.stringify({
    id: entry.id,
    startDate: entry.startDate,
    endDate: entry.endDate,
    transportMode: entry.transportMode,
    distanceMeters: entry.distanceMeters,
    route: entry.route ?? [],
  })
}

const left = await load(leftPath)
const right = await load(rightPath)
const missingFromRight = [...left.keys()].filter((key) => !right.has(key))
const missingFromLeft = [...right.keys()].filter((key) => !left.has(key))
const journeyDifferences = []

for (const [dateKey, day] of left) {
  const other = right.get(dateKey)
  if (!other) {
    continue
  }
  const rightJourneys = new Map(
    other.entries.filter((entry) => entry.kind === 'journey').map((entry) => [entry.id, entry]),
  )
  for (const entry of day.entries.filter((item) => item.kind === 'journey')) {
    const counterpart = rightJourneys.get(entry.id)
    if (!counterpart || journeySignature(entry) !== journeySignature(counterpart)) {
      journeyDifferences.push({
        dateKey,
        id: entry.id,
        leftPoints: entry.route?.length ?? 0,
        rightPoints: counterpart?.route?.length ?? 0,
        leftDistanceMeters: entry.distanceMeters ?? null,
        rightDistanceMeters: counterpart?.distanceMeters ?? null,
      })
    }
  }
}

console.log(
  JSON.stringify(
    {
      left: summarize(left),
      right: summarize(right),
      missingFromRight,
      missingFromLeft,
      journeyDifferences,
    },
    null,
    2,
  ),
)

if (missingFromRight.length > 0 || journeyDifferences.length > 0) {
  process.exitCode = 1
}
