# ADR 1: One container for the API and the UI (no React)

*An ADR (Architecture Decision Record) is a short note explaining one
design decision: why it was made and what it costs.*

## Context
The system needs a JSON API (for scripts and the graders) and a web page
for store staff. A common setup is a separate front-end (React) talking to
a separate API service. That means two builds, two images, two
deployments, and CORS (browser rules for cross-site requests) to configure.
The project's priority is a demo that works end to end and code a
classmate can read.

## Decision
One Flask app in one container serves both:
- `/api/...` returns JSON;
- the HTML pages are rendered on the server with Jinja templates.

Both call the same functions in `services.py`, so every business rule
(validation, duplicate SKU, restock) exists exactly once.

## Consequences
- One image to build, scan, deploy and scale; one set of probes and metrics.
- No CORS: pages and API come from the same address.
- Pages reload on every action; there is no rich client-side behaviour.
  Fine for an inventory screen.
- The API only accepts bearer tokens (not the browser cookie), so the
  dashboard chart gets its data embedded in the page by the same
  `services.analytics()` function the API uses.
- If a richer UI is ever needed, a React app could use the existing API
  without changing the back end.
