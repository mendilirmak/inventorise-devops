# The nine EC2 instances, one block per role. Sizes are from CLAUDE.md.

resource "aws_key_pair" "cluster" {
  key_name   = "inventorise-cluster"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_instance" "bastion" {
  ami                         = var.ami_id
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.cluster.key_name
  subnet_id                   = aws_subnet.public.id
  availability_zone           = var.availability_zone
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  source_dest_check           = false # must be off, so it can forward traffic for private nodes
  associate_public_ip_address = false # the Elastic IP below gives it a fixed address
  ebs_optimized               = true
  monitoring                  = false

  metadata_options {
    # IMDSv2 only: blocks the simple credential theft through an SSRF bug.
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "inventorise-bastion", Role = "bastion" }
}

resource "aws_instance" "control_plane" {
  count                  = 3
  ami                    = var.ami_id
  instance_type          = "t3.medium"
  key_name               = aws_key_pair.cluster.key_name
  subnet_id              = aws_subnet.private.id
  availability_zone      = var.availability_zone
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id, aws_security_group.ssh_from_bastion.id]
  ebs_optimized          = true
  monitoring             = false

  metadata_options {
    # IMDSv2 only: blocks the simple credential theft through an SSRF bug.
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "inventorise-cp-${count.index + 1}", Role = "control-plane" }
}

resource "aws_instance" "worker" {
  count                  = 2
  ami                    = var.ami_id
  instance_type          = "t3.large"
  key_name               = aws_key_pair.cluster.key_name
  subnet_id              = aws_subnet.public.id
  availability_zone      = var.availability_zone
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id, aws_security_group.web.id, aws_security_group.ssh_from_bastion.id]
  ebs_optimized          = true
  monitoring             = false

  metadata_options {
    # IMDSv2 only: blocks the simple credential theft through an SSRF bug.
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "inventorise-worker-${count.index + 1}", Role = "worker" }
}

resource "aws_instance" "postgres" {
  count                  = 2
  ami                    = var.ami_id
  instance_type          = "t3.medium"
  key_name               = aws_key_pair.cluster.key_name
  subnet_id              = aws_subnet.private.id
  availability_zone      = var.availability_zone
  vpc_security_group_ids = [aws_security_group.postgres.id, aws_security_group.ssh_from_bastion.id]
  ebs_optimized          = true
  monitoring             = false

  metadata_options {
    # IMDSv2 only: blocks the simple credential theft through an SSRF bug.
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  # The first node is the primary, the second the standby. Ansible sets the roles.
  tags = { Name = "inventorise-pg-${count.index + 1}", Role = "postgres" }
}

resource "aws_instance" "ci" {
  ami                    = var.ami_id
  instance_type          = "t3.medium"
  key_name               = aws_key_pair.cluster.key_name
  subnet_id              = aws_subnet.private.id
  availability_zone      = var.availability_zone
  vpc_security_group_ids = [aws_security_group.ci.id, aws_security_group.ssh_from_bastion.id]
  ebs_optimized          = true
  monitoring             = false

  metadata_options {
    # IMDSv2 only: blocks the simple credential theft through an SSRF bug.
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "inventorise-ci", Role = "ci" }
}

# Fixed public addresses for the bastion and the workers. The costs are
# shown in STATUS.md; they are billed even when the instances are stopped.
resource "aws_eip" "bastion" {
  domain     = "vpc"
  instance   = aws_instance.bastion.id
  tags       = { Name = "inventorise-bastion" }
  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip" "worker" {
  count      = 2
  domain     = "vpc"
  instance   = aws_instance.worker[count.index].id
  tags       = { Name = "inventorise-worker-${count.index + 1}" }
  depends_on = [aws_internet_gateway.main]
}
