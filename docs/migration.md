# Blip to Locations migration

## Data boundary

Blip's iPhone `Application Support/Blip/Timeline/timeline-v1.json` is the
primary capture ledger. It includes raw observations (normally retained for
about eight days), visits, derived days, saved places, edits, tracking state,
and pending sync. `pending-capture-v1.json` protects recent background events.
Blip's D1 `timeline_days` holds derived day snapshots with routes, but cannot
recreate all local ledger state. The new bundle ID cannot directly read Blip's
private app container. Do not substitute the D1 export for this import.

## Before installing the replacement

1. Keep Blip and Cloudflare running. Make a complete local Blip backup: D1,
   every R2 object, the encryption key through the user's existing secure
   channel, and an inventory with SHA-256 checksums. The current Blip
   `scripts/backup.mjs` handles D1 tables only, so it is insufficient alone.
2. Export the complete iPhone ledger and pending capture file from the actual
   device. For a developer-installed app, Xcode's Devices and Simulators
   container download can provide the files. A production install needs the
   updated Blip build with “Export Full Ledger for Locations”; save both files
   from its share sheet. Blip's original “Export Timeline as JSON” exports days
   only and is insufficient.
3. Get the Cloudflare timeline export using Blip's “Export Cloud Timeline for
   Locations” control, which calls the authenticated
   `/native/v1/timeline/export` endpoint. Save it unmodified. Run
   `node scripts/compare-snapshots.mjs <ledger-json> <cloud-export-json>`.
   Investigate missing days and any shorter or altered drive routes.
4. Keep the original files. Import `timeline-v1.json` and optionally
   `pending-capture-v1.json` into Locations on the iPhone. Do not select the
   separate cloud export in the ledger picker. The app keeps untouched copies and
   disables old deletion intent before syncing to the new service.
5. Import the cloud day snapshots into PostgreSQL with
   `pnpm --dir server import:legacy <cloud-export-json>` (dry run), then
   `--apply`, then `--verify`. The importer compares the full normalized day
   payload, including all route points, after write.
6. Export from the Locations native API and compare it with the local ledger.
   Check total days, visits, journeys, drive count, route point count, distances,
   and representative long drives. Only then configure the app's new sync URL
   and token. Confirm a newly captured drive on device and in PostgreSQL.
7. After verified parity, disable tracking in Blip, then enable it in
   Locations. Keep the old app and Cloudflare data until a separate, explicit
   retention decision.

## Route parity command

`compare-snapshots.mjs` accepts either the full ledger (`days` field) or the
Cloudflare day export. It reports missing days and changed journey geometry.
The source device may have newer unsynced days; such differences are a reason
to wait for sync or preserve the local-only day, not to overwrite it.
