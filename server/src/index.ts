import { createServer } from 'node:http'
import { PostgresTimelineDatabase } from './database.js'
import { createHandler } from './http.js'

function required(name: string): string {
  const value = process.env[name]
  if (!value || value.length < 32) {
    throw new Error(`${name} is required and must be at least 32 characters`)
  }
  return value
}

const databaseURL = process.env.DATABASE_URL
if (!databaseURL) {
  throw new Error('DATABASE_URL is required')
}

const tokens = {
  deviceWrite: required('LOCATIONS_DEVICE_WRITE_TOKEN'),
  mcpRead: required('LOCATIONS_MCP_READ_TOKEN'),
  mcpDetail: process.env.LOCATIONS_MCP_DETAIL_TOKEN,
}
if (tokens.mcpDetail && tokens.mcpDetail.length < 32) {
  throw new Error('LOCATIONS_MCP_DETAIL_TOKEN must be at least 32 characters')
}
if (
  new Set(Object.values(tokens).filter(Boolean)).size !==
  Object.values(tokens).filter(Boolean).length
) {
  throw new Error('Locations access tokens must be distinct')
}

const database = new PostgresTimelineDatabase(databaseURL)
await database.initialize()

const port = Number(process.env.PORT ?? '3000')
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('PORT must be a valid port number')
}

const server = createServer(createHandler(database, tokens))
server.listen(port, '0.0.0.0', () => {
  console.info(`locations listening on ${port}`)
})

async function shutdown(): Promise<void> {
  server.close()
  await database.close()
}

process.once('SIGTERM', () => void shutdown())
process.once('SIGINT', () => void shutdown())
