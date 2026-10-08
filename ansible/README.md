# Ansible — configure the EC2 nodes

Ansible logs in to each instance over SSH and sets it up. It runs from your
WSL machine; nothing is installed on the nodes beforehand except what Ubuntu
ships. Private nodes are reached **through the bastion** (SSH ProxyJump).

## What each role does

| Role | Hosts | What it does |
|---|---|---|
| `common` | all | hostname, packages, automatic security updates, SSH hardening (keys only, no root) |
| `bastion` | bastion | turns on IP forwarding and an nftables NAT rule, so private nodes can reach the internet |
| `postgres` | pg-1, pg-2 | PostgreSQL 16, TLS-only connections with SCRAM passwords; pg-1 is the primary, pg-2 copies it and runs as a standby |
| `k3s_server` | cp-1..3 | k3s control plane with embedded etcd (HA), Secrets encrypted in etcd, Traefik off, no app pods |
| `k3s_agent` | workers | k3s worker nodes, labelled for the ingress |
| `ci` | ci | installs Docker. Jenkins comes in Phase 5 |

The k3s binary is downloaded from the pinned release and checked against its
published SHA-256. No `curl | sh` installer is used.

## Run it

```bash
cd ~/inventorise/inventorise-devops

# 1. Unlock your SSH key once for this terminal
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519

# 2. Start the instances and build the inventory from Terraform's outputs
export PATH=$HOME/.local/bin:$PATH
scripts/aws-instances.sh start
scripts/make-inventory.sh

# The account allows 20 running vCPUs, enough for all 9 instances (18). If a
# start ever fails with VcpuLimitExceeded, leave one out:
#   EXCLUDE=inventorise-worker-2 scripts/aws-instances.sh start
#   EXCLUDE=inventorise-worker-2 scripts/make-inventory.sh

# 3. Install the pinned collections once, then run the playbook
cd ansible
ansible-galaxy collection install -r requirements.yml -p collections
ansible-playbook playbooks/site.yml
```

Running it again is safe: it only changes what is different.

## Secrets

Random passwords (k3s token, Postgres app and replication users) are created
on the first run into `ansible/.secrets/` and reused afterwards. That folder
is git-ignored. The playbook also saves the cluster's `kubeconfig` there.

## Check it works

```bash
ansible all -m ping                                    # every host answers "pong"
ssh -J ubuntu@<bastion-ip> ubuntu@<cp-1-ip> 'sudo k3s kubectl get nodes'
#   all control-plane (and worker) nodes: Ready
ssh -J ubuntu@<bastion-ip> ubuntu@<pg-1-ip> \
  'sudo -u postgres psql -c "select client_addr, state from pg_stat_replication"'
#   shows pg-2 as "streaming"
```

## Known gaps (also in docs/SECURITY.md)

- Workers join through control-plane node cp-1 only. If cp-1 is down, new
  workers cannot join until it is back (existing nodes keep working). A load
  balancer in front of the three servers is the production fix.
- Postgres failover is manual: promote pg-2 with `pg_ctl promote` and point
  the app at it.
- Everything runs in one availability zone.
