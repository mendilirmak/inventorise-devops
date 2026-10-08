#!/usr/bin/env bash
# Installs the platform add-ons on the EC2 (k3s) cluster, once per cluster:
#   ingress-nginx -> cert-manager + private CA -> Argo CD -> Secrets -> monitoring
# Safe to run again.
#
# Needs an SSH tunnel to the Kubernetes API, opened in another terminal
# (it needs your SSH key passphrase, so this script cannot do it for you):
#   ssh -N -L 6443:<cp-1 private IP>:6443 ubuntu@<bastion public IP>
#
#   scripts/ec2-bootstrap.sh
set -euo pipefail

# Pinned chart versions.
INGRESS_NGINX_CHART_VERSION=4.15.1
CERT_MANAGER_VERSION=v1.21.2
ARGOCD_CHART_VERSION=10.10.1

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
export KUBECONFIG=${KUBECONFIG:-$REPO_DIR/ansible/.secrets/kubeconfig}
POSTGRES_PASSWORD_FILE=$REPO_DIR/ansible/.secrets/postgres_app_password

step() { echo; echo "==> $*"; }

step "Checking the connection to the cluster"
if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Cannot reach the cluster. Is the SSH tunnel open? (see the top of this file)" >&2
  exit 1
fi
kubectl get nodes --no-headers | awk '{print "  " $1, $2}'

step "ingress-nginx $INGRESS_NGINX_CHART_VERSION (runs on the workers, ports 80/443)"
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --version "$INGRESS_NGINX_CHART_VERSION" \
  --namespace ingress-nginx --create-namespace \
  --values "$REPO_DIR/k8s/ec2-addons/ingress-nginx-values.yaml" \
  --wait --timeout 5m

step "cert-manager $CERT_MANAGER_VERSION"
helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --version "$CERT_MANAGER_VERSION" \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 5m

step "Private certificate authority"
kubectl apply -f "$REPO_DIR/k8s/ec2-addons/private-ca.yaml"
kubectl -n cert-manager wait --for=condition=Ready certificate/inventorise-ca --timeout=120s

step "Argo CD $ARGOCD_CHART_VERSION"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values "$REPO_DIR/k8s/ec2-addons/argocd-values.yaml" \
  --wait --timeout 8m

step "App namespace and Secrets"
# The database password was created by Ansible on the Postgres nodes. The
# Kubernetes Secret must use the same one. It is passed in the environment of
# the script, never on a command line or on screen.
if [[ ! -r $POSTGRES_PASSWORD_FILE ]]; then
  echo "Missing $POSTGRES_PASSWORD_FILE. Run the Ansible playbook first." >&2
  exit 1
fi
POSTGRES_PASSWORD=$(<"$POSTGRES_PASSWORD_FILE") "$REPO_DIR/scripts/create-secrets.sh"

step "Monitoring (Prometheus + Grafana)"
EXTRA_VALUES=monitoring/values-ec2.yaml "$REPO_DIR/scripts/monitoring-up.sh"

cat <<'EOF'

Platform ready. Next:
  - Argo CD UI:  kubectl -n argocd port-forward svc/argocd-server 8443:443
      user "admin", password:
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  - Grafana:     kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
  - The app itself is deployed by Argo CD from k8s/overlays/ec2 (Phase 5).
EOF
