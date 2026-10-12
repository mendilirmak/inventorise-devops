# Security

This document lists what the system does to stay secure, and what it does not
do yet. Each known gap says what we would do in production.

Labels used below:
- **best practice**: what we do, and what we would recommend anyway
- **acceptable risk**: a known weakness we accept for this project, with the reason
- **insecure pattern**: something we would not use in production; it is here only because of a constraint

## 1. Controls in place

### Application (inventorise-app)

| Control | How it works |
|---|---|
| Hashed passwords | Passwords are stored with scrypt (werkzeug). The database never holds a password. |
| Hashed API tokens | Tokens are 32 random bytes. Only their SHA-256 hash is stored, so a database leak does not give usable tokens. Tokens expire after 24 h. |
| Login rules | Login failures and successes are logged with the username, IP and result. The response time is the same for an unknown user and a wrong password. |
| Accounts are created from the server only | `flask create-user` is the only way to make an account. There is no sign-up page. |
| CSRF protection | Form posts need a token (Flask-WTF). The API uses bearer tokens, not cookies, so it is not open to cross-site requests. |
| Content-Security-Policy | Scripts load only from this site and the pinned Chart.js CDN, with a Subresource Integrity hash. The page cannot be framed. |
| Cookies | HttpOnly, SameSite=Lax, and Secure in production. |
| Input checks | Lengths, number ranges, SKU format and duplicate SKUs are checked before any write. |
| No stack traces to users | Errors are logged on the server. Clients get a short message. |
| Non-root container | The image runs as UID 10001, with a read-only root file system in Kubernetes. |
| Secret scanning | gitleaks runs on the app repo in the pipeline. Any finding fails the build. |

### Container image and pipeline

| Control | How it works |
|---|---|
| Pinned base image | `python:3.12.15-slim-trixie` (exact tag). |
| Image vulnerability scan | Trivy scans each image. A CRITICAL finding fails the build. |
| SBOM | A CycloneDX software list is produced for every image. |
| Pinned tools | gitleaks, Trivy and Checkov have exact versions. Jenkins plugins are pinned. |
| Immutable tags | Images are tagged with the commit ID, never `latest`. |
| IaC scan | Checkov checks the Kubernetes and Terraform files. Each skipped check has a written reason in `.checkov.yaml`. |
| No `kubectl apply` from CI | Jenkins only commits to git. Argo CD makes the change, so every change is in git history. |
| Rollback | A failed deploy (Argo CD not Healthy within 180 s) is reverted by Jenkins automatically. |

### Cloud and network (AWS EC2)

| Control | How it works |
|---|---|
| One way in | SSH reaches the cluster only through the bastion, and the bastion accepts SSH only from the admin's home IP. |
| Private nodes | Control plane, Postgres and CI have no public IP. Their outbound traffic goes through the bastion's NAT. |
| Narrow security groups | Each role has its own group. Only workers accept web traffic (ports 80 and 443). Postgres accepts connections only from the workers and from the other database node. |
| Instance metadata | IMDSv2 is required on every instance, so a web-request bug cannot read the instance's credentials. |
| Encrypted disks | All root volumes are encrypted (EBS). |
| Least-privilege CLI user | The `inventorise-cli` IAM policy allows EC2 actions in eu-north-1 only, plus `sts:GetCallerIdentity`. |
| Budget alerts | Alerts at $50 and $100. |
| Stop when idle | The instances are stopped when not in use. The start and stop scripts wait for the cluster to be ready. |

### Cluster

| Control | How it works |
|---|---|
| Pod Security "restricted" | The app namespace refuses pods that run as root, gain privileges, or skip the seccomp filter. |
| Security context | Non-root user, no privilege escalation, all capabilities dropped, read-only root file system. |
| No API token in the app | `automountServiceAccountToken: false`. The app cannot call the Kubernetes API. |
| NetworkPolicy | App pods accept traffic only from ingress-nginx and the monitoring namespace. |
| Encrypted Secrets | k3s encrypts Kubernetes Secrets in etcd. Existing Secrets were re-encrypted with a new key on 2026-10-12. |
| Random Secrets | Database and app keys come from a script with random values. Nothing is committed. |
| TLS to the database | The app connects with `sslmode=require`, and Postgres accepts only SSL connections from the app's subnet (`hostssl`, scram-sha-256). |
| HTTPS only | HTTP redirects to HTTPS (308). Certificates come from our private CA. |
| Jenkins access | The Jenkins service account can only read Argo CD status and run the smoke-user script (`argocd/ci-access.yaml`). |

