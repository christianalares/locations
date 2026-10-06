import { defineRailway, postgres, preserve, project, service } from 'railway/iac'

export default defineRailway(() => {
  const locationsDb = postgres('locations-db')

  const locationsApi = service('locations-api', {
    build: {
      builder: 'RAILPACK',
      buildCommand: 'pnpm --dir server check-types && pnpm --dir server test',
    },
    start: 'pnpm --dir server start',
    healthcheck: '/health',
    replicas: 1,
    env: {
      DATABASE_URL: locationsDb.env.DATABASE_URL,
      NODE_ENV: 'production',
      PORT: '3000',
      LOCATIONS_DEVICE_WRITE_TOKEN: preserve(),
      LOCATIONS_MCP_READ_TOKEN: preserve(),
      LOCATIONS_MCP_DETAIL_TOKEN: preserve(),
    },
  })

  return project('locations', {
    resources: [locationsDb, locationsApi],
  })
})
