#!/usr/bin/env bash
# Brings up the whole app on a local Minikube cluster. Safe to run again:
# every step skips or updates what already exists.
#
#   scripts/minikube-up.sh
#
# Steps: start Minikube -> metrics-server addon -> ingress-nginx (Helm) ->
# Secrets -> build the app image inside Minikube -> apply the minikube
# overlay with that image tag -> wait for the rollout.
#
# Needs: minikube, kubectl, helm, docker, and the app repo next to this one
# (or APP_DIR=/path/to/inventorise-app).
set -euo pipefail

# Pinned versions (see README for why these).
MINIKUBE_K8S_VERSION=v1.36.4
INGRESS_NGINX_CHART_VERSION=4.15.1

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_DIR=${APP_DIR:-$REPO_DIR/../inventorise-app}
IMAGE=dusterius/inventory-app

step() { echo; echo "==> $*"; }

step "Starting Minikube (Kubernetes $MINIKUBE_K8S_VERSION)"
# --cni=calico: a network plugin that enforces NetworkPolicy (the default
# one ignores it). Only takes effect when the cluster is first created.
minikube start \
  --driver=docker \
  --kubernetes-version="$MINIKUBE_K8S_VERSION" \
  --cni=calico \
  --cpus=4 \
  --memory=6g

step "Enabling metrics-server (CPU numbers for the autoscaler)"
minikube addons enable metrics-server

step "Installing ingress-nginx $INGRESS_NGINX_CHART_VERSION"
# NodePort: Minikube has no cloud load balancer. Reach it with
# `kubectl port-forward` (printed at the end).
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --version "$INGRESS_NGINX_CHART_VERSION" \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=NodePort \
  --wait --timeout 5m

step "Creating Secrets (skipped if they exist)"
"$REPO_DIR/scripts/create-secrets.sh"

step "Building the app image inside Minikube"
# Tag = the app repo's commit, so every running pod can be traced back to
# exact source. "-dirty" marks uncommitted changes. Never "latest".
TAG=$(git -C "$APP_DIR" rev-parse --short HEAD)
if [[ -n $(git -C "$APP_DIR" status --porcelain) ]]; then
  TAG="$TAG-dirty"
fi
minikube image build -t "$IMAGE:$TAG" "$APP_DIR"

step "Applying k8s/overlays/minikube with image $IMAGE:$TAG"
# A throw-away kustomization on top of the overlay sets the image tag, so
# the committed files are never modified. (kustomize only accepts a
# relative path to the overlay.)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
overlay=$(realpath --relative-to="$tmp" "$REPO_DIR/k8s/overlays/minikube")
cat > "$tmp/kustomization.yaml" <<EOF
resources: [$overlay]
images: [{name: $IMAGE, newTag: "$TAG"}]
EOF
kubectl apply -k "$tmp"

step "Waiting for the rollout"
kubectl -n inventory rollout status statefulset/postgres --timeout=180s
kubectl -n inventory rollout status deployment/app --timeout=180s

cat <<EOF

Done. To open the app:
  1. Keep this running in a separate terminal:
       kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80
  2. Windows hosts file (C:\\Windows\\System32\\drivers\\etc\\hosts, as admin):
       127.0.0.1 inventory.local
  3. Browse to http://inventory.local:8080
Create a user first:  scripts/create-app-user.sh admin
EOF
