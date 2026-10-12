# ADR 4: Jenkins on the host Docker socket (lab-only)

*An ADR (Architecture Decision Record) is a short note explaining one
design decision: why it was made and what it costs.*

## Context
The pipeline builds and scans container images. Building images needs a
Docker daemon. On one CI node, the simplest option is to mount the host's
Docker socket into the Jenkins container.

## Decision
Jenkins runs as a container with `/var/run/docker.sock` mounted. The pipeline
builds, scans and pushes images through the host's Docker daemon.

This is an **insecure pattern** for production. Anyone who can change the
pipeline controls that daemon, which means root on the CI node. We accept it
for this course project, because the alternatives need more infrastructure
than the project can justify.

## Consequences
- Builds are fast and simple, and need no extra services.
- A compromised pipeline is a compromised CI node. The node has no public IP,
  and the UI is reachable only through the bastion, which limits the exposure.
- Production fix: rootless builds (Kaniko or BuildKit) on separate build agents.
  See SECURITY.md, accepted risks.
