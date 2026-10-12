# ADR 12: A bastion instance for SSH and NAT, not a NAT Gateway

*An ADR (Architecture Decision Record) is a short note explaining one
design decision: why it was made and what it costs.*

## Context
Private nodes need outbound internet for package updates and image pulls. A
managed NAT Gateway costs about $32 a month plus data charges. It is also a
service outside the EC2-only scope.

## Decision
One small instance (t3.micro) is the only SSH entry point, and it also forwards
outbound traffic for the private subnet (`nftables` masquerade, set by Ansible).
Its route table entry points at the instance.

This keeps the design to EC2 only and costs the price of one small instance.

## Consequences
- Cheap, with the same EC2 tools we already use.
- The bastion is a single point of failure for outbound traffic and SSH. It is
  not highly available. For this project that is acceptable, and we record it.
- Its throughput is limited by its instance size, which is fine for updates
  and image pulls.
