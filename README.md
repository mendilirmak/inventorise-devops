# Inventorise — DevOps

Everything needed to run the
[inventorise-app](https://github.com/mendilirmak/inventorise-app) on
Kubernetes: manifests, scripts, and (in later phases) monitoring, the
Jenkins pipeline, Terraform for AWS EKS and the project documentation.

Run every command from **WSL2 (Ubuntu)**, not PowerShell.

## Tools and pinned versions

| Tool | Version | Why pinned here |
|---|---|---|
| kubectl | v1.36.x | Talks to the cluster; also contains kustomize |
| minikube | v1.39.0 | Local single-node cluster |
| Kubernetes (on Minikube) | v1.36.4 | Same minor version as kubectl and the planned EKS cluster |
| Helm | v4.3.0 | Installs third-party charts (we write no charts ourselves) |
| ingress-nginx chart | 4.15.1 | Routes outside HTTP traffic to the app |

minikube and Helm are installed as checksum-verified binaries in
`~/.local/bin` (no sudo needed):

```bash
cd /tmp
curl -fsSLO https://github.com/kubernetes/minikube/releases/download/v1.39.0/minikube-linux-amd64
curl -fsSLO https://github.com/kubernetes/minikube/releases/download/v1.39.0/minikube-linux-amd64.sha256
echo "$(cat minikube-linux-amd64.sha256)  minikube-linux-amd64" | sha256sum -c -
install -D -m 0755 minikube-linux-amd64 ~/.local/bin/minikube

curl -fsSLO https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz
curl -fsSLO https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz.sha256sum
sha256sum -c helm-v4.3.0-linux-amd64.tar.gz.sha256sum
tar -xzf helm-v4.3.0-linux-amd64.tar.gz linux-amd64/helm
install -m 0755 linux-amd64/helm ~/.local/bin/helm
source ~/.profile   # puts ~/.local/bin on PATH
```

## Kubernetes manifests (`k8s/`)

We use **kustomize** (built into kubectl): one `base/` with everything
shared, and one small overlay per environment with only the differences.

| File | What it is |
|---|---|
| `base/namespace.yaml` | Namespace `inventory`, with Pod Security "restricted" enforced |
| `base/configmap.yaml` | `APP_ENV`, `LOW_STOCK_THRESHOLD`, `LOG_LEVEL` |
| `base/secret.example.yaml` | Shape of the two Secrets. Example only, never applied |
| `base/postgres-statefulset.yaml` | Postgres 16, 1 replica, 1 Gi persistent disk, headless Service |
| `base/app-deployment.yaml` | The app: probes, CPU/memory limits, non-root, read-only filesystem |
| `base/app-service.yaml` | In-cluster address `app.inventory.svc` |
| `base/ingress.yaml` | `http://inventory.local/` → app (ingress-nginx) |
| `base/app-hpa.yaml` | Autoscaler: 2–5 app pods, target 60% CPU |
| `base/networkpolicy.yaml` | Only app pods may connect to Postgres |
| `overlays/minikube/` | `APP_ENV=dev` (no TLS locally), storage class `standard` |

The app needs two Secrets: `inventory-db` (`POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_DB`) and `inventory-app` (`SECRET_KEY`).
They are never committed. On Minikube `scripts/create-secrets.sh` creates
them with random values; on EKS they will come from AWS Secrets Manager.

## Run on Minikube

```bash
scripts/minikube-up.sh               # ~5 min the first time
scripts/create-app-user.sh admin     # asks for a password (min 12 chars)
```

`minikube-up.sh` starts Minikube, enables metrics-server, installs
ingress-nginx, creates the Secrets, builds the app image **inside**
Minikube (tagged with the app repo's commit, never `latest`) and applies
the overlay. It expects the app repo next to this one, or
`APP_DIR=/path/to/inventorise-app`.

To open the app in the Windows browser:

1. In a separate terminal, keep this running:
   `kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80`
2. Add `127.0.0.1 inventory.local` to
   `C:\Windows\System32\drivers\etc\hosts` (edit as administrator).
3. Browse to http://inventory.local:8080

**Check it works:**

```bash
kubectl -n inventory get pods                 # app x2 and postgres-0: Running, READY 1/1
kubectl -n inventory get hpa app              # TARGETS shows a CPU %, not <unknown>
curl -s -H 'Host: inventory.local' localhost:8080/health/ready   # {"status":"ok"} (with port-forward)
```

**Data survives a restart:** create a product, then
`kubectl -n inventory delete pod postgres-0`. The pod comes back with the
same disk, so the product is still there.

## Autoscaling demo

```bash
kubectl -n inventory get hpa app -w     # terminal 1: watch replicas
scripts/load-test.sh                    # terminal 2: 3 minutes of load
```

Replicas go from 2 up to as many as 5 while the load runs, and back to 2
about 2 minutes after it stops. The autoscaler compares CPU use with the
pod's CPU *request* (100m), which is why the request must be set.

## Monitoring (`monitoring/`)

**kube-prometheus-stack** (Helm chart 91.9.0) installs Prometheus (collects
and stores metrics), Grafana (dashboards) and the exporters that report pod
CPU, memory and replica counts. It goes into the `monitoring` namespace,
the only namespace besides ingress-nginx that the app's NetworkPolicy lets
in.

| File | What it is |
|---|---|
| `monitoring/values.yaml` | Our chart settings: no Alertmanager, 2-day retention, Grafana password from a Secret |
| `monitoring/servicemonitor.yaml` | Tells Prometheus to scrape the app's `/metrics` every 15 s |
| `monitoring/inventory-dashboard.json` | The "Inventorise app" Grafana dashboard |
| `monitoring/kustomization.yaml` | Applies the ServiceMonitor and turns the dashboard into a ConfigMap |

```bash
scripts/monitoring-up.sh      # after minikube-up.sh; ~3-5 min
```

The script creates the Secret `grafana-admin` with a random password (never
stored in a file), installs the chart, then applies `monitoring/`.
Grafana loads the dashboard automatically from the ConfigMap labelled
`grafana_dashboard: "1"`.

**Open Grafana:**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# password for user "admin":
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Browse to http://localhost:3000 → Dashboards → **Inventorise app**.
To import it by hand instead (e.g. into another Grafana): Dashboards →
New → Import → upload `monitoring/inventory-dashboard.json` → pick the
Prometheus data source.

| Panel | Shows |
|---|---|
| Request rate per endpoint | Requests/second per route (health checks excluded) |
| p95 latency per endpoint | 95% of requests are faster than this |
| Error rate (5xx) | Share of requests that failed with a server error |
| Low-stock products | The app's own `inventory_low_stock_products` metric |
| App replicas (autoscaling) | Available pods vs. what the autoscaler wants |
| App pod CPU / memory | Per pod, compared with the requests and limits |

**Check it works:** run `scripts/load-test.sh` — request rate, CPU and
then the replica count rise within a minute or two.

## EC2 cluster (production-style demo)

The demo target is a k3s cluster on nine EC2 instances in eu-north-1: a
bastion, three control-plane nodes, two workers, two Postgres nodes (primary
and standby) and a CI node. Everything is in code:

| Folder / script | What it does |
|---|---|
| `terraform/` | Creates the network, security groups, instances and public IPs |
| `ansible/` | Configures the nodes: k3s, Postgres replication, NAT, hardening (see `ansible/README.md`) |
| `scripts/aws-instances.sh` | `start`, `stop`, `status` for all instances (stopped = no compute cost) |
| `scripts/aws-shred.sh` | Deletes everything billable (`--destroy`), or just lists it |
| `scripts/ec2-bootstrap.sh` | Installs ingress-nginx, cert-manager + private CA, Argo CD, monitoring and the app Secrets |
| `k8s/overlays/ec2/` | The app for EC2: external Postgres, TLS-only database connection, HTTPS ingress |
| `k8s/ec2-addons/` | Helm values and the private CA for the add-ons above |

Order: `terraform apply` → `ansible-playbook playbooks/site.yml` → open an SSH
tunnel to the Kubernetes API → `scripts/ec2-bootstrap.sh`. Read the header of
each script for the exact commands.

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

**Postgres failover (manual):** promote the standby (`pg_ctl promote` on
`inventorise-pg-2`), then change the address in
`k8s/overlays/ec2/postgres-endpoint.yaml` to its IP and apply the overlay.

## Start over / stop

```bash
minikube stop                            # pause; everything is kept
kubectl delete namespace inventory       # delete the app AND its data
minikube delete                          # delete the whole cluster
```
