# Values Ansible and the scripts need. Printed after `terraform apply`.

output "bastion_public_ip" {
  description = "SSH entry point. Also the public address for the NAT box."
  value       = aws_eip.bastion.public_ip
}

output "worker_public_ips" {
  description = "Public addresses for the web entry point (ports 80 and 443)."
  value       = aws_eip.worker[*].public_ip
}

output "control_plane_private_ips" {
  value = aws_instance.control_plane[*].private_ip
}

output "worker_private_ips" {
  value = aws_instance.worker[*].private_ip
}

output "postgres_private_ips" {
  description = "First address is the primary, second the standby."
  value       = aws_instance.postgres[*].private_ip
}

output "ci_private_ip" {
  value = aws_instance.ci.private_ip
}

output "instance_ids" {
  description = "Used by the start and stop script."
  value = concat(
    [aws_instance.bastion.id],
    aws_instance.control_plane[*].id,
    aws_instance.worker[*].id,
    aws_instance.postgres[*].id,
    [aws_instance.ci.id],
  )
}