## 2. Accepted risks

### Management account for the project
- **Constraint:** the credits and budgets belong to the management account of Mendi's AWS organization. Organization policies do not apply there.
- **Risk:** a leaked key from this account reaches more than a member account would. An attacker with full access could change billing or the organization.
- **Compensating controls:** the CLI user has an EC2-only policy for one region, so it cannot call IAM, Organizations or billing. There are budget alerts, no keys in the repos, and the instances are stopped when idle.
- **Production fix:** a separate member account with a service control policy that limits regions and services.

### Terraform state on the admin machine
- **Constraint:** no S3 backend, to keep to the EC2-only scope.
- **Risk:** the state file holds resource IDs and IP addresses. A stolen laptop exposes them.
- **Compensating controls:** the state is git-ignored, the laptop is encrypted, and no secrets are stored in the state.
- **Production fix:** a remote backend with encryption and locking.

### Jenkins on the Docker socket
- **Constraint:** Jenkins builds images with the host's Docker daemon. This is the simplest option on one CI node.
- **Risk:** anyone who can change the pipeline controls the CI node's Docker daemon, which is root on that node. This is an **insecure pattern**.
- **Compensating controls:** the CI node has no public address, the Jenkins UI is reachable only through the bastion, and the credentials are held only in Jenkins.
- **Production fix:** rootless builds (for example Kaniko or BuildKit) on separate build agents.

### Jenkins service account can exec into app pods
- **Constraint:** the smoke test creates the smoke user with `create-app-user.sh`, which runs `flask create-user` in an app pod.
- **Risk:** the token can run commands in the app pods, which hold the database password in their environment.
- **Compensating controls:** the permission is limited to the `inventory` namespace. The token is stored only in Jenkins, and the CI node has no public address.
- **Production fix:** a separate, audited job for creating users, with no `exec` permission.

## 3. Known gaps

| Gap | Effect | Production fix |
|---|---|---|
| No rate limiting and no lockout on login | Password guessing is possible at network speed. Login attempts are logged, but nothing stops them. | Rate limiting at ingress, plus a lockout after repeated failures. |
| Private CA | Browsers show a warning unless the CA is installed. The demo laptop has it installed. | A public certificate (Let's Encrypt with a real domain). |
| Manual Postgres failover | If the primary fails, someone must promote the standby and change the address. | Patroni or a managed database service, with automatic failover. |
| No WAL archiving | The recovery point is the last `backup-postgres.sh` run. Data written after it is lost in a disaster. | Continuous WAL archiving to remote storage, plus point-in-time recovery. |
| One availability zone | A zone failure takes the whole cluster down. | Spread nodes over three zones. |
| Fixed node count | The autoscaler can add pods, but not nodes. A traffic peak is limited by the two workers. | Cluster autoscaler or a larger fixed pool. |
| ingress-nginx is retired upstream | It gets no more security fixes. | A maintained controller, or the Kubernetes Gateway API. |
| About 45 s of partial failure when a worker dies | Measured in the failover test on 2026-10-12: 10 of 153 probes failed. The dead pod stays in the service until Kubernetes marks its node NotReady. | Faster node failure detection (a shorter node-monitor grace period), or more replicas with a disruption budget. |
| Secrets are not in an external vault | Secrets live in the cluster, and anyone with cluster-admin access can read them. | External Secrets Operator with a secrets manager, out of scope here (ADR 7). |
| Single database | No replicas are read from; the app depends on one primary. | Read replicas and connection pooling. |
| Application creates tables on start | `create_all()` does not change existing columns. Schema changes need a real migration tool. | Alembic migrations (ADR 3). |

## 4. What we would check first in a real incident

1. **Compromised app account:** revoke the user's token (change their password with `flask create-user`), and check the login log for the source IPs.
2. **Compromised Jenkins token:** rotate the GitHub and Docker Hub tokens, and the `kubeconfig-ci` credential (`scripts/make-ci-kubeconfig.sh`).
3. **Leaked AWS key:** deactivate the key in IAM, create a new one, and check the budgets and the CloudTrail history.
4. **Database breach:** the stored passwords and tokens are hashes, but rotate the database password and the app `SECRET_KEY`, and invalidate all tokens.
