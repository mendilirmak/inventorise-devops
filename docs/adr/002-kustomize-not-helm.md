# ADR 2: kustomize for our manifests, not our own Helm chart

## Context
The app runs on two clusters (Minikube and EKS) that differ in only a few
details: storage class, ingress host, where Secrets come from, `APP_ENV`.
Helm charts handle differences with Go templates inside the YAML, which
are hard to read and easy to break. kustomize instead patches plain YAML
and is built into `kubectl` (`kubectl apply -k`), so it needs no extra tool.

## Decision
Our own manifests use kustomize: `k8s/base/` holds everything shared,
`k8s/overlays/minikube` and `k8s/overlays/eks` hold only the differences.
Helm is still used to **install third-party software** (ingress-nginx,
kube-prometheus-stack, External Secrets Operator, metrics-server on EKS),
always with a pinned chart version.

## Consequences
- Every manifest is plain, valid Kubernetes YAML that can be read and
  scanned (Checkov) on its own.
- The difference between environments is visible in one small file.
- The image tag is set at deploy time (`kustomize edit set image` in the
  pipeline, a temporary kustomization in `minikube-up.sh`), so the
  committed files never contain a build-specific tag.
- No packaging or versioning of our app as a chart. Not needed: we deploy
  it ourselves and nobody else installs it.
