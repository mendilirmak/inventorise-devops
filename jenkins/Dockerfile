# Jenkins for the CI node: the official LTS image plus the tools the pipeline
# calls. Built on the CI node by Ansible (roles/ci).
#
# Why JDK 21 and not the "lts-jdk17" tag from the plan: that tag stopped
# receiving updates in March 2026 (current LTS releases are JDK 21 and 25
# only), so it would miss security fixes.
FROM jenkins/jenkins:2.580.1-lts-jdk21

USER root

# Docker CLI: the pipeline builds and scans images by talking to the CI node's
# Docker daemon through the mounted socket (lab-only, see docs/adr/004).
RUN apt-get update \
 && apt-get install -y --no-install-recommends docker-cli \
 && rm -rf /var/lib/apt/lists/*

# kubectl: reads the Argo CD application status and runs the smoke-user script.
# Downloaded with its published checksum, which is verified before install.
ARG KUBECTL_VERSION=v1.36.1
RUN curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
 && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - \
 && install -m 0755 kubectl /usr/local/bin/kubectl \
 && rm kubectl kubectl.sha256

USER jenkins

# Plugins, installed at build time at the exact versions in plugins.txt.
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
