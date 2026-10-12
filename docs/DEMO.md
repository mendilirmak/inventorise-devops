# Demo script

About 15 minutes. Run it from WSL2 with the laptop that trusts the private CA.
Each step says what to show and what to say.

## Before the demo (about 10 minutes, the day before and again on the day)

1. **Start the instances.** Load the SSH key, then:
   ```bash
   eval "$(ssh-agent -s)"; ssh-add ~/.ssh/id_ed25519
   cd ~/inventorise/inventorise-devops
   scripts/aws-instances.sh start
   ```
   Wait for "The cluster is ready". It takes about 3 minutes.
2. **Open the API tunnel** in its own terminal, and keep it open:
   ```bash
   ssh -N -L 6443:10.20.2.88:6443 ubuntu@$(terraform -chdir=terraform output -raw bastion_public_ip)
   ```
3. **Set kubectl** in the working terminal:
   ```bash
   export KUBECONFIG=~/inventorise/inventorise-devops/ansible/.secrets/kubeconfig
   kubectl get nodes          # 5 nodes, all Ready
   ```
4. **Check the site and the data:** open https://inventory.local/health/ready. It should show `{"status":"ok"}` with no warning. Log in and check that the dashboard has about 40 products.
5. **Reset the demo data if needed:** `kubectl -n inventory exec -i deploy/app -c app -- python - < docs/seed-demo-data.py` adds the shop data again, if it's missing. It skips products that already exist.
6. **Save the CA certificate** for the API step, if the file is not there yet:
   ```bash
   mkdir -p ~/inventorise/inventorise-docs
   kubectl -n inventory get configmap inventorise-ca-cert -o jsonpath='{.data.ca\.crt}' > ~/inventorise/inventorise-docs/ca.crt
   ```
7. **Spread the app pods over both workers.** A rolling restart does it, and the
   failover step needs it:
   ```bash
   kubectl -n inventory rollout restart deploy/app
   kubectl -n inventory rollout status deploy/app
   kubectl -n inventory get pods -o wide    # one pod on inventorise-worker-1, one on inventorise-worker-2
   ```
   If both pods are on the same worker, stop the other worker in step 7 of the demo instead.
8. **Open these windows in advance:** the browser on the dashboard, Grafana (see step 7), the Argo CD UI (step 4), the Jenkins job, and a terminal with `kubectl -n inventory get hpa app -w`.

## 1. The idea (1 minute)

"This is an inventory system for a PC-parts shop. What I want to show is not the app, but how the app gets to production and stays there. Everything is code: the servers, the cluster, the deployment and the monitoring."

Show `docs/ARCHITECTURE.md`, and point at the diagram: visitors come through the two workers, the app talks to Postgres, and the admin reaches everything through the bastion.

## 2. Log in and use the app (2 minutes)

1. Open https://inventory.local/login. Log in as the demo user (`<user>`, the name you created in the setup step).
2. **Dashboard:** point out the product table, the shaded low-stock rows, and the stock chart. Say that the chart and the API use the same code (`services.analytics`).
3. **Add a product:** click **New product** in the top bar, enter a name, SKU, price and stock, and save. Show the new row on the dashboard.
4. **Restock:** click **Edit / restock** on that product, add 10 units with a note, and show the stock go up. The restock appears under Recent restocks.
5. **API:** in a terminal, get a token and call the API:
   ```bash
   TOKEN=$(curl -s --cacert ~/inventorise/inventorise-docs/ca.crt \
     -X POST https://inventory.local/api/auth/login \
     -H 'Content-Type: application/json' \
     -d '{"username":"<user>","password":"<password>"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
   curl -s --cacert ~/inventorise/inventorise-docs/ca.crt \
     -H "Authorization: Bearer $TOKEN" https://inventory.local/api/products/low-stock
   ```
   Say: "Without a token the API answers 401. The token is stored only as a hash in the database."

   Create the CA file once, from the cluster, if it isn't there:
   `kubectl -n inventory get configmap inventorise-ca-cert -o jsonpath='{.data.ca\.crt}' > ~/inventorise/inventorise-docs/ca.crt`

