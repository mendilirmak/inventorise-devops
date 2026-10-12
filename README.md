# Inventorise — DevOps

Infrastructure, cluster setup, deployment and CI/CD for the
[inventorise-app](https://github.com/mendilirmak/inventorise-app). It runs on a
self-hosted Kubernetes cluster (k3s) on AWS EC2.

Run every command from **WSL2 (Ubuntu)**, not PowerShell.

## Status

| Part | State |
|---|---|
| AWS infrastructure (Terraform, Ansible) | Built. A repeat Ansible run changes nothing |
| Cluster, private CA, Argo CD, monitoring | Installed and healthy |
| Jenkins pipeline (11 stages) | Green. Deploys, then checks the live site |
| Autoscaling | Tested: 2 → 5 → 2 under load, all requests returned 200 |
| Worker failure | Being tested |
| Docs (architecture, demo, security) | Not written yet |

## How it works

```
push to app repo ──► Jenkins (CI node): scan, test, build, scan image,
                     push to Docker Hub, commit the new image tag to git
                              │
                              ▼
                     Argo CD syncs the cluster from git
                              │
                              ▼
                     Jenkins waits for Synced + Healthy, then runs a smoke test
```

Git is the source of truth. Jenkins never runs `kubectl apply` for the app.

| Folder / file | What it is |
|---|---|
| `terraform/` | Network, security groups, the 9 instances, Elastic IPs |
| `ansible/` | Node setup: k3s, Postgres replication, NAT bastion, Jenkins image (see `ansible/README.md`) |
| `k8s/base/` | The app: Deployment, Service, Ingress, autoscaler, network rules |
| `k8s/overlays/ec2/` | What is specific to the cluster: external Postgres, TLS to the database, HTTPS, the image tag |
| `k8s/ec2-addons/` | Helm values for ingress-nginx, cert-manager and Argo CD, and the private CA |
| `argocd/` | The Argo CD application, and the Jenkins service account's permissions |
| `jenkins/` | Jenkins image, pinned plugins, and setup steps (`jenkins/README.md`) |
| `Jenkinsfile` | The 11-stage pipeline |
| `monitoring/` | Prometheus and Grafana settings, the ServiceMonitor, the dashboard |
| `scripts/` | Start and stop, bootstrap, backups, the load test, and helpers |
| `docs/adr/` | Architecture decisions (ADRs) |

## Pinned versions

| Tool | Version |
|---|---|
| Terraform / AWS provider | 1.16.5 / 6.68.0 |
| ansible-core | 2.21.5 (collections in `ansible/requirements.yml`) |
| k3s | v1.36.5+k3s1 |
| kubectl | v1.36.1 |
| Helm | v4.3.0 |
| ingress-nginx / cert-manager / Argo CD | chart 4.15.1 / v1.21.2 / chart 10.10.1 |
| kube-prometheus-stack | chart 91.9.0 |
| Jenkins | 2.580.1-lts-jdk21 (plugins in `jenkins/plugins.txt`) |

## Daily use

**1. Start the instances** (load your SSH key first; see below):

```bash
scripts/aws-instances.sh start      # bastion, Postgres, control plane, workers, CI
```

It waits until every node answers SSH and all 5 cluster nodes are `Ready`.

**2. Open the Kubernetes API tunnel** (keep this terminal open):

```bash
BASTION=$(terraform -chdir=terraform output -raw bastion_public_ip)
ssh -N -L 6443:10.20.2.88:6443 ubuntu@$BASTION
```

**3. Use kubectl** (in a second terminal):

```bash
export KUBECONFIG=~/inventorise/inventorise-devops/ansible/.secrets/kubeconfig
kubectl get nodes
kubectl -n argocd get application inventorise-ec2    # Synced, Healthy
```

**4. Stop when you finish** (this saves most of the cost):

```bash
scripts/backup-postgres.sh          # copy the database to backups/
scripts/aws-instances.sh stop
```

**SSH key:** the scripts check ssh-agent. Load the key with
`eval "$(ssh-agent -s)"; ssh-add ~/.ssh/id_ed25519`.

**Cost:** all nine instances run at about $0.42 an hour. Stopped instances still
cost about $0.60 a day for disks and public IPs.

## Deploy

Push to the app repo, then run the Jenkins job (`inventorise`, **Build Now**).
Jenkins builds the image, pushes it, commits the new tag to
`k8s/overlays/ec2/kustomization.yaml`, and waits for Argo CD. The smoke test then
logs in over HTTPS.

Create an app user by hand (asks for a password of 12+ characters):

```bash
scripts/create-app-user.sh admin
```

## Load test and autoscaling

```bash
kubectl -n inventory get hpa app -w     # terminal 1: watch replicas
scripts/load-test.sh                    # terminal 2: 3 minutes, 50 clients
```

The autoscaler runs 2 to 5 pods at 60% of the CPU request (100 m). It scales
down after a 2-minute quiet period.

## Monitoring

Prometheus and Grafana run in the `monitoring` namespace. Open Grafana:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Log in as `admin` at http://localhost:3000, then open **Inventorise app**. It has
seven panels: request rate, p95 latency, 5xx errors, low-stock products, replica
count, pod CPU, and pod memory.

## Access to the site

The site is HTTPS only, with a certificate from our private CA. A browser does
not trust that CA by default. The install steps for the demo machine are in the
notes (`inventorise-docs/STATUS.md`) and will move to `docs/` in Phase 6.

## Known gaps

These are listed for SECURITY.md:
- The Postgres failover is manual. Promote the standby, then change
  `k8s/overlays/ec2/postgres-endpoint.yaml` and commit.
- There is no WAL archiving. The recovery point is the last `backup-postgres.sh` run.
- The private CA shows a browser warning on machines that do not trust it.
- ingress-nginx is retired upstream and gets no more security fixes.
- The cluster has one availability zone, and the node count is fixed.
- The Jenkins service account can run commands in the app pods (`argocd/ci-access.yaml`).

## Recovery

- **Stop, then start later:** the same commands as above. Nothing is lost.
- **Restore the database:** the steps are in the header of `scripts/backup-postgres.sh`.
- **Rebuild everything:** `terraform destroy`, then Terraform apply, Ansible,
  `ec2-bootstrap.sh` and the Jenkins setup. About 30 minutes, plus the first
  pipeline run.
