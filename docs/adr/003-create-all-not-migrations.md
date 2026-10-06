# ADR 3: `db.create_all()` at startup instead of migrations

## Context
The app needs three tables. Real products use migrations (Alembic): small
versioned scripts that change the schema step by step without losing
data. That adds a tool, a `migrations/` folder and a deploy step (run the
migration before the new app version starts).

## Decision
The app calls `db.create_all()` when it starts. It creates any table that
does not exist yet and leaves existing tables alone. On Postgres the call
holds a database lock (`pg_advisory_xact_lock`), so two pods starting at
the same moment take turns instead of both creating the same table.

## Consequences
- Zero extra steps: a fresh database works on first start.
- `create_all` never changes an existing table. Adding or renaming a
  column later would need a manual change or dropping the data.
  Acceptable for this project because the schema is fixed.
- Production fix: Alembic migrations, run as a Kubernetes Job (or an
  initContainer) before the new Deployment version rolls out.
