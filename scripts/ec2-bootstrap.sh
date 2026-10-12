#!/usr/bin/env bash
# Installs the cluster add-ons on the EC2 (k3s) cluster, in this order:
#   ingress-nginx -> cert-manager + private CA -> Argo CD -> Secrets -> monitoring
# Safe to run again.
#
# Needs an SSH tunnel to the Kubernetes API, opened in another terminal. It
# asks for your SSH key passphrase, so the script cannot open it itself:
#   ssh -N -L 6443:<cp-1 private IP>:6443 ubuntu@<bastion public IP>
#
#   scripts/ec2-bootstrap.sh
set -euo pipefail

# Chart versions (pinned).
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
# Ansible created the database password on the Postgres nodes. The Kubernetes
# Secret must hold the same password. It is passed through the environment, so
# it never appears on the command line or on screen.
if [[ ! -r $POSTGRES_PASSWORD_FILE ]]; then
  echo "Missing $POSTGRES_PASSWORD_FILE. Run the Ansible playbook first." >&2
  exit 1
fi
POSTGRES_PASSWORD=$(<"$POSTGRES_PASSWORD_FILE") "$REPO_DIR/scripts/create-secrets.sh"

step "Public CA certificate and CI access"
# The CA certificate is public, so it goes into a ConfigMap. The Jenkins smoke
# test reads it to trust the private CA. We never copy the CA's Secret, because
# that Secret also holds the private key.
kubectl -n cert-manager get secret inventorise-ca -o 'jsonpath={.data.tls\.crt}' | base64 -d > /tmp/inventorise-ca.crt
kubectl -n inventory create configmap inventorise-ca-cert --from-file=ca.crt=/tmp/inventorise-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/inventorise-ca.crt
# Limits what Jenkins may do in the cluster (see argocd/ci-access.yaml).
kubectl apply -f "$REPO_DIR/argocd/ci-access.yaml"

step "Argo CD application (k8s/overlays/ec2)"
# Until the first pipeline run sets a real image tag, the app pods show
# ImagePullBackOff. That is expected.
kubectl apply -f "$REPO_DIR/argocd/application-ec2.yaml"

step "Monitoring (Prometheus + Grafana)"
EXTRA_VALUES=monitoring/values-ec2.yaml "$REPO_DIR/scripts/monitoring-up.sh"

cat <<'EOF'

Platform ready. Next:
  - Argo CD UI:  kubectl -n argocd port-forward svc/argocd-server 8443:443
      user "admin", password:
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  - Grafana:     kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
  - The app itself is deployed by Argo CD from k8s/overlays/ec2. It stays in
    ImagePullBackOff until the Jenkins pipeline has built and pushed an image.
  - Next: scripts/make-ci-kubeconfig.sh <cp-1 private IP>  (credential for Jenkins)
EOF
