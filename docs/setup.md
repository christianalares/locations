# Personal server setup

A server is optional for recording on the iPhone. Use it for backups, restoring
onto a replacement phone, and allowing your agent to read timeline summaries.
Each person needs a separate instance: there are no user accounts or tenant
boundaries in the current database, and restoring onto another phone transfers
recording authority to that phone.

## Before provisioning

Read `AGENTS.md` and `privacy.md`. Install Node.js 22 or later, pnpm 10, and the
Railway CLI. The installed `railway` TypeScript SDK requires Railway CLI 5.42.1
or later. Run `pnpm install --frozen-lockfile` and `pnpm check`.

Use a new project in the user's own Railway workspace. Confirm the project and
environment before making changes; do not reuse an existing personal service
or copy someone else's tokens. `.railway/config.json` is a local link file and
must stay ignored.

Sign in and create a dedicated project, if one does not already exist:

```sh
railway login
railway init --name locations
```

A human completes the account sign-in and accepts any hosting charges.

## Infrastructure and secrets

`.railway/railway.ts` defines the intended topology:

| Resource | Purpose |
| --- | --- |
| `locations-db` | PostgreSQL with persistent storage |
| `locations-api` | Node.js API and MCP endpoint |

The API uses the database's `DATABASE_URL` reference. It builds from the
repository root with `pnpm --dir server check-types && pnpm --dir server test`,
starts with `pnpm --dir server start`, listens on port 3000, and has `/health`
as its healthcheck.

Generate separate random access tokens, each at least 32 characters, for:

| Variable | Access |
| --- | --- |
| `LOCATIONS_DEVICE_WRITE_TOKEN` | Native timeline reads, writes, and phone restoration |
| `LOCATIONS_MCP_READ_TOKEN` | MCP summaries without coordinates |
| `LOCATIONS_MCP_DETAIL_TOKEN` | Optional MCP drive routes when explicitly requested |

Keep the originals in the user's password manager or another private secret
store. Configure them as Railway variables on `locations-api`, never as literal
values in the infrastructure file. `preserve()` retains values already held by
Railway; it does not generate new credentials. For a new service, provision the
service and set its secrets before expecting a healthy deployment. If planning
requires the preserved variables to exist first, bootstrap an empty
`locations-api` service in this new project, set its variables, and plan again.

For an agent, pass a stored secret through stdin rather than command arguments:

```sh
railway variable set LOCATIONS_DEVICE_WRITE_TOKEN --stdin --service locations-api
```

Repeat for the other token names, supplying each distinct value through stdin.
Never echo the values into logs, commit them, or publish them in setup reports.

Preview the infrastructure changes:

```sh
railway config plan
```

Review the plan against the intended project and resources. Apply only the
reviewed plan with `railway config apply`. Keep topology changes in
`.railway/railway.ts` and rerun the plan after edits. A fresh installation needs
no legacy import. An installation migrating existing data must complete the
ledger preservation and parity checks in `migration.md` before cutover.

## Deploy and connect

Upload from the repository root so the workspace, lockfile, and server are
included:

```sh
railway up --service locations-api
railway domain --service locations-api --port 3000
```

The infrastructure file does not pin a GitHub repository. For automatic deploys
from a fork, add that fork's GitHub source through the `github()` helper in
`.railway/railway.ts`, then review and apply its plan. Do not deploy another
person's private modifications or credentials.

Wait for a successful deployment, inspect bounded logs, and verify the HTTPS
URL's `/health` response. Also check that a native request without a token is
rejected, and that an MCP read token cannot access native endpoints. A healthy
server alone does not prove that phone capture or backup works.

On the iPhone, choose Settings → Connect and restore. Enter the HTTPS server
address and the device token, then save. Do not paste the MCP token into the
phone. On a fresh empty account, enable tracking after connecting. On a
replacement phone, let restoration finish before enabling it.

For an MCP client, use the server's HTTPS `/mcp` endpoint and a Bearer read token
through the client's secret configuration. Tools are `locations_days`,
`locations_drives`, and `locations_search_places`. Only give detail access when
route coordinates are needed; `includeRoute: true` must also be requested.

## Completion checks for the setup agent

- The API is healthy and unauthorized timeline requests are rejected.
- The correct phone and unique bundle identifier are installed and launch.
- Always and Precise Location permissions are enabled for background capture.
- A fresh drive appears on the phone with plausible start/end times and route.
- With a server, sync finishes and the day's snapshot and ledger backup arrive.
- MCP summaries omit coordinates; native endpoints reject MCP tokens.
- Credentials, exports, and signing material are absent from Git.

Report the server URL, installation method, and test results. Deliver the device
token privately, and explain any seven-day signing expiry. Do not declare a
simulator run or a server healthcheck to be proof of a physical-device drive.
