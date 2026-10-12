# Jenkins for the CI node: the official LTS image plus the tools the pipeline
# calls. Ansible builds it on the CI node (ansible/roles/ci).
#
# JDK 21, not the "lts-jdk17" tag: that tag has not been rebuilt since March
# 2026, so it would miss later security fixes. JDK 21 is current.
FROM jenkins/jenkins:2.580.1-lts-jdk21

USER root

# Docker CLI: the pipeline builds and scans images through the CI node's Docker
# daemon, using the mounted socket (lab-only, see jenkins/README.md).
RUN apt-get update \
 && apt-get install -y --no-install-recommends docker-cli \
 && rm -rf /var/lib/apt/lists/*

# kubectl: reads the Argo CD application status and runs the smoke-user script.
# The download is checked against its published checksum before it is installed.
ARG KUBECTL_VERSION=v1.36.1
RUN curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
 && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - \
 && install -m 0755 kubectl /usr/local/bin/kubectl \
 && rm kubectl kubectl.sha256

USER jenkins

# Plugins, installed at build time at the exact versions listed in plugins.txt.
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
