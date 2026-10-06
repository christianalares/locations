# Railway configuration

`railway.ts` is the only infrastructure authoring file. It defines one PostgreSQL
database and one Locations API in the existing `locations` Railway project.

The three access tokens are preserved Railway variables. Generate distinct,
random values before the first deployment. The device token can read and write
the native timeline API. The MCP read token sees place and drive summaries
without coordinates. The optional MCP detail token allows a client to request
drive route geometry. No MCP token can write.

Run `railway config plan` after changes. Apply only after reviewing the plan and
setting the access tokens. Do not connect the iPhone app or import live data
until the ledger export and parity checks in `docs/migration.md` are complete.
