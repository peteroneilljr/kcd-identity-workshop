# Documentation

This directory contains in-depth technical explanations of the technologies and concepts used in this demo.

## Contents

### [Reverse Proxy Architecture](REVERSE-PROXY-EXPLAINED.md)
Explains how reverse proxies work, their role as a security gateway, and why they provide better security than traditional VPNs. Includes detailed Envoy configuration breakdown and comparison with VPN architecture.

**Topics covered:**
- Envoy's filter chain architecture
- JWT authentication filter
- RBAC authorization filter
- Network topology and isolation
- VPN vs Reverse Proxy comparison
- Zero Trust principles

### [OAuth2 and OpenID Connect](OAUTH-OIDC-EXPLAINED.md)
Comprehensive guide to OAuth2 and OIDC protocols, how they work together, and how they're used in this demo for authentication and authorization.

**Topics covered:**
- OAuth2 vs OIDC relationship
- Grant types (password grant used in demo)
- Token endpoint and flow
- OIDC discovery and standard claims
- Production-ready Authorization Code Flow
- Security considerations

### [JWT Tokens](JWT-EXPLAINED.md)
Deep dive into JSON Web Tokens - their structure, security properties, and how they enable stateless authentication.

**Topics covered:**
- JWT structure (Header.Payload.Signature)
- Base64URL encoding
- RS256 signature algorithm
- Claims and their purposes
- JWKS (JSON Web Key Set)
- Token validation process
- Security guarantees (integrity, authenticity, statelessness)

### [Access Logging with Identity](ACCESS-LOGGING-EXPLAINED.md)
Explains how Envoy's dynamic metadata system enables identity-aware logging, creating a complete audit trail for compliance and security monitoring.

**Topics covered:**
- Dynamic metadata in Envoy
- Data flow between filters
- Access log format configuration
- Log fields and their sources
- Audit trail analysis
- Security monitoring use cases

## How to Use These Docs

- **For Presenting**: Use these as reference material when explaining concepts during your talk
- **For Audience**: Share these links for attendees who want deeper technical details
- **For Learning**: Read in order: Reverse Proxy → OAuth/OIDC → JWT → Access Logging

## Related Files

- [Main README](../README.md) - Quick start and architecture overview
- [Follow-Along Workshop](../follow-along/README.md) - Step-by-step modules, one per backend
