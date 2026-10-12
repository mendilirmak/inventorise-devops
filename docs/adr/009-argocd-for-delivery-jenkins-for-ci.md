# ADR 9: Argo CD for delivery, Jenkins for CI only

*An ADR (Architecture Decision Record) is a short note explaining one
design decision: why it was made and what it costs.*

## Context
Jenkins can deploy directly with `kubectl apply`. That gives no record of what is
running compared with what was committed, and a manual change in the cluster
is never reverted.

## Decision
Jenkins tests, builds and scans. Then it commits the new image tag to the devops
repo, and stops. Argo CD watches that repo, applies the change, and reverts any
manual change to the cluster (`selfHeal`). Jenkins waits for Argo CD to report
Synced and Healthy, and reverts the tag commit if that does not happen in 180 s.

Git is the source of truth.

## Consequences
- Every running version can be traced to a commit.
- A rollback is a `git revert`, and it is also automatic when the deploy fails.
- Two tools to learn instead of one. Argo CD polls git every 30 seconds, so a
  deploy takes about a minute.
