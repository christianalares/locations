# Continuous sync and phone recovery

The iPhone's ledger remains the primary capture record. PostgreSQL keeps both
the day snapshots used by MCP and a separate backup of retained observations,
visits, saved places, visit assignments, Home, and manual edit intent. The
existing observation and visit retention rules still apply. Credentials,
device Contacts identifiers, tracking permissions, and old pending deletion
intent are not restored onto another phone.

Recording and edits queue an upload after a 15-second coalescing window while
the app is active. Continuous changes do not reset that window. Background
capture queues a file-backed, non-discretionary URLSession upload immediately.
Uploads can continue during ordinary suspension, and their acknowledgments
are recovered after relaunch. Offline changes remain in the ledger; failures
retry with backoff up to five minutes. Opening the app and Sync now also sync.
iOS controls actual transfer timing, and force-quitting the app cancels its
background transfers until it is opened again.

Uploads are gzip-compressed and contain up to ten changed days, newest first, plus the retained capture
and place state. Historical backfills continue in subsequent batches. Each
batch commits its day updates, deletions, and ledger backup in one PostgreSQL
transaction. Generation and revision checks reject delayed older writes and
make retrying a committed request safe. Acknowledgments only clear days that
still match the uploaded copy; edits made during an upload stay queued.

## Recover onto a replacement phone

1. Install Locations and choose **Connect and restore**.
2. Enter the same Locations server address and device token, then save.
   Keep the token in a password manager or another place outside the phone.
3. The empty installation restores all cloud days and any ledger backup before
   uploading. It takes over recording authority from the previous phone.
4. Enable tracking and approve the new phone's permissions when ready.

Restoration preserves historical routes and edits, including days for which
raw observations have expired. An unfinished visit is bounded at the backup
time so the gap between phones is not filled with invented activity. Cloud
day snapshots never produce fabricated raw observations. An existing local
history is not silently replaced. A server with only legacy day snapshots can
still restore those days, but cannot recover raw state it never received.

## Server protocol and rollout

The device token protects POST `/native/v1/timeline/register`, `/sync`, and
`/restore`. MCP tokens cannot access these endpoints. The singleton
`timeline_backup` table holds the active source device, generation, revision,
backup timestamp, and ledger state; `timeline_days` continues serving MCP.
The schema addition preserves existing day rows. Deploy the server before
installing build 5 on the phone, then confirm a ledger backup and drained queues.

Run the server tests against an isolated PostgreSQL instance with
`LOCATIONS_TEST_DATABASE_URL` set. The integration test uses a fresh schema and
checks additive initialization, atomic rollback, idempotent uploads, restoration,
and rejection of uploads from the replaced phone. Swift tests cover failed
upload retries, concurrent edits, cloud-safe residents, and restoration without
inventing observations.
