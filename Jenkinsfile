// CI pipeline for the inventory app. It runs on the Jenkins CI node.
// Jenkins does CI: it tests, builds, scans, pushes the image, and commits the
// new image tag to git. Argo CD does CD: it sees the commit and updates the
// cluster. Jenkins never runs `kubectl apply`.
//
// Each tool runs in a pinned container, so builds do not depend on what is
// installed on the CI node. The workspace is mounted at the same path inside
// the containers (see ansible/roles/ci).
//
// Credentials (set up once in Jenkins, see jenkins/README.md):
//   dockerhub      Docker Hub user and access token (push images)
//   github-devops  GitHub user and token that may push to the devops repo
//   kubeconfig-ci  kubeconfig for the jenkins-ci service account (see argocd/ci-access.yaml)
//   smoke-user     user and password the smoke test logs in with

pipeline {
  agent any

  options {
    timestamps()
    timeout(time: 45, unit: 'MINUTES')
    disableConcurrentBuilds()   // one writer to the devops repo at a time
    buildDiscarder(logRotator(numToKeepStr: '15'))
  }

  parameters {
    string(name: 'APP_BRANCH', defaultValue: 'main',
           description: 'Branch of the app repo to build')
  }

  environment {
    IMAGE          = 'dusterius/inventory-app'
    APP_REPO       = 'https://github.com/mendilirmak/inventorise-app.git'
    DEVOPS_REPO    = 'https://github.com/mendilirmak/inventorise-devops.git'
    PYTHON_IMAGE   = 'python:3.12.15-slim-trixie'
    GITLEAKS_IMAGE = 'zricethezav/gitleaks:v8.30.1'
    TRIVY_IMAGE    = 'aquasec/trivy:0.75.0'
    CHECKOV_IMAGE  = 'bridgecrew/checkov:3.3.23'
    OVERLAY        = 'k8s/overlays/ec2'
    ARGO_APP       = 'inventorise-ec2'
  }

  stages {

    stage('Checkout') {
      steps {
        deleteDir()
        dir('app')    { git url: env.APP_REPO,    branch: params.APP_BRANCH }
        dir('devops') { git url: env.DEVOPS_REPO, branch: 'main' }
        script {
          // The image tag is the app commit, so every image maps to one commit.
          env.TAG = sh(script: 'git -C app rev-parse --short=12 HEAD', returnStdout: true).trim()
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.TAG}"
        }
        sh 'mkdir -p reports'
      }
    }

    stage('Secret scan') {
      steps {
        // Scans the whole git history of the app repo. Any finding fails the build.
        // GIT_CONFIG_* marks the mounted repo as safe (its owner differs inside the container).
        sh '''
          docker run --rm --user "$(id -u)" \
            -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/repo \
            -v "$WORKSPACE/app:/repo:ro" "$GITLEAKS_IMAGE" \
            git --no-banner --redact --exit-code 1 /repo
        '''
      }
    }

    stage('Lint') {
      steps {
        // Creates a virtualenv in the workspace. The test stages reuse it.
        sh '''
          docker run --rm --user "$(id -u)" -e HOME=/tmp \
            -v "$WORKSPACE:/work" -w /work/app "$PYTHON_IMAGE" sh -c '
              python -m venv /work/.ci-venv &&
              /work/.ci-venv/bin/pip install --quiet -r requirements-dev.txt &&
              /work/.ci-venv/bin/ruff check .'
        '''
      }
    }

    stage('Unit tests') {
      steps {
        sh '''
          docker run --rm --user "$(id -u)" -e HOME=/tmp \
            -v "$WORKSPACE:/work" -w /work/app "$PYTHON_IMAGE" \
            /work/.ci-venv/bin/pytest -p no:cacheprovider --junitxml=/work/reports/junit.xml
        '''
      }
      post { always { junit allowEmptyResults: true, testResults: 'reports/junit.xml' } }
    }

    stage('Build image') {
      steps {
        sh 'docker build --pull -t "$IMAGE:$TAG" app'
      }
    }

    stage('Image scan and SBOM') {
      steps {
        // The SBOM (software bill of materials) lists every package in the image.
        // The build fails if the image has a CRITICAL vulnerability.
        sh '''
          mkdir -p "$JENKINS_HOME/trivy-cache"
          DOCKER_GID=$(stat -c %g /var/run/docker.sock)
          trivy() {
            docker run --rm --user "$(id -u)" --group-add "$DOCKER_GID" \
              -e TRIVY_CACHE_DIR=/cache -v "$JENKINS_HOME/trivy-cache:/cache" \
              -v /var/run/docker.sock:/var/run/docker.sock \
              -v "$WORKSPACE/reports:/reports" "$TRIVY_IMAGE" "$@"
          }
          trivy image --format cyclonedx --output /reports/sbom.json "$IMAGE:$TAG"
          trivy image --severity CRITICAL --exit-code 1 --format json --output /reports/trivy.json "$IMAGE:$TAG"
        '''
      }
    }

    stage('Push to Docker Hub') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub',
                         usernameVariable: 'DH_USER', passwordVariable: 'DH_TOKEN')]) {
          // A temporary config folder keeps the login out of JENKINS_HOME.
          sh '''
            export DOCKER_CONFIG=$(mktemp -d)
            trap 'rm -rf "$DOCKER_CONFIG"' EXIT
            printf '%s' "$DH_TOKEN" | docker login --username "$DH_USER" --password-stdin
            docker push "$IMAGE:$TAG"
          '''
        }
      }
    }

    stage('IaC scan') {
      steps {
        // Checkov checks the Kubernetes and Terraform files for risky settings.
        // Skipped checks, each with a reason, are listed in .checkov.yaml.
        sh '''
          # Checkov writes one file per output. A missing folder makes it write
          # the report to a file named "reports", so create the folder first.
          mkdir -p "$WORKSPACE/devops/reports"
          docker run --rm --user "$(id -u)" -v "$WORKSPACE/devops:/src" -w /src \
            "$CHECKOV_IMAGE" --config-file .checkov.yaml \
            --directory k8s --directory terraform \
            --output cli --output junitxml --output-file-path console,reports
        '''
      }
      post { always { junit allowEmptyResults: true, testResults: 'devops/reports/results_junitxml.xml' } }
    }

    stage('Update GitOps repo') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'github-devops',
                         usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')]) {
          sh '''
            cd devops
            kustomization="$OVERLAY/kustomization.yaml"
            sed -i -E "s|^([[:space:]]*newTag:).*|\\1 \\"$TAG\\"|" "$kustomization"
            if git diff --quiet; then
              echo "Tag $TAG is already in $kustomization; nothing to commit."
            else
              git -c user.name="Jenkins CI" -c user.email="jenkins@inventorise.local" \
                commit -am "Deploy $IMAGE:$TAG to the ec2 cluster"
              askpass=$(mktemp); trap 'rm -f "$askpass"' EXIT
              printf '#!/bin/sh\\ncase "$1" in Username*) echo "$GIT_USER";; *) echo "$GIT_TOKEN";; esac\\n' > "$askpass"
              chmod 700 "$askpass"
              GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git push origin HEAD:main
              touch ../.tag-committed
            fi
          '''
        }
        script { env.DEPLOY_COMMIT = sh(script: 'git -C devops rev-parse HEAD', returnStdout: true).trim() }
      }
    }

    stage('Sync and verify') {
      steps {
        // Argo CD polls git every 30 s (k8s/ec2-addons/argocd-values.yaml).
        // Wait until it has this commit and reports Synced and Healthy.
        // If that does not happen within 180 s, the tag commit is reverted.
        withCredentials([file(credentialsId: 'kubeconfig-ci', variable: 'KUBECONFIG')]) {
          script {
            def rc = sh(returnStatus: true, script: '''#!/usr/bin/env bash
              end=$(( $(date +%s) + 180 ))
              get() { kubectl -n argocd get application "$ARGO_APP" -o "jsonpath={$1}" 2>/dev/null || true; }
              while true; do
                sync=$(get .status.sync.status); health=$(get .status.health.status); rev=$(get .status.sync.revision)
                echo "argocd: revision=${rev:0:12} sync=$sync health=$health (want ${DEPLOY_COMMIT:0:12} Synced Healthy)"
                if [ "$rev" = "$DEPLOY_COMMIT" ] && [ "$sync" = Synced ] && [ "$health" = Healthy ]; then exit 0; fi
                if [ "$(date +%s)" -ge "$end" ]; then exit 1; fi
                sleep 5
              done
            ''')
            if (rc != 0) {
              echo 'Deployment did not become Synced and Healthy in time. Reverting the tag commit.'
              if (fileExists('.tag-committed')) {
                withCredentials([usernamePassword(credentialsId: 'github-devops',
                                 usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')]) {
                  sh '''
                    cd devops
                    git -c user.name="Jenkins CI" -c user.email="jenkins@inventorise.local" \
                      revert --no-edit "$DEPLOY_COMMIT"
                    askpass=$(mktemp); trap 'rm -f "$askpass"' EXIT
                    printf '#!/bin/sh\\ncase "$1" in Username*) echo "$GIT_USER";; *) echo "$GIT_TOKEN";; esac\\n' > "$askpass"
                    chmod 700 "$askpass"
                    GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git push origin HEAD:main
                  '''
                }
              }
              error('Argo CD did not report Synced and Healthy within 180 s; the tag commit was reverted.')
            }
          }
        }
      }
    }

    stage('Smoke test') {
      steps {
        withCredentials([
          file(credentialsId: 'kubeconfig-ci', variable: 'KUBECONFIG'),
          usernamePassword(credentialsId: 'smoke-user', usernameVariable: 'SMOKE_USER', passwordVariable: 'SMOKE_PASSWORD')
        ]) {
          // 1. Create the smoke user if it is missing. The password goes in on stdin.
          // 2. Read the public CA certificate from the ConfigMap, to trust it.
          // 3. Call the app through ingress-nginx on a worker, using the real
          //    hostname, so the certificate is checked properly.
          sh '''
            APP_USER_PASSWORD="$SMOKE_PASSWORD" devops/scripts/create-app-user.sh "$SMOKE_USER"
            kubectl -n inventory get configmap inventorise-ca-cert -o 'jsonpath={.data.ca\\.crt}' > ca.crt
            worker_ip=$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/name=ingress-nginx \
                          -o 'jsonpath={.items[0].status.hostIP}')
            docker run --rm --user "$(id -u)" -e HOME=/tmp \
              --add-host "inventory.local:$worker_ip" \
              -e BASE_URL=https://inventory.local -e SMOKE_USER -e SMOKE_PASSWORD \
              -e SSL_CERT_FILE=/work/ca.crt \
              -v "$WORKSPACE:/work" -w /work/app "$PYTHON_IMAGE" \
              /work/.ci-venv/bin/pytest -p no:cacheprovider --junitxml=/work/reports/smoke.xml tests/smoke
          '''
        }
      }
      post { always { junit allowEmptyResults: true, testResults: 'reports/smoke.xml' } }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'reports/**, devops/reports/**', allowEmptyArchive: true
      sh 'docker image prune --force || true'
    }
  }
}
