# Step-CA (Docker Server Install)

![Docker Compose](https://img.shields.io/badge/deploy-docker%20compose-2496ED?logo=docker&logoColor=white)
![step-ca](https://img.shields.io/badge/app-step--ca-F59E0B)
![Port](https://img.shields.io/badge/port-9000-6C757D)
![Scope](https://img.shields.io/badge/scope-LAN%20only-C9372C)

This stack runs [Smallstep Step-CA](https://smallstep.com/docs/step-ca), a private certificate authority (CA) for issuing and managing TLS certificates inside a homelab or internal network.

## What this application does

- Creates and runs a private internal CA using `step-ca`
- Issues trusted certificates for internal hostnames and services
- Supports automated certificate workflows for reverse proxies, apps, and internal endpoints
- Keeps CA data persistent using a mounted Docker volume

## Included container

- Service: `stepca`
- Image: `smallstep/step-ca:latest`
- Default exposed port in this stack: `9000`
- Data path (host): `/volume1/docker/stepca`

## Notes for this stack

- This configuration is intended for LAN/internal use.
- The container is configured with internal DNS for local name resolution.

> [!WARNING]
> Avoid exposing this service directly to the public internet without additional hardening.

## References

- Step-CA GitHub project: [https://github.com/smallstep/certificates](https://github.com/smallstep/certificates)
- Docker image (Docker Hub): [https://hub.docker.com/r/smallstep/step-ca](https://hub.docker.com/r/smallstep/step-ca)
- Step-CA documentation: [https://smallstep.com/docs/step-ca](https://smallstep.com/docs/step-ca)
