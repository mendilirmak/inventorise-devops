# A dedicated VPC, not the default one, so the layout is visible in code.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "inventorise" }
}

# Internet gateway: the way public subnets reach the internet.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "inventorise" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false # public addresses are Elastic IPs, set explicitly
  tags                    = { Name = "inventorise-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "inventorise-private" }
}

# Public subnet: default route straight to the internet gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "inventorise-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private subnet: outbound traffic goes to the bastion, which acts as the
# NAT box (see ansible/roles/bastion). This replaces a paid NAT Gateway.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.bastion.primary_network_interface_id
  }
  tags = { Name = "inventorise-private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
