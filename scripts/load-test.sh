#!/usr/bin/env bash
# Generates load so the HorizontalPodAutoscaler adds app pods.
#
#   scripts/load-test.sh            # 3 minutes, 50 parallel clients
#   DURATION=5m CONCURRENCY=100 scripts/load-test.sh
#
# Watch it in another terminal:  kubectl -n inventory get hpa app -w
#
# `hey` (an HTTP load generator) runs as a temporary pod inside the cluster.
# It sends requests through ingress-nginx over HTTPS, the same path real users
# take. Running inside the cluster avoids a port-forward, which would be the
# bottleneck. hey is built from source at a pinned version; Go checks the
# download against its public checksum database.
set -euo pipefail

DURATION=${DURATION:-3m}
CONCURRENCY=${CONCURRENCY:-50}
HOST=${HOST:-inventory.local}
TARGET=${TARGET:-https://$HOST/login}
GO_IMAGE=golang:1.27.1-alpine
HEY_VERSION=v0.1.4

# The site is HTTPS only (plain HTTP redirects), and its certificate comes from
# our private CA. So the load pod:
#  - runs in the `inventory` namespace, to read the public CA certificate from
#    the ConfigMap `inventorise-ca-cert` and trust it (SSL_CERT_FILE);
#  - maps the name inventory.local to the ingress controller's cluster address
#    (hostAliases), so the certificate name matches;
#  - runs with the same restricted security settings as the app.
ingress_ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o 'jsonpath={.spec.clusterIP}')
overrides=$(cat <<JSON
{"spec": {
  "hostAliases": [{"ip": "$ingress_ip", "hostnames": ["$HOST"]}],
  "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
  "volumes": [{"name": "ca", "configMap": {"name": "inventorise-ca-cert"}}],
  "containers": [{
    "name": "load-test",
    "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
    "env": [
      {"name": "SSL_CERT_FILE", "value": "/ca/ca.crt"},
      {"name": "HOME", "value": "/tmp"},
      {"name": "GOPATH", "value": "/tmp/go"},
      {"name": "GOCACHE", "value": "/tmp/go-cache"}
    ],
    "volumeMounts": [{"name": "ca", "mountPath": "/ca", "readOnly": true}]
  }]
}}
JSON
)

echo "Load: $CONCURRENCY clients for $DURATION -> $TARGET"
# /login needs no account and renders a template, so it costs real CPU.
kubectl run load-test --rm -i --restart=Never \
  --namespace inventory \
  --image="$GO_IMAGE" \
  --overrides="$overrides" \
  --command -- sh -c \
  "go run github.com/rakyll/hey@$HEY_VERSION -z $DURATION -c $CONCURRENCY $TARGET"
