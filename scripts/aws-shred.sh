#!/usr/bin/env bash
# Deletes everything billable that this project created in AWS, then checks
# that nothing is left. Safe to run again.
#
#   scripts/aws-shred.sh              # only LIST what exists (changes nothing)
#   scripts/aws-shred.sh --destroy    # terraform destroy, then check for leftovers
#   scripts/aws-shred.sh --destroy --force
#                                     # also delete leftovers found by tag
#
# How it works
#   1. `terraform destroy` removes everything Terraform manages.
#   2. A second pass looks for anything tagged Project=inventorise that is
#      still alive (for example if the Terraform state was lost, or something
#      was created by hand). It lists the billable kinds:
#        instances, disks (EBS volumes), Elastic IPs, snapshots, AMIs, NAT gateways.
#      With --force it deletes them. Nothing without the tag is ever touched.
#
# Needs: the `inventorise` AWS profile, terraform, and the aws wrapper in PATH.
set -euo pipefail

PROFILE=${AWS_PROFILE:-inventorise}
REGION=${AWS_REGION:-eu-north-1}
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TAG_FILTER="Name=tag:Project,Values=inventorise"

DESTROY=false
FORCE=false
for arg in "$@"; do
  case $arg in
    --destroy) DESTROY=true ;;
    --force) FORCE=true ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

ec2() { aws ec2 "$@" --region "$REGION" --profile "$PROFILE" --output text; }

# Each function prints the IDs of one kind of billable thing, space separated.
list_instances() {
  ec2 describe-instances \
    --filters "$TAG_FILTER" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId'
}
list_volumes()   { ec2 describe-volumes --filters "$TAG_FILTER" --query 'Volumes[].VolumeId'; }
list_eips()      { ec2 describe-addresses --filters "$TAG_FILTER" --query 'Addresses[].AllocationId'; }
list_snapshots() { ec2 describe-snapshots --owner-ids self --filters "$TAG_FILTER" --query 'Snapshots[].SnapshotId'; }
list_images()    { ec2 describe-images --owners self --filters "$TAG_FILTER" --query 'Images[].ImageId'; }
list_nats() {
  ec2 describe-nat-gateways \
    --filter "$TAG_FILTER" Name=state,Values=pending,available \
    --query 'NatGateways[].NatGatewayId'
}

# Prints what is left and returns 0 if nothing billable remains.
report() {
  local found=0 kind ids
  for kind in instances volumes eips snapshots images nats; do
    ids=$(list_"$kind")
    if [[ -n $ids ]]; then
      echo "  $kind: $ids"
      found=1
    else
      echo "  $kind: none"
    fi
  done
  return $found
}

delete_leftovers() {
  local ids
  ids=$(list_instances)
  if [[ -n $ids ]]; then
    echo "Terminating instances: $ids"
    # shellcheck disable=SC2086  # IDs are separate words on purpose
    ec2 terminate-instances --instance-ids $ids >/dev/null
    # shellcheck disable=SC2086
    ec2 wait instance-terminated --instance-ids $ids
  fi
  for ids in $(list_eips); do
    echo "Releasing Elastic IP $ids"
    ec2 release-address --allocation-id "$ids" >/dev/null
  done
  for ids in $(list_nats); do
    echo "Deleting NAT gateway $ids"
    ec2 delete-nat-gateway --nat-gateway-id "$ids" >/dev/null
  done
  for ids in $(list_images); do
    echo "Deregistering image $ids"
    ec2 deregister-image --image-id "$ids" >/dev/null
  done
  for ids in $(list_snapshots); do
    echo "Deleting snapshot $ids"
    ec2 delete-snapshot --snapshot-id "$ids" >/dev/null
  done
  for ids in $(list_volumes); do
    echo "Deleting disk $ids"
    ec2 delete-volume --volume-id "$ids" >/dev/null
  done
}

echo "Account: $(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)  Region: $REGION"

if [[ $DESTROY == true ]]; then
  echo
  echo "This will DELETE the whole project infrastructure (terraform destroy)."
  read -rp "Type DESTROY to continue: " answer
  [[ $answer == DESTROY ]] || { echo "Cancelled."; exit 1; }
  (cd "$REPO_DIR/terraform" && AWS_PROFILE=$PROFILE terraform destroy -input=false -auto-approve)
fi

echo
echo "Billable things still tagged Project=inventorise:"
if report; then
  echo "Nothing billable left."
  exit 0
fi

echo
if [[ $FORCE == true ]]; then
  delete_leftovers
  echo
  echo "Checking again:"
  report && { echo "Nothing billable left."; exit 0; }
  echo "Something is still left. Look in the console." >&2
  exit 1
fi

if [[ $DESTROY == true ]]; then
  echo "Leftovers found. Run again with --destroy --force to delete them." >&2
  exit 1
fi
echo "(List only. Use --destroy to delete.)"
