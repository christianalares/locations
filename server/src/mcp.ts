import type { TimelineDatabase } from './database.js'
import type { TimelineDay, TimelineEntry } from './schema.js'
import { agentDay, listDays } from './timeline.js'

type Access = 'read' | 'detail'

interface RpcRequest {
  jsonrpc: '2.0'
  id?: string | number | null
  method: string
  params?: Record<string, unknown>
}

const toolDefinitions = [
  {
    name: 'locations_days',
    description: 'Read timeline days with visits and journeys. Coordinates are omitted.',
    inputSchema: {
      type: 'object',
      properties: {
        start: { type: 'string', description: 'First date, YYYY-MM-DD' },
        end: { type: 'string', description: 'Last date, YYYY-MM-DD' },
        limit: { type: 'integer', minimum: 1, maximum: 31 },
      },
    },
  },
  {
    name: 'locations_drives',
    description: 'Find recorded drives and their distances; route points require a detail token.',
    inputSchema: {
      type: 'object',
      properties: {
        start: { type: 'string' },
        end: { type: 'string' },
        limit: { type: 'integer', minimum: 1, maximum: 100 },
        includeRoute: { type: 'boolean' },
      },
    },
  },
  {
    name: 'locations_search_places',
    description: 'Search visited place names and subtitles in the timeline.',
    inputSchema: {
      type: 'object',
      required: ['query'],
      properties: {
        query: { type: 'string', minLength: 1 },
        start: { type: 'string' },
        end: { type: 'string' },
        limit: { type: 'integer', minimum: 1, maximum: 100 },
      },
    },
  },
] as const

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

function boundedInteger(value: unknown, fallback: number, maximum: number): number {
  return typeof value === 'number' && Number.isInteger(value)
    ? Math.min(Math.max(value, 1), maximum)
    : fallback
}

function entrySummary(day: TimelineDay, entry: TimelineEntry): Record<string, unknown> {
  return {
    date: day.dateKey,
    timeZone: day.timeZoneIdentifier,
    title: entry.title,
    subtitle: entry.subtitle ?? null,
    start: entry.startDate,
    end: entry.endDate ?? null,
    distanceMeters: entry.distanceMeters ?? null,
    transportMode: entry.transportMode ?? null,
    confidence: entry.confidence,
  }
}

async function runTool(
  db: TimelineDatabase,
  name: string,
  args: Record<string, unknown>,
  access: Access,
): Promise<unknown> {
  const start = optionalString(args.start)
  const end = optionalString(args.end)

  if (name === 'locations_days') {
    const days = await listDays(db, {
      start,
      end,
      limit: boundedInteger(args.limit, 7, 31),
    })
    return { days: days.map(agentDay), privacy: 'Coordinates and route geometry omitted.' }
  }

  if (name === 'locations_drives') {
    const days = await listDays(db, { start, end, limit: 10_000 })
    const includeRoute = args.includeRoute === true && access === 'detail'
    const drives = days.flatMap((day) =>
      day.entries
        .filter((entry) => entry.kind === 'journey' && entry.transportMode === 'driving')
        .map((entry) => ({
          ...entrySummary(day, entry),
          ...(includeRoute ? { route: entry.route ?? [] } : {}),
        })),
    )
    return { drives: drives.slice(0, boundedInteger(args.limit, 25, 100)) }
  }

  if (name === 'locations_search_places') {
    const query = optionalString(args.query)?.trim().toLocaleLowerCase()
    if (!query || query.length > 100) {
      throw new Error('invalid_query')
    }
    const days = await listDays(db, { start, end, limit: 10_000 })
    const visits = days.flatMap((day) =>
      day.entries
        .filter(
          (entry) =>
            entry.kind === 'visit' &&
            `${entry.title} ${entry.subtitle ?? ''}`.toLocaleLowerCase().includes(query),
        )
        .map((entry) => entrySummary(day, entry)),
    )
    return { visits: visits.slice(0, boundedInteger(args.limit, 25, 100)) }
  }

  throw new Error('unknown_tool')
}

export async function handleMcp(
  db: TimelineDatabase,
  message: RpcRequest,
  access: Access,
): Promise<Record<string, unknown> | null> {
  if (message.jsonrpc !== '2.0' || typeof message.method !== 'string') {
    return {
      jsonrpc: '2.0',
      id: message.id ?? null,
      error: { code: -32600, message: 'Invalid Request' },
    }
  }
  if (message.method === 'notifications/initialized') {
    return null
  }

  let result: unknown
  try {
    if (message.method === 'initialize') {
      result = {
        protocolVersion: '2025-06-18',
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'locations', version: '0.1.0' },
      }
    } else if (message.method === 'ping') {
      result = {}
    } else if (message.method === 'tools/list') {
      result = { tools: toolDefinitions }
    } else if (message.method === 'tools/call') {
      const name = optionalString(message.params?.name)
      const args = message.params?.arguments
      if (
        !name ||
        (args !== undefined && (typeof args !== 'object' || args === null || Array.isArray(args)))
      ) {
        throw new Error('invalid_tool_arguments')
      }
      const value = await runTool(db, name, (args ?? {}) as Record<string, unknown>, access)
      result = { content: [{ type: 'text', text: JSON.stringify(value) }] }
    } else {
      return {
        jsonrpc: '2.0',
        id: message.id ?? null,
        error: { code: -32601, message: 'Method not found' },
      }
    }
  } catch (error) {
    result = {
      content: [{ type: 'text', text: error instanceof Error ? error.message : 'tool_error' }],
      isError: true,
    }
  }

  return { jsonrpc: '2.0', id: message.id ?? null, result }
}
