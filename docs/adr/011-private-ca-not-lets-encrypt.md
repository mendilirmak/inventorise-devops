# ADR 11: Private CA with cert-manager, not Let's Encrypt

*An ADR (Architecture Decision Record) is a short note explaining one
design decision: why it was made and what it costs.*

## Context
HTTPS needs a certificate that browsers trust. Let's Encrypt is the usual free
choice, but it needs a public domain name and a public address that the CA can
reach to check the domain. The demo hostname `inventory.local` is not a public
domain. A real domain costs money and needs DNS control.

## Decision
cert-manager runs a private CA inside the cluster (ClusterIssuer
`inventorise-ca`). It signs the certificate for `inventory.local`. The CA
certificate is installed on the demo laptop. Graders need nothing.

The CA's private key stays in the cluster Secret, and it is never exported.

## Consequences
- No domain or DNS cost, and no dependence on an outside service.
- Browsers without the CA installed show a warning.
- If Let's Encrypt is wanted later, cert-manager can switch issuers. Only the
  hostname and the issuer change (SECURITY.md, known gaps).