## 3. Change the app and run the pipeline (4 minutes)

1. In Jenkins, open the job `inventorise` and click **Build Now**. Show the stages as they run: secret scan, lint, unit tests, build, image scan, push, IaC scan, the tag commit, Argo CD, and the smoke test.
2. While it runs, say: "Jenkins does not touch the cluster. It commits the new image tag to git, and Argo CD applies it."
3. Show the commit in GitHub: the devops repo, `k8s/overlays/ec2/kustomization.yaml`, with the `newTag` line changed.

If the build is still running at the end of the demo, show the finished run from the day before.

## 4. Argo CD sync (2 minutes)

1. Open the Argo CD UI: `kubectl -n argocd port-forward svc/argocd-server 8443:443`, then https://localhost:8443. Log in as `admin`. Get the password with:
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
   ```
2. Show the application `inventorise-ec2`: **Synced** and **Healthy**, with the resource tree.
3. Say: "Git is the source of truth. If someone changes the cluster by hand, Argo CD puts it back."

## 5. Load test and autoscaling (4 minutes)

1. Terminal 1: `kubectl -n inventory get hpa app -w`
2. Terminal 2: `scripts/load-test.sh` (3 minutes, 50 clients through HTTPS).
3. Point out that the replicas go from 2 to 5, and back to 2 about 2 minutes after the load stops.
4. Last tested result: 83,498 requests, all `200`, median 50 ms.

## 6. Grafana (2 minutes)

1. Open Grafana:
   ```bash
   kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
   kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
   ```
2. Log in as `admin` at http://localhost:3000, then open **Inventorise app**.
3. Show the request rate, the p95 latency, the replica count and the CPU during the load test. Say that the app exports these numbers itself (`/metrics`) and Prometheus collects them.

## 7. Worker failure (4 minutes)

1. Check first with `kubectl -n inventory get pods -o wide` that each worker runs a pod. Then say: "I'll switch off one of the two workers. The app should stay up on the other one."
2. Find the instance ID: `aws ec2 describe-instances --profile inventorise --region eu-north-1 --filters Name=tag:Name,Values=inventorise-worker-1 --query 'Reservations[].Instances[].InstanceId' --output text`
3. Stop it: `aws ec2 stop-instances --profile inventorise --region eu-north-1 --instance-ids <id>`
4. Watch the pods and the node: `kubectl get nodes -w` and `kubectl -n inventory get pods -o wide`. The node goes NotReady, and the pods are replaced on the other worker.
5. **Be honest here:** "For about 45 seconds, some requests fail. That's the time before Kubernetes marks the node as gone. It's a known gap, and I've written it up in SECURITY.md."
6. Start the worker again with `scripts/aws-instances.sh start`, and show that all five nodes are Ready.

## 8. Stop everything (1 minute)

```bash
scripts/backup-postgres.sh      # keep a copy of the data
scripts/aws-instances.sh stop
```

Say: "Stopped instances cost almost nothing. The servers, the disks and the data stay."

## If something goes wrong

| Symptom | What to do |
|---|---|
| The browser shows a certificate warning | The CA is not trusted on this laptop. Install it (see the README, "Access to the site"). |
| https://inventory.local does not load | Check the hosts line: `13.63.194.83 inventory.local` (worker-1) or the worker-2 IP. |
| 503 from the site | The app pods are not ready. `kubectl -n inventory get pods`, then `kubectl -n inventory logs deploy/app -c app --tail=50`. |
| Jenkins build fails at the smoke test | The `smoke-user` password is too short, or the user is missing. Re-run `scripts/create-app-user.sh smoke` with a 12+ character password. |
| Argo CD shows OutOfSync | Click **Refresh**, or run `kubectl -n argocd annotate application inventorise-ec2 argocd.argoproj.io/refresh=hard --overwrite`. |
| Cannot reach the cluster | The tunnel is closed, or the bastion IP has changed. Re-open the tunnel. |
| Login fails for the demo user | Re-run `scripts/create-app-user.sh <name>` with a new password. |
