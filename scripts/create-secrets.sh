#!/usr/bin/env bash
# Minikube only: creates the two Secrets the app needs.
#   inventory-db  : POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
#   inventory-app : SECRET_KEY
# Values come from these env vars if set, otherwise strong random values
# are generated. Nothing is printed.
#
# An existing Secret is left alone: Postgres only reads its password when
# the database is first created, so changing it later would lock the app
# out. To start over: kubectl delete namespace inventory (deletes the data).
#
# On EKS the same Secrets come from AWS Secrets Manager instead (Phase 5).
set -euo pipefail

NAMESPACE=inventory

random_hex() { python3 -c "import secrets; print(secrets.token_hex($1))"; }

POSTGRES_USER=${POSTGRES_USER:-inventory}
POSTGRES_DB=${POSTGRES_DB:-inventory}
# Hex only: the password is placed inside DATABASE_URL, where characters
# like @ : / would break it.
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-$(random_hex 24)}
SECRET_KEY=${SECRET_KEY:-$(random_hex 32)}

if [[ ! $POSTGRES_PASSWORD =~ ^[A-Za-z0-9]+$ ]]; then
  echo "POSTGRES_PASSWORD may only contain letters and digits" >&2
  exit 1
fi
if (( ${#SECRET_KEY} < 32 )); then
  echo "SECRET_KEY must be at least 32 characters" >&2
  exit 1
fi

# The namespace comes from the same file the manifests use, so it has its
# Pod Security labels from the start.
kubectl apply -f "$(dirname "$0")/../k8s/base/namespace.yaml"

create_secret() {
  local name=$1 env_file=$2
  if kubectl -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    echo "secret/$name already exists - left unchanged"
    return
  fi
  # Values are passed through a file descriptor (<(...)), not as command-line
  # arguments, so they never appear in the process list.
  kubectl -n "$NAMESPACE" create secret generic "$name" --from-env-file="$env_file"
}

create_secret inventory-db <(printf 'POSTGRES_USER=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=%s\n' \
  "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$POSTGRES_DB")
create_secret inventory-app <(printf 'SECRET_KEY=%s\n' "$SECRET_KEY")
