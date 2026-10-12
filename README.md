# Inventorise — DevOps

Everything needed to run the
[inventorise-app](https://github.com/mendilirmak/inventorise-app) on a
self-hosted Kubernetes cluster (k3s) on AWS EC2: infrastructure code, cluster
add-ons, manifests, monitoring and the Jenkins pipeline.

Run every command from **WSL2 (Ubuntu)**, not PowerShell.

## How it fits together

```
you push code ──► Jenkins (CI node): scan secrets, lint, test, build image,
                  scan image, push to Docker Hub, commit the new tag to git
                         │
                         ▼
                  Argo CD sees the commit ──► updates the k3s cluster
                         │
                         ▼
                  Jenkins checks Synced + Healthy, then runs a smoke test
```

| Folder / file | What it is |
|---|---|
| `terraform/` | Creates the network, security groups, instances and public IPs |
| `ansible/` | Configures the nodes: k3s, Postgres replication, NAT, hardening, Jenkins (see `ansible/README.md`) |
| `k8s/base/` | The app: Deployment, Service, Ingress, autoscaler, network rules |
| `k8s/overlays/ec2/` | What is specific to the cluster: external Postgres, TLS-only database connection, HTTPS ingress, image tag |
| `k8s/ec2-addons/` | Helm values and the private CA for ingress-nginx, cert-manager and Argo CD |
| `argocd/` | The Argo CD application, and what Jenkins may do in the cluster |
| `jenkins/` | The Jenkins image (Dockerfile, pinned plugins) and its setup guide |
| `Jenkinsfile` | The 11-stage pipeline |
| `monitoring/` | Prometheus + Grafana settings, ServiceMonitor, the dashboard |
| `scripts/` | Start/stop, bootstrap, secrets, load test, cleanup |
| `docs/` | Architecture decisions (ADRs) and, later, the submitted documents |

## Tools and pinned versions

| Tool | Version | Used for |
|---|---|---|
| Terraform | 1.16.5 (AWS provider 6.68.0) | Infrastructure |
| ansible-core | 2.21.5 (collections pinned in `ansible/requirements.yml`) | Node setup |
| k3s | v1.36.5+k3s1 | Kubernetes |
| kubectl | v1.36.x | Talks to the cluster; also contains kustomize |
| Helm | v4.3.0 | Installs third-party charts only (we write no charts) |
| ingress-nginx chart | 4.15.1 | Public HTTP/HTTPS entry |
| cert-manager | v1.21.2 | Certificates from the private CA |
| Argo CD chart | 10.10.1 | Continuous delivery |
| kube-prometheus-stack chart | 91.9.0 | Prometheus + Grafana |
| Jenkins | 2.580.1-lts-jdk21, plugins in `jenkins/plugins.txt` | CI |

## Build the cluster

Order: `terraform apply` → `ansible-playbook playbooks/site.yml` → open an SSH
tunnel to the Kubernetes API → `scripts/ec2-bootstrap.sh` → Jenkins setup
(`jenkins/README.md`). Read the header of each script for the exact commands.

**Reach the cluster from your machine** (the control plane has no public
address). In one terminal, with your SSH key loaded in the agent:

```bash
ssh -N -L 6443:<cp-1 private IP>:6443 ubuntu@<bastion public IP>
export KUBECONFIG=~/inventorise/inventorise-devops/ansible/.secrets/kubeconfig
kubectl get nodes
```

**Check it works:** all 5 nodes `Ready`; the ingress answers on both workers'
public IPs (`curl -sk -o /dev/null -w '%{http_code}\n' https://<worker IP>/`
returns 404 until the app is deployed); `kubectl get clusterissuer` shows
`inventorise-ca` Ready.

## Cost control

| Script | What it does |
|---|---|
| `scripts/aws-instances.sh status\|start\|stop` | Start or stop all nine instances (stopped = no compute cost) |
| `scripts/aws-shred.sh` | Lists everything billable; `--destroy` deletes it |

Running all nine instances costs about $0.42 an hour. Disks and public IPs
cost about $0.60 a day while stopped. **Stop the instances after every session.**

## Deploy the app

The Jenkins pipeline does it: it builds the image, pushes it to Docker Hub and
commits the new tag to `k8s/overlays/ec2/kustomization.yaml`. Argo CD then
applies it. Do not run `kubectl apply` for the app.

**Check it works:**

```bash
kubectl -n argocd get application inventorise-ec2    # SYNC STATUS Synced, HEALTH STATUS Healthy
kubectl -n inventory get pods                        # app pods Running, 1/1
kubectl -n inventory get hpa app                     # TARGETS shows a CPU %, not <unknown>
```

Create a login for yourself (asks for a password, 12+ characters):
`scripts/create-app-user.sh admin`.

## Autoscaling demo

```bash
kubectl -n inventory get hpa app -w     # terminal 1: watch replicas
scripts/load-test.sh                    # terminal 2: 3 minutes of load
```

Replicas go from 2 up to as many as 5 while the load runs, and back to 2
about 2 minutes after it stops. The autoscaler compares CPU use with the
pod's CPU *request* (100m), which is why the request must be set.

## Monitoring (`monitoring/`)

`scripts/ec2-bootstrap.sh` installs **kube-prometheus-stack** (Prometheus
collects and stores metrics, Grafana shows dashboards) into the `monitoring`
namespace, plus our ServiceMonitor and the "Inventorise app" dashboard.

| File | What it is |
|---|---|
| `monitoring/values.yaml` | Chart settings: no Alertmanager, 2-day retention, Grafana password from a Secret |
| `monitoring/values-ec2.yaml` | Turns off scrapes of control-plane parts k3s does not expose |
| `monitoring/servicemonitor.yaml` | Tells Prometheus to scrape the app's `/metrics` every 15 s |
| `monitoring/inventory-dashboard.json` | The Grafana dashboard |

**Open Grafana:**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# password for user "admin":
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Browse to http://localhost:3000 → Dashboards → **Inventorise app**.

| Panel | Shows |
|---|---|
| Request rate per endpoint | Requests/second per route (health checks excluded) |
| p95 latency per endpoint | 95% of requests are faster than this |
| Error rate (5xx) | Share of requests that failed with a server error |
| Low-stock products | The app's own `inventory_low_stock_products` metric |
| App replicas (autoscaling) | Available pods vs. what the autoscaler wants |
| App pod CPU / memory | Per pod, compared with the requests and limits |

**Check it works:** run `scripts/load-test.sh` — request rate, CPU and then
the replica count rise within a minute or two.

## Postgres failover (manual, a known gap)

Promote the standby (`pg_ctl promote` on `inventorise-pg-2`), then change the
address in `k8s/overlays/ec2/postgres-endpoint.yaml` to its IP and commit.
Argo CD applies it.
