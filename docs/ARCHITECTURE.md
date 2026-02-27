# Architecture — IT-Stack FREEPBX

## Overview

FreePBX with Asterisk provides VoIP telephony, auto-attendant, voicemail, call recording, and CTI integration with SuiteCRM.

## Role in IT-Stack

- **Category:** communications
- **Phase:** 3
- **Server:** lab-pbx1 (10.0.50.16)
- **Ports:** 5060 (SIP), 5061 (SIP TLS), 80 (Admin HTTP), 10000-20000/udp (RTP)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → freepbx → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
