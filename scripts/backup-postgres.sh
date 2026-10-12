#!/usr/bin/env bash
# Copies the inventory database from the Postgres primary to this machine.
# Run it after each working session, and before any risky change to the database.
#
#   scripts/backup-postgres.sh
#
# How it works:
#   1. Finds the primary (inventorise-pg-1) and the bastion, which must be running.
#   2. Runs pg_dump on the primary as the postgres user (local login, no password),
#      through SSH. The dump is in Postgres's custom format.
#   3. Checks the file is a readable dump (pg_restore --list, in a pinned image).
#   4. Keeps the newest 7 copies and deletes older ones.
#
# Files go to backups/ (git-ignored) with mode 600. They are not encrypted, and
# they contain the password hashes, so keep this folder on your own machine only.
#
# Restore (after stopping the app, so nothing writes during the restore):
#   AWS_PROFILE=inventorise terraform -chdir=terraform output -raw bastion_public_ip
#   ssh -J ubuntu@<bastion> ubuntu@<pg-1 private IP> \
#     'sudo -u postgres pg_restore --clean --if-exists --no-owner -d inventory' < backups/<file>.dump
#
# Needs your SSH key in ssh-agent (ssh-add ~/.ssh/id_ed25519).
set -euo pipefail

PROFILE=${AWS_PROFILE:-inventorise}
REGION=${AWS_REGION:-eu-north-1}
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
BACKUP_DIR=$REPO_DIR/backups
KEEP=7
DB_NAME=${DB_NAME:-inventory}
PG_IMAGE=postgres:16.15   # same major version as the server; used only to read the dump

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

ec2() { aws ec2 "$@" --region "$REGION" --profile "$PROFILE" --output text; }

# SSH check: keys must be loaded, or BatchMode makes ssh fail with a clear message.
rc=0
ssh-add -l >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then
  echo "No SSH key in ssh-agent. Run: eval \"\$(ssh-agent -s)\"; ssh-add ~/.ssh/id_ed25519" >&2
  exit 1
fi

primary_ip=$(ec2 describe-instances \
  --filters "Name=tag:Name,Values=inventorise-pg-1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress')
if [[ -z $primary_ip || $primary_ip == None ]]; then
  echo "inventorise-pg-1 is not running. Start the instances first (scripts/aws-instances.sh start)." >&2
  exit 1
fi
bastion=$(terraform -chdir="$REPO_DIR/terraform" output -raw bastion_public_ip)

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
umask 077
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=$BACKUP_DIR/inventory-$stamp.dump
partial=$out.partial
trap 'rm -f "$partial"' EXIT

echo "Dumping $DB_NAME from $primary_ip"
ssh "${SSH_OPTS[@]}" -J "ubuntu@$bastion" "ubuntu@$primary_ip" \
  "sudo -u postgres pg_dump --format=custom --no-owner --dbname=$DB_NAME" > "$partial"

if [[ ! -s $partial ]]; then
  echo "The dump is empty. Nothing saved." >&2
  exit 1
fi

# A dump that cannot be listed is not a usable backup. Fail before keeping it.
docker run --rm -v "$partial:/dump.bin:ro" "$PG_IMAGE" pg_restore --list /dump.bin >/dev/null
mv "$partial" "$out"
echo "Saved $out ($(du -h "$out" | cut -f1))"

# Keep the newest $KEEP copies only.
find "$BACKUP_DIR" -maxdepth 1 -name 'inventory-*.dump' -printf '%T@ %p\n' |
  sort -rn | tail -n +"$((KEEP + 1))" | cut -d' ' -f2- | xargs -r rm -f --
echo "Copies kept: $(find "$BACKUP_DIR" -maxdepth 1 -name 'inventory-*.dump' | wc -l) (newest $KEEP)"
