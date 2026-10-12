# ADR 6: Users are created by the backend, with session and bearer-token login

*An ADR (Architecture Decision Record) is a short note explaining one
design decision: why it was made and what it costs.*

## Context
The app needs logins for two kinds of client: people in a browser, and scripts
calling the API. A sign-up page would bring email checks, password resets and
spam handling, none of which is part of the project's goals.

## Decision
- Accounts are created only from the command line: `flask create-user`.
- Browsers use a session cookie (HttpOnly, SameSite=Lax, Secure in production).
- Scripts send `Authorization: Bearer <token>`. The token is 32 random bytes,
  stored only as a SHA-256 hash, and valid for 24 hours.
- There is one role, so there are no admin pages to protect.

## Consequences
- No sign-up, reset or admin screens to build and secure.
- Every new account needs someone with cluster access to create it.
- No lockout or rate limiting yet, so password guessing is possible. This is a
  known gap (SECURITY.md).
