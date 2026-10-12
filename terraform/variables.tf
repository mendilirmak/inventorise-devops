variable "region" {
  description = "AWS region. eu-north-1 is the only region the course account policies allow."
  type        = string
  default     = "eu-north-1"
}

variable "availability_zone" {
  description = "One zone only. Multi-zone is a known gap (see SECURITY.md)."
  type        = string
  default     = "eu-north-1a"
}

variable "ami_id" {
  description = "Ubuntu 24.04 (noble) AMI from Canonical in eu-north-1. Pinned by ID."
  type        = string
  default     = "ami-09d835910a77f135c"
}

variable "admin_cidr" {
  description = "Your home IP as x.x.x.x/32. Only this address reaches SSH on the bastion. Update it when your IP changes (scripts/update-admin-ip.sh)."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to the public key for cluster SSH access. Only the public key is used."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Bastion and the two workers (they have public IPs)."
  type        = string
  default     = "10.20.1.0/24"
}

variable "private_subnet_cidr" {
  description = "Control plane, Postgres and CI. No public IPs."
  type        = string
  default     = "10.20.2.0/24"
}
