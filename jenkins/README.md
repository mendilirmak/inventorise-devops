# Jenkins (CI)

Jenkins runs on the CI node (private subnet) as a Docker container started by
systemd. Ansible builds the image on the node from the two files in this
folder, so everything is pinned:

| File | What it pins |
|---|---|
| `Dockerfile` | Jenkins `2.580.1-lts-jdk21`, kubectl `v1.36.1` (checksum-verified), Docker CLI from Debian |
| `plugins.txt` | 68 plugins at exact versions. We ask for five: Pipeline (`workflow-aggregator`), `git`, `credentials-binding`, `junit`, `timestamper`. The rest are what they need |

The pipeline's tools run in their own pinned containers: gitleaks v8.30.1,
Python 3.12.15 (ruff, pytest), Trivy 0.75.0, Checkov 3.3.23.

**Lab-only:** Jenkins controls the CI node's Docker daemon through the mounted
socket, so anyone who can change the pipeline is effectively root on that node.
The node has no public address and the UI is reachable only through the bastion.

## First-time setup

1. Build the node: `ansible-playbook playbooks/site.yml` (the `ci` play builds
   the image and starts the service). Add the new security group rule first:
   `terraform apply` (lets the CI node reach the Kubernetes API).
2. Run `scripts/ec2-bootstrap.sh` (creates the access rules and the CA ConfigMap
   in the cluster), then `scripts/make-ci-kubeconfig.sh <cp-1 private IP>`.
3. Open the UI through the bastion and unlock it:
   ```bash
   ssh -L 8080:<ci private IP>:8080 ubuntu@<bastion public IP>
   # in the bastion/CI shell (ssh -J ubuntu@<bastion> ubuntu@<ci private IP>):
   sudo cat /var/jenkins_home/secrets/initialAdminPassword
   ```
   Browse to http://localhost:8080. In the wizard choose **Select plugins to
   install → None** (they are already installed), then create your admin user.
4. Add four credentials (Manage Jenkins → Credentials → System → Global):

   | ID | Kind | Value |
   |---|---|---|
   | `dockerhub` | Username with password | `dusterius` + a Docker Hub access token (Read & Write) |
   | `github-devops` | Username with password | `mendilirmak` + a fine-grained GitHub token with **Contents: write** on `inventorise-devops` only |
   | `kubeconfig-ci` | Secret file | `ansible/.secrets/ci-kubeconfig` (delete the file afterwards) |
   | `smoke-user` | Username with password | `smoke` + a new random password (12+ characters) |

5. New Item → Pipeline → *Pipeline script from SCM* → Git →
   `https://github.com/mendilirmak/inventorise-devops.git`, branch `main`,
   script path `Jenkinsfile`. Build with parameters.

**Check it works:** the first build goes through all 11 stages green, the
Argo CD application shows Synced and Healthy, and `https://inventory.local`
answers.

## Starting a build on a new app commit

Jenkins cannot receive GitHub webhooks: the CI node has no public address. So a
second, small job checks the app repo every 5 minutes and starts the pipeline:

1. Create a freestyle job named `inventorise-poll`.
2. **Source Code Management:** Git, repository `https://github.com/mendilirmak/inventorise-app.git`,
   branch `main`.
3. **Build Triggers:** Poll SCM, schedule `H/5 * * * *`.
4. **Build steps:** none.
5. **Post-build Actions:** Build other projects: `inventorise`, no parameters
   (`APP_BRANCH` keeps its default `main`).

The devops repo is not polled. The pipeline commits the image tag there, so
polling it would start a build after every build, endlessly.

Check: push a commit to the app repo, or wait for a poll. A `inventorise` build
should start within about 5 minutes. Cost: a request to GitHub every 5 minutes.

## Updating Jenkins or a plugin

Change the version in `Dockerfile` (or the plugin names in `plugins.txt`),
build the image locally, list the versions it resolved and paste them back:

```bash
docker build -t inventorise-jenkins:test jenkins
docker run --rm --entrypoint bash inventorise-jenkins:test -c \
  'for f in /usr/share/jenkins/ref/plugins/*.jpi; do echo "$(basename $f .jpi):$(unzip -p $f META-INF/MANIFEST.MF | tr -d "\r" | sed -n "s/^Plugin-Version: //p")"; done | sort'
```

Then run the Ansible `ci` play again. It rebuilds the image and restarts Jenkins.
