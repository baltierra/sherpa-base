# sherpa-base

Shared infrastructure for every Sherpa app (DataSherpa PhD research, NCSA) running on one
Jetstream2 VM: **Traefik** (HTTPS + routing by subdomain) and **PostgreSQL 17 + pgvector**,
with all data on the persistent volume.

The goal: if the VM dies, create a new one, attach the volume, run one script, and everything
comes back.

```
Internet ── :80/:443 ──> Traefik ──(sherpa-web network)──> <app>.sherpa.ncsa.illinois.edu containers
                           │                                         │
                  socket-proxy (read-only)                 (sherpa-db network)
                                                                     │
                                                       PostgreSQL 17 + pgvector
```

## Where things live

```
/opt/sherpa-base/                    this repo (boot disk; GitHub is the source of truth)
/media/volume/sherpa-data/           persistent volume (ext4)
├── pgvector/data/                   PostgreSQL data directory
├── traefik/acme.json                Let's Encrypt certificates
├── _secrets/                        sherpa-base.env, apps/<app>.db.env   (never in git)
└── poc/  des/  tim/                 one folder per Sherpa: its repo and its data
```

## Prerequisites

- Ubuntu 24.04 VM, user `exouser` with sudo.
- Volume mounted at `/media/volume/sherpa-data`.
- Jetstream2 security group: inbound **22, 80, 443** only (5432 and 8080 stay closed; they are also bound to loopback).
- DNS for `sherpa.ncsa.illinois.edu` and `*.sherpa.ncsa.illinois.edu` points at the VM (done by NCSA).

## First-time setup, or rebuilding the VM

```bash
sudo mkdir -p /opt/sherpa-base && sudo chown "$USER": /opt/sherpa-base
git clone https://github.com/baltierra/sherpa-base.git /opt/sherpa-base
cd /opt/sherpa-base
./bootstrap.sh          # Docker, folders, secrets file, networks. Asks for the Let's Encrypt email.
./scripts/up.sh         # Traefik + PostgreSQL
./scripts/verify.sh     # volume, containers, pgvector, Traefik routers
```

Log out and back in once after the first bootstrap so `docker` works without `sudo` (the scripts fall back to
`sudo` until then, but plain `docker` commands in this README will not).

`bootstrap.sh` is idempotent. It also makes `docker.service` wait for the volume mount, and the
compose file refuses to create data folders on the boot disk, so a missing volume produces an
error instead of a silently empty database.

Rebuilding with the same volume: run the same steps. Existing database and certificates are
picked up as they are (the `initdb` SQL only runs when the data directory is empty).

### Check HTTPS with Let's Encrypt staging first (recommended)

Staging has no rate limits, so mistakes cost nothing.

1. In `/media/volume/sherpa-data/_secrets/sherpa-base.env` set
   `ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory`
2. `./scripts/up.sh`, then `./scripts/compose.sh --profile test up -d whoami`
3. `curl -kI https://whoami.sherpa.ncsa.illinois.edu` should return `200` (`-k` because staging certificates are not trusted).
4. Switch to production: restore `ACME_CA_SERVER` to the production URL (see `.env.example`), then

   ```bash
   ./scripts/compose.sh stop traefik
   rm /media/volume/sherpa-data/traefik/acme.json
   install -m 600 /dev/null /media/volume/sherpa-data/traefik/acme.json
   ./scripts/compose.sh up -d traefik
   curl -I https://whoami.sherpa.ncsa.illinois.edu     # now without -k
   docker rm -f sherpa-whoami
   ```

If issuance fails: confirm the name resolves to the VM, port 80 is reachable from the internet,
and `docker logs sherpa-traefik` for the ACME error. Two campus-specific things to ask NCSA about
if it still fails: CAA records on `illinois.edu` that exclude Let's Encrypt, and Let's Encrypt's
weekly new-certificate limit per registered domain (`illinois.edu` is shared across campus;
renewals do not count).

## Adding a Sherpa

1. `./scripts/db-create-app.sh des` creates database `des` and role `des` (pgvector enabled) and
   writes the credentials to `/media/volume/sherpa-data/_secrets/apps/des.db.env`.
2. Put the app in `/media/volume/sherpa-data/des/` (clone its repo there).
3. Start from `templates/app-compose.example.yaml`. It shows the Traefik labels, the two networks to join,
   and the naming conventions. The subdomain works as soon as the container is up: Traefik requests
   the certificate on first use.

## Day to day

| Task | Command |
|---|---|
| Start / update base stack | `./scripts/up.sh` |
| Status, logs, restart | `./scripts/compose.sh ps` / `logs -f traefik` / `restart postgres` |
| SQL shell (superuser) | `./scripts/psql.sh` or `./scripts/psql.sh -d des` |
| New database for an app | `./scripts/db-create-app.sh <app>` (`--rotate` for a new password) |
| Health check | `./scripts/verify.sh` |

### Admin access from your laptop

Neither port is public. Use SSH tunnels:

```bash
# PostgreSQL (DBeaver, psql, pgAdmin, ...) -> connect to localhost:15432
ssh -L 15432:127.0.0.1:5432 exouser@sherpa.ncsa.illinois.edu

# Traefik dashboard -> http://localhost:8080/dashboard/   (trailing slash required)
ssh -L 8080:127.0.0.1:8080 exouser@sherpa.ncsa.illinois.edu
```

The dashboard is not needed for normal operation. It is only useful to see which routers and
certificates Traefik loaded when something does not route.

## Security notes

- Published ports: 80 and 443 only. PostgreSQL (5432) and the dashboard (8080) bind to `127.0.0.1`.
  Docker edits iptables directly and bypasses UFW, so the Jetstream2 security group is the real firewall.
- Traefik never touches the Docker socket directly. It goes through `socket-proxy`, which allows read-only
  container, network and info calls and blocks every write.
- Each app's role can connect to its own database only; other Sherpas' databases are closed to it. (The empty default
  `postgres` maintenance database stays open to all roles.) Credentials are mode 600 on the volume.
- `sherpa-db` is a regular bridge network, not `internal`, because publishing the loopback PostgreSQL port needs that.
  Only containers you explicitly attach can reach it.
- Nothing sensitive is committed: `.env.example` has placeholders, and `.gitignore` blocks env files, keys and `acme.json`.

## Moving secrets to SOPS/age later

Not hard, and nothing else changes. Commit an encrypted `secrets/sherpa-base.enc.env`, and add one step
to `bootstrap.sh` that decrypts it to `/media/volume/sherpa-data/_secrets/sherpa-base.env`. Compose and
all scripts only ever read that file. The per-app `*.db.env` files can be handled the same way.

## Deliberately not done yet

- **Backups.** Until they exist, losing the volume means losing everything. Plan: nightly `pg_dump` per
  database to the OSN S3 bucket, plus an encrypted copy of `_secrets/`.
- **GitHub Container Registry.** Later each app compose file just pulls `ghcr.io/<pri-org>/<image>:<tag>`
  instead of building on the VM. Docker images live on the boot disk, so `docker image prune` occasionally.
- **Upgrades.** Image tags are pinned (Traefik, socket proxy, whoami) or follow a major (`pgvector:pg17`).
  A PostgreSQL major upgrade (17 to 18) needs a dump and restore.
