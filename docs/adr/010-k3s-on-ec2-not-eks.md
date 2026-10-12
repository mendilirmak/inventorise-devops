# ADR 10: k3s on EC2 instead of EKS

*An ADR (Architecture Decision Record) is a short note explaining one
design decision: why it was made and what it costs.*

## Context
EKS is the managed Kubernetes service on AWS. Its control plane costs about
$73 a month per cluster, and it needs AWS services beyond EC2 (IAM roles for
the nodes, load balancers, the EKS API). Both conflict with the EC2-only scope
and the $200 credit budget.

## Decision
k3s runs the Kubernetes control plane on our own EC2 instances. Three
control-plane servers give high availability with embedded etcd. Two workers
run the app.

The cluster is built with Terraform and Ansible, so it can be recreated.

## Consequences
- No control-plane fee. The cost is the same EC2 instances we already pay for.
- We run and patch the control plane ourselves (Ansible does most of it).
- Not everything in the Kubernetes documentation applies, for example managed
  node groups. The demo states the differences.
