#!/usr/bin/env bash
# Writes the kubeconfig that Jenkins uses (credential "kubeconfig-ci").
# It logs in as the service account "jenkins-ci" (argocd/ci-access.yaml), which
# can only read Argo CD status and run the smoke-user script.
#
#   scripts/make-ci-kubeconfig.sh <cp-1 private IP>
#
# Needs the SSH tunnel and ansible/.secrets/kubeconfig, as ec2-bootstrap.sh does.
# Writes ansible/.secrets/ci-kubeconfig (git-ignored, mode 600). Upload it to
# Jenkins as a "Secret file" credential with ID kubeconfig-ci, then delete it.
# The token is never printed.
set -euo pipefail

CP_IP=${1:?usage: $0 <cp-1 private IP>}
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
export KUBECONFIG=${KUBECONFIG:-$REPO_DIR/ansible/.secrets/kubeconfig}
OUT=$REPO_DIR/ansible/.secrets/ci-kubeconfig

token=$(kubectl -n inventory get secret jenkins-ci-token -o 'jsonpath={.data.token}' | base64 -d)
ca=$(kubectl -n inventory get secret jenkins-ci-token -o 'jsonpath={.data.ca\.crt}')
if [[ -z $token || -z $ca ]]; then
  echo "The token is not ready yet. Run scripts/ec2-bootstrap.sh first." >&2
  exit 1
fi

# Create the file as private before the token goes into it.
umask 077
cat > "$OUT" <<YAML
apiVersion: v1
kind: Config
clusters:
  - name: inventorise
    cluster:
      server: https://$CP_IP:6443
      certificate-authority-data: $ca
users:
  - name: jenkins-ci
    user:
      token: $token
contexts:
  - name: jenkins-ci
    context: {cluster: inventorise, user: jenkins-ci, namespace: inventory}
current-context: jenkins-ci
YAML
unset token
echo "Written: $OUT"
echo "Upload it to Jenkins as a Secret file credential with ID kubeconfig-ci, then delete it."
