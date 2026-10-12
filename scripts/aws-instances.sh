#!/usr/bin/env bash
# Starts, stops or shows the project's EC2 instances (everything tagged
# Project=inventorise), in dependency order. Stopped instances cost nothing for
# compute; disks and Elastic IPs still cost a little.
#
#   scripts/aws-instances.sh status
#   scripts/aws-instances.sh start    # bastion, Postgres, control plane, workers, CI
#   scripts/aws-instances.sh stop     # the same groups in reverse order
#
# Start order matters: private nodes reach the internet through the bastion
# (NAT), and the cluster needs its database. "start" waits for SSH on each group
# and, at the end, for every cluster node to report Ready.
#
# The checks use SSH, so load your key first:  ssh-add ~/.ssh/id_ed25519
#
# EXCLUDE (names, comma-separated) leaves instances out. Keep it for the case
# where the vCPU quota is lowered again:
#   EXCLUDE=inventorise-worker-2 scripts/aws-instances.sh start
set -euo pipefail

PROFILE=${AWS_PROFILE:-inventorise}
REGION=${AWS_REGION:-eu-north-1}
ACTION=${1:-status}
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
EXCLUDE=${EXCLUDE:-}

# Roles (the Role tag set by Terraform), in the order they start.
START_ORDER=(bastion postgres control-plane worker ci)
STOP_ORDER=(ci worker control-plane postgres bastion)

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

ec2() { aws ec2 "$@" --region "$REGION" --profile "$PROFILE" --output text; }

# The JMESPath query uses backticks inside single quotes on purpose.
# shellcheck disable=SC2016
# Prints "name<TAB>instance-id<TAB>private-ip" for each instance of a role in
# the given states, sorted by name and minus any EXCLUDE names.
instances_of() {
  ec2 describe-instances \
    --filters "Name=tag:Project,Values=inventorise" "Name=tag:Role,Values=$1" \
              "Name=instance-state-name,Values=$2" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,PrivateIpAddress]' |
    sort | awk -v skip=",$EXCLUDE," 'index(skip, "," $1 ",") == 0'
}

# Space-separated instance IDs from instances_of output on stdin.
ids_only() { awk '{ printf "%s ", $2 }'; }

# Runs a check until it succeeds or the time limit passes.
retry() {  # <what> <seconds> <command...>
  local what=$1 limit=$2
  shift 2
  local end=$((SECONDS + limit))
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS >= end )); then
      echo "  timed out waiting for: $what" >&2
      return 1
    fi
    sleep 10
  done
  echo "  ready: $what"
}

BASTION=""
# SSH to a node. Private nodes are reached through the bastion (ProxyJump).
ssh_node() {  # <ip> <command...>
  local ip=$1
  shift
  if [[ $ip == "$BASTION" ]]; then
    # The command words are meant to be sent to the remote shell as they are.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "ubuntu@$ip" "$@"
  else
    ssh "${SSH_OPTS[@]}" -J "ubuntu@$BASTION" "ubuntu@$ip" "$@"
  fi
}

check_ssh_agent() {
  # ssh-add -l: 0 = keys loaded, 1 = agent running but empty, 2 = no agent.
  local rc=0
  ssh-add -l >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )); then
    echo "No SSH key in ssh-agent (ssh-add -l gave status $rc)." >&2
    echo "Run: eval \"\$(ssh-agent -s)\"; ssh-add ~/.ssh/id_ed25519" >&2
    exit 1
  fi
}

status() {
  # shellcheck disable=SC2016  # JMESPath backticks, not shell expansion
  ec2 describe-instances --filters "Name=tag:Project,Values=inventorise" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,State.Name,PrivateIpAddress]' |
    sort
}

start() {
  check_ssh_agent
  BASTION=$(terraform -chdir="$REPO_DIR/terraform" output -raw bastion_public_ip)
  local expected_nodes=0

  for role in "${START_ORDER[@]}"; do
    local stopped ids
    stopped=$(instances_of "$role" stopped)
    if [[ -n $stopped ]]; then
      ids=$(ids_only <<<"$stopped")
      echo "Starting $role: $ids"
      # shellcheck disable=SC2086  # IDs are separate words on purpose
      ec2 start-instances --instance-ids $ids >/dev/null
      # shellcheck disable=SC2086
      ec2 wait instance-running --instance-ids $ids
    fi

    # Every instance of this role must answer SSH before the next group starts.
    while IFS=$'\t' read -r name _ ip; do
      [[ -n $name ]] || continue
      if [[ $role == bastion ]]; then
        ip=$BASTION
      fi
      retry "SSH to $name" 300 ssh_node "$ip" true || exit 1
    done < <(instances_of "$role" running)

    if [[ $role == control-plane || $role == worker ]]; then
      expected_nodes=$((expected_nodes + $(instances_of "$role" running | wc -l)))
    fi
  done

  # The cluster is ready when every control-plane and worker node is Ready.
  local cp1
  cp1=$(instances_of control-plane running | sed -n 1p | cut -f3)
  nodes_ready() {
    ssh_node "$cp1" "sudo k3s kubectl get nodes --no-headers | grep -c -w Ready || true" |
      awk -v want="$expected_nodes" '$1 == want { ok = 1 } END { exit !ok }'
  }
  retry "$expected_nodes Kubernetes nodes Ready" 600 nodes_ready || exit 1
  echo "Started. The cluster is ready. Open the tunnel to use kubectl (see devops README)."
}

stop() {
  check_ssh_agent
  for role in "${STOP_ORDER[@]}"; do
    local running ids
    running=$(instances_of "$role" "pending,running")
    if [[ -n $running ]]; then
      ids=$(ids_only <<<"$running")
      echo "Stopping $role: $ids"
      # shellcheck disable=SC2086
      ec2 stop-instances --instance-ids $ids >/dev/null
      # shellcheck disable=SC2086
      ec2 wait instance-stopped --instance-ids $ids
    fi
  done
  echo "Stopped."
}

case $ACTION in
  status) status ;;
  start)  start ;;
  stop)   stop ;;
  *)
    echo "Usage: $0 status|start|stop" >&2
    exit 2
    ;;
esac
