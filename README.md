# Locations

Standalone iPhone timeline capture with a Railway-backed mirror and read-only MCP.
The Swift timeline is ported from Blip's current behavior, including dense driving,
visits, route recovery, saved places, manual journey edits, and crash-safe capture.
There is no Mac app.

## Layout

- `swift/`: the native timeline package and source tests
- `apps/ios/`: XcodeGen project for the iPhone app
- `server/`: PostgreSQL sync API and MCP endpoint
- `.railway/`: TypeScript infrastructure definition
- `docs/migration.md`: legacy export, import, and cutover gates

## Local server checks

```sh
pnpm install
pnpm --dir server check-types
pnpm --dir server test
pnpm exec biome check .
```

The API requires `DATABASE_URL`, `LOCATIONS_DEVICE_WRITE_TOKEN`, and
`LOCATIONS_MCP_READ_TOKEN`; `LOCATIONS_MCP_DETAIL_TOKEN` is optional. All tokens
must be distinct, and the required tokens must have at least 32 characters.
The device token is stored in the iPhone Keychain after entry in Settings.

Recorded changes upload automatically, with a 15-second coalescing window in
the foreground and file-backed uploads from background capture. PostgreSQL
backs up retained capture state and saved places alongside the day snapshots.
On a replacement phone, connect to the same service to restore before enabling
tracking. See `docs/sync-and-restore.md` for recovery and timing details.

`POST /mcp` supports `locations_days`, `locations_drives`, and
`locations_search_places`. A read token omits coordinates. A detail token may
request a drive's route with `includeRoute: true`. MCP has no write tools.

## iPhone project

The project is defined at `apps/ios/project.yml`. Generate it with XcodeGen,
then open `apps/ios/LocationsIOS.xcodeproj`. The simulator and development
iPhone builds use Xcode 27. Run native tests with `swift test --package-path swift`. See
`docs/signing.md` for installation. The existing Blip timeline remains the
reference until an on-device drive comparison passes.

The new app will not start capture automatically on first launch. Connect to
restore an existing Locations backup, or import `timeline-v1.json` and optionally
`pending-capture-v1.json`, before enabling tracking. The importer saves untouched
copies under the new app's Application
Support directory before creating its own ledger.

Tests and previews use fictional Null Island fixtures. See `docs/privacy.md`
for the runtime data boundary and precautions when publishing source.
