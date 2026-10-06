# ADR 5: kube-prometheus-stack instead of hand-written monitoring

## Context
We need app metrics (requests, latency, errors, low-stock count) and
cluster metrics (pod CPU and memory, replica count for the autoscaling
demo), shown on a Grafana dashboard. Installing Prometheus, Grafana,
kube-state-metrics and node-exporter by hand means many manifests, plus
the permissions (RBAC) and scrape configuration, all of which we would
have to maintain.

## Decision
Install the community Helm chart **kube-prometheus-stack** (pinned
version) into the `monitoring` namespace. Our own part is small:
- `monitoring/values.yaml`: Alertmanager off (alerting is out of scope),
  2-day retention, Grafana admin password from a Secret;
- a `ServiceMonitor` that tells Prometheus to scrape the app's `/metrics`;
- one dashboard JSON, loaded automatically through a labelled ConfigMap.

## Consequences
- A full, standard monitoring stack in one command; the same chart runs
  on Minikube and EKS.
- The Prometheus Operator's `ServiceMonitor` replaces hand-written scrape
  configuration.
- The stack uses about 1.5-2 GB of memory, a real share of a 6 GB
  Minikube or a t3.medium node.
- We depend on the chart's defaults and upgrades; pinning the version
  keeps installs repeatable.
