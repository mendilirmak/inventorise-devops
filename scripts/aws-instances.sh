#!/usr/bin/env bash
# Start, stop or show the project's EC2 instances (everything tagged
# Project=inventorise). Stopped instances cost nothing for compute; disks and
# the public IP addresses still cost a little.
#
#   scripts/aws-instances.sh status
#   scripts/aws-instances.sh start     # starts all, waits until running
#   scripts/aws-instances.sh stop      # stops all, waits until stopped
set -euo pipefail

PROFILE=${AWS_PROFILE:-inventorise}
REGION=${AWS_REGION:-eu-north-1}
ACTION=${1:-status}

ec2() { aws ec2 "$@" --region "$REGION" --profile "$PROFILE" --output text; }

ids_in_states() {
  ec2 describe-instances \
    --filters "Name=tag:Project,Values=inventorise" "Name=instance-state-name,Values=$1" \
    --query 'Reservations[].Instances[].InstanceId'
}

case $ACTION in
  status)
    ec2 describe-instances --filters "Name=tag:Project,Values=inventorise" \
      --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,State.Name,PrivateIpAddress]' |
      sort
    ;;
  start)
    ids=$(ids_in_states stopped)
    if [[ -z $ids ]]; then echo "Nothing to start."; exit 0; fi
    # shellcheck disable=SC2086  # IDs are separate words on purpose
    ec2 start-instances --instance-ids $ids >/dev/null
    # shellcheck disable=SC2086
    ec2 wait instance-running --instance-ids $ids
    echo "Started. Give the nodes about a minute to finish booting."
    ;;
  stop)
    ids=$(ids_in_states pending,running)
    if [[ -z $ids ]]; then echo "Nothing to stop."; exit 0; fi
    # shellcheck disable=SC2086
    ec2 stop-instances --instance-ids $ids >/dev/null
    # shellcheck disable=SC2086
    ec2 wait instance-stopped --instance-ids $ids
    echo "Stopped."
    ;;
  *)
    echo "Usage: $0 status|start|stop" >&2
    exit 2
    ;;
esac
