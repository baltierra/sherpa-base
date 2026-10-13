# sherpa-base
Infrastructure-as-code for a Jetstream2 VM hosting multiple DataSherpa apps. Docker Compose stack with Traefik (automatic Let’s Encrypt HTTPS, one subdomain per app) and PostgreSQL 17 + pgvector, with idempotent bootstrap and helper scripts. All data lives on a persistent volume, so a rebuilt VM comes back with a single script.
