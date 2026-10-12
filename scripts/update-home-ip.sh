#!/usr/bin/env bash
# Updates the one firewall rule that lets your home IP reach the bastion over
# SSH. Everything else (the Kubernetes API, the private nodes) is reached
# through the bastion, so it follows this rule automatically.
# Run it after your home IP changes.
#
#   scripts/update-home-ip.sh --check    # show the current and new IP, change nothing
#   scripts/update-home-ip.sh            # update the rule
#
# How it works:
#   1. Reads your public IPv4 address from checkip.amazonaws.com (HTTPS).
#   2. Runs `terraform apply` for that one rule, with the new address.
#   3. Only after the apply succeeds, writes the address to terraform/terraform.tfvars
#      (git-ignored), so the next full `terraform plan` shows no changes.
#
# Fails closed: if the address cannot be read or is not a valid IPv4 address,
# nothing changes. The rule is never opened to 0.0.0.0/0.
set -euo pipefail

PROFILE=${AWS_PROFILE:-inventorise}
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TF_DIR=$REPO_DIR/terraform
TFVARS=$TF_DIR/terraform.tfvars
RULE=aws_vpc_security_group_ingress_rule.bastion_ssh_admin

CHECK_ONLY=false
case ${1:-} in
  --check) CHECK_ONLY=true ;;
  "") ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

valid_ipv4() {
  local ip=$1 octet
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

ip=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]') || {
  echo "Could not read your public IP address. Nothing changed." >&2
  exit 1
}
if ! valid_ipv4 "$ip"; then
  echo "checkip.amazonaws.com returned something that is not an IPv4 address. Nothing changed." >&2
  exit 1
fi
wanted="$ip/32"

current=$(grep -E '^admin_cidr' "$TFVARS" | sed -E 's/^[^"]*"([^"]+)".*/\1/') || true
if [[ -z $current ]]; then
  echo "No admin_cidr line in $TFVARS. Add one, then run this again. Nothing changed." >&2
  exit 1
fi

if [[ $current == "$wanted" ]]; then
  echo "The SSH rule already allows $wanted. Nothing to do."
  exit 0
fi

echo "Your IP is now $wanted; the rule allows $current."
if [[ $CHECK_ONLY == true ]]; then
  echo "Run without --check to update the rule."
  exit 0
fi

# -var overrides the tfvars file for this run only. The tfvars file is written
# after the apply succeeds, so a failed run can simply be repeated.
AWS_PROFILE=$PROFILE terraform -chdir="$TF_DIR" apply \
  -target="$RULE" -var "admin_cidr=$wanted"

sed -i -E "s|^admin_cidr[[:space:]]*=.*|admin_cidr = \"$wanted\"|" "$TFVARS"
echo "Done: the SSH rule now allows $wanted."
echo "Check with: AWS_PROFILE=$PROFILE terraform -chdir=terraform plan   (should show no changes)"
