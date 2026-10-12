# ADR 2: kustomize for our manifests, not our own Helm chart

## Context
The app is deployed to a k3s cluster on EC2. It needs a few settings that
are specific to that cluster: where Postgres lives, HTTPS, the image tag.
Helm charts handle differences with Go templates inside the YAML, which
are hard to read and easy to break. kustomize instead patches plain YAML
and is built into `kubectl` (`kubectl apply -k`), so it needs no extra tool.

## Decision
Our own manifests use kustomize: `k8s/base/` holds everything shared,
`k8s/overlays/ec2` holds only what is specific to the cluster. Helm is
still used to **install third-party software** (ingress-nginx, cert-manager,
Argo CD, kube-prometheus-stack), always with a pinned chart version.

## Consequences
- Every manifest is plain, valid Kubernetes YAML that can be read and
  scanned (Checkov) on its own.
- The difference between environments is visible in one small file.
- The image tag is the `newTag` line of the overlay. The Jenkins pipeline
  rewrites it and commits it, and Argo CD applies it, so git always shows
  exactly what runs.
- No packaging or versioning of our app as a chart. Not needed: we deploy
  it ourselves and nobody else installs it.
