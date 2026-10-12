# ADR 8: Scale pods automatically, but not nodes

*An ADR (Architecture Decision Record) is a short note explaining one
design decision: why it was made and what it costs.*

## Context
The app's load changes during the day. Kubernetes can add pods (HorizontalPodAutoscaler)
and can add nodes (cluster autoscaler). Adding nodes needs an autoscaler that
creates EC2 instances, and that needs AWS permissions beyond EC2 instance control.

## Decision
The HPA runs between 2 and 5 app pods, at 60% CPU of the request. The node
count is fixed at five. Postgres is never autoscaled.

The autoscaler test (2 → 5 → 2 under load) shows that pod scaling works within
the fixed node pool.

## Consequences
- Scaling stays within the two workers. The highest load we can serve is
  limited by their capacity.
- No extra permissions are needed for the scaling.
- Node autoscaling is listed as a production improvement (SECURITY.md).
