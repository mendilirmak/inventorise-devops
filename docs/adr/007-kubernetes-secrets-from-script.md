# ADR 7: Kubernetes Secrets from a script, not AWS Secrets Manager

*An ADR (Architecture Decision Record) is a short note explaining one
design decision: why it was made and what it costs.*

## Context
The first plan stored the database password and the app key in AWS Secrets
Manager, read by the External Secrets Operator. Secrets Manager is an AWS
service outside the EC2-only scope the project agreed on, and it has a monthly
cost per secret.

## Decision
`scripts/create-secrets.sh` creates the two Secrets with random values, from
inside the cluster. Nothing is committed to git. The Secrets are encrypted in
etcd (k3s `secrets-encryption`).

This ADR replaces the earlier plan to use Secrets Manager.

## Consequences
- No extra AWS service, and no extra monthly cost.
- The Secrets are created on the cluster, not in git.
- Whoever can read Secrets in the cluster can read these values. Rotation is
  manual. A secrets manager with rotation is the production answer (SECURITY.md).
