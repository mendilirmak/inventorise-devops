#!/usr/bin/env bash
# Generates load so the HorizontalPodAutoscaler adds app pods.
#
#   scripts/load-test.sh            # 3 minutes, 50 parallel clients
#   DURATION=5m CONCURRENCY=100 scripts/load-test.sh
#
# Watch it in another terminal:  kubectl -n inventory get hpa app -w
#
# `hey` (an HTTP load generator) runs as a temporary pod INSIDE the cluster
# and sends requests through ingress-nginx, the same path real users take.
# Running it inside avoids the port-forward, which would be the bottleneck.
# It is built from source with a pinned version; Go verifies the download
# against its public checksum database.
set -euo pipefail

DURATION=${DURATION:-3m}
CONCURRENCY=${CONCURRENCY:-50}
HOST=${HOST:-inventory.local}
TARGET=${TARGET:-http://ingress-nginx-controller.ingress-nginx.svc.cluster.local/login}
GO_IMAGE=golang:1.27.1-alpine
HEY_VERSION=v0.1.4

echo "Load: $CONCURRENCY clients for $DURATION -> $TARGET (Host: $HOST)"
# /login needs no account and renders a template, so it costs real CPU.
kubectl run load-test --rm -i --restart=Never \
  --namespace default \
  --image="$GO_IMAGE" \
  --command -- sh -c \
  "go run github.com/rakyll/hey@$HEY_VERSION -z $DURATION -c $CONCURRENCY -host $HOST $TARGET"
