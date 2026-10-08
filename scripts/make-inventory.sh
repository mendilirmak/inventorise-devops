#!/usr/bin/env bash
# Builds ansible/inventory.ini from the Terraform outputs. Run it after every
# `terraform apply` (the file is git-ignored; it only holds IP addresses).
#
#   scripts/make-inventory.sh
#
# Private nodes are reached through the bastion with SSH ProxyJump, so only
# the bastion needs a public SSH port.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUT=$REPO_DIR/ansible/inventory.ini
TF_JSON=$(cd "$REPO_DIR/terraform" && terraform output -json)

TF_JSON=$TF_JSON python3 - > "$OUT" <<'PY'
import json
import os

outputs = {k: v["value"] for k, v in json.loads(os.environ["TF_JSON"]).items()}
bastion = outputs["bastion_public_ip"]


def hosts(prefix, ips):
    return [f"inventorise-{prefix}-{i + 1} ansible_host={ip}" for i, ip in enumerate(ips)]


lines = ["[bastion]", f"inventorise-bastion ansible_host={bastion}", ""]
for group, prefix, key in [
    ("control_plane", "cp", "control_plane_private_ips"),
    ("workers", "worker", "worker_private_ips"),
    ("postgres", "pg", "postgres_private_ips"),
]:
    lines += [f"[{group}]"] + hosts(prefix, outputs.get(key) or []) + [""]
lines += ["[ci]", "inventorise-ci ansible_host=" + outputs["ci_private_ip"], ""]
lines += [
    "[private:children]", "control_plane", "workers", "postgres", "ci", "",
    "[private:vars]",
    f"ansible_ssh_common_args=-o ProxyJump=ubuntu@{bastion} -o StrictHostKeyChecking=accept-new",
    "",
    "[bastion:vars]",
    "ansible_ssh_common_args=-o StrictHostKeyChecking=accept-new",
    "",
]
print("\n".join(lines))
PY

echo "Wrote $OUT ($(grep -c ansible_host "$OUT") hosts)"
