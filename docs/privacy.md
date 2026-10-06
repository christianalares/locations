# Privacy and public source

Tests and previews use fictional places around Null Island (latitude 0,
longitude 0), synthetic dates, and example identities. Their nearby fixes,
journey shapes, and timing relationships exercise capture and recovery without
embedding a person's location history. Never copy a live ledger into a fixture.

The installed app records location history only when tracking is enabled.
Its private iPhone ledger contains observations, visits, routes, saved places,
Home, and edits. Local ledger files use iOS file protection that remains
available after the first unlock, allowing background capture while locked.

When connected to a server, the app uploads day snapshots and a backup of
retained capture and saved-place state for phone recovery. PostgreSQL stores
readable JSON records; this is not end-to-end encrypted. Protect database
access and treat database backups as private location history.

People explicitly associated with saved places can be included in uploads by
display name and hashed email/phone match values. Device Contacts identifiers
and photos stay local. The match values are unsalted SHA-256 hashes, so someone
with the uploaded values can compare them with guessed emails or phone numbers.
They are personal data, not anonymous identifiers.

MCP requires an access token. Read access omits coordinates but still exposes
place names and subtitles, visit times, home status, and activity summaries.
Drive routes require detail access and an explicit `includeRoute` request.
MCP has no write tools. The device token can read, restore, and change native
timeline data, so it must remain private.

Before publishing changes, scan both the working files and Git history for
credentials and inspect fixtures and documentation for personal data. Keep
ledger exports, bootstrap credentials, local environment files, and signing
material outside Git. A secret scanner cannot identify a private home address
embedded in otherwise valid test coordinates.
