# Locations repository rules

- Preserve the ported iPhone capture, drive promotion, observation retention, route recovery, and edit behavior unless a parity test proves a deliberate change.
- Treat the iPhone ledger as the primary capture record and PostgreSQL day snapshots as a mirror. Never infer missing raw observations from cloud days.
- Keep native writes behind the device token. MCP tools are read-only; coordinates require the detail token and an explicit request.
- Use Biome for TypeScript formatting and linting. Use braces and blank lines between validation, work, and return steps.
- Keep Railway topology in `.railway/railway.ts`; run `railway config plan` after edits. Do not apply an unreviewed plan or cut over live data before the migration checks pass.
