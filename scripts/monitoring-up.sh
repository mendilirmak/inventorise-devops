#!/usr/bin/env bash
# Installs Prometheus + Grafana (kube-prometheus-stack) into the
# "monitoring" namespace, then our ServiceMonitor and Grafana dashboard.
# Safe to run again.
#
#   scripts/monitoring-up.sh
#
# Run after scripts/minikube-up.sh (the app must exist to be scraped).
set -euo pipefail

KUBE_PROMETHEUS_STACK_VERSION=91.9.0
NAMESPACE=monitoring
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)

step() { echo; echo "==> $*"; }

step "Namespace $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

step "Grafana admin Secret (random password; skipped if it exists)"
if kubectl -n "$NAMESPACE" get secret grafana-admin >/dev/null 2>&1; then
  echo "secret/grafana-admin already exists - left unchanged"
else
  password=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
  # Passed through a file descriptor, so it never shows in the process list.
  kubectl -n "$NAMESPACE" create secret generic grafana-admin \
    --from-env-file=<(printf 'admin-user=admin\nadmin-password=%s\n' "$password")
  unset password
fi

step "kube-prometheus-stack $KUBE_PROMETHEUS_STACK_VERSION (takes a few minutes)"
helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts \
  --version "$KUBE_PROMETHEUS_STACK_VERSION" \
  --namespace "$NAMESPACE" \
  --values "$REPO_DIR/monitoring/values.yaml" \
  --wait --timeout 10m

step "ServiceMonitor + Grafana dashboard"
kubectl apply -k "$REPO_DIR/monitoring"

cat <<'EOF'

Done. To open Grafana:
  1. Keep this running in a separate terminal:
       kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
  2. Browse to http://localhost:3000 and log in as "admin". The password:
       kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
  3. Dashboards -> "Inventorise app".
EOF
