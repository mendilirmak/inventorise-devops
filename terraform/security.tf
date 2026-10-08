# One security group per role. Each group allows only what that role needs.

# Bastion: the only machine that accepts SSH from the internet, and only from
# your home IP.
resource "aws_security_group" "bastion" {
  description = "SSH entry point and NAT for private nodes"
  name        = "inventorise-bastion"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "inventorise-bastion" }
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh_admin" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from the admin home IP"
}

# Traffic from private nodes is routed through the bastion (NAT), so the
# private subnet must be allowed to reach it.
resource "aws_vpc_security_group_ingress_rule" "bastion_from_private" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = var.private_subnet_cidr
  ip_protocol       = "-1"
  description       = "NAT for the private subnet"
}

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  description       = "Outbound to anywhere (updates, image pulls)"
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Every private node accepts SSH only from the bastion.
resource "aws_security_group" "ssh_from_bastion" {
  description = "SSH from the bastion only"
  name        = "inventorise-ssh-from-bastion"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "inventorise-ssh-from-bastion" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh_from_bastion" {
  #checkov:skip=CKV_AWS_24: False positive. This rule allows only the bastion security group, not 0.0.0.0/0.
  security_group_id            = aws_security_group.ssh_from_bastion.id
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  description                  = "SSH from the bastion"
}

# Kubernetes nodes (control plane and workers) talk to each other freely
# inside this group: API, etcd, kubelet, pod networking.
resource "aws_security_group" "k8s_nodes" {
  description = "Kubernetes nodes talk to each other inside the cluster"
  name        = "inventorise-k8s-nodes"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "inventorise-k8s-nodes" }
}

resource "aws_vpc_security_group_ingress_rule" "k8s_nodes_self" {
  security_group_id            = aws_security_group.k8s_nodes.id
  referenced_security_group_id = aws_security_group.k8s_nodes.id
  ip_protocol                  = "-1"
  description                  = "Node-to-node traffic inside the cluster"
}

resource "aws_vpc_security_group_ingress_rule" "k8s_api_from_bastion" {
  security_group_id            = aws_security_group.k8s_nodes.id
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
  description                  = "kubectl through the bastion"
}

resource "aws_vpc_security_group_egress_rule" "k8s_nodes_all" {
  description       = "Outbound to anywhere (image pulls, updates)"
  security_group_id = aws_security_group.k8s_nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Workers only: the public web entry point, ports 80 and 443.
resource "aws_security_group" "web" {
  description = "Public HTTP and HTTPS on the workers"
  name        = "inventorise-web"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "inventorise-web" }
}

resource "aws_vpc_security_group_ingress_rule" "web_http" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP (redirects to HTTPS)"
}

resource "aws_vpc_security_group_ingress_rule" "web_https" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS"
}

# Postgres: reachable only from the workers, and between the two DB nodes
# (streaming replication).
resource "aws_security_group" "postgres" {
  description = "PostgreSQL, from workers and between DB nodes"
  name        = "inventorise-postgres"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "inventorise-postgres" }
}

resource "aws_vpc_security_group_ingress_rule" "postgres_from_workers" {
  security_group_id            = aws_security_group.postgres.id
  referenced_security_group_id = aws_security_group.k8s_nodes.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "App pods reach Postgres"
}

resource "aws_vpc_security_group_ingress_rule" "postgres_replication" {
  security_group_id            = aws_security_group.postgres.id
  referenced_security_group_id = aws_security_group.postgres.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Standby replicates from primary"
}

resource "aws_vpc_security_group_egress_rule" "postgres_all" {
  description       = "Outbound to anywhere (package updates)"
  security_group_id = aws_security_group.postgres.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# CI node: Jenkins web UI reachable only from the bastion (SSH tunnel).
resource "aws_security_group" "ci" {
  description = "CI node: Jenkins UI from the bastion only"
  name        = "inventorise-ci"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "inventorise-ci" }
}

resource "aws_vpc_security_group_ingress_rule" "ci_jenkins_from_bastion" {
  security_group_id            = aws_security_group.ci.id
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Jenkins UI through the bastion"
}

resource "aws_vpc_security_group_egress_rule" "ci_all" {
  description       = "Outbound to anywhere (Docker Hub, GitHub, packages)"
  security_group_id = aws_security_group.ci.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# The VPC's built-in default security group is emptied, so nothing can
# accidentally use it. No rules means it allows no traffic.
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "inventorise-default-unused" }
}
