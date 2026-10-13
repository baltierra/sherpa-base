#!/usr/bin/env bash
# sherpa-base bootstrap for a fresh Ubuntu 24.04 Jetstream2 VM.
# Idempotent: safe to re-run at any time.
#
#   ./bootstrap.sh            # prepare the VM (Docker, folders, secrets, networks)
#   ./bootstrap.sh --up       # ... and start the base stack afterwards
#
# Optional environment:
#   ACME_EMAIL=you@domain     # skip the interactive question
#   SHERPA_APPS="poc des tim" # folders to create on the volume
#   DATA_ROOT=/path           # volume mount point (default /media/volume/sherpa-data)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"

[[ $EUID -ne 0 ]] || die "Run as your normal user (it needs sudo), not as root."
sudo -v
USER_NAME="$(id -un)"
read -ra APPS <<<"${SHERPA_APPS:-poc des tim}"
NEED_DOCKER_RESTART=0

# --- 1. Sanity checks ---------------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
  || warn "Written for Ubuntu 24.04; this is ${PRETTY_NAME:-unknown}. Continuing."

require_mount
log "Volume OK: $(findmnt -no SOURCE,FSTYPE "$DATA_ROOT" | tr -s ' ' ' ') at $DATA_ROOT"
if [[ "$(stat -c %U "$DATA_ROOT")" != "$USER_NAME" ]]; then
  log "Giving $USER_NAME ownership of the volume root"
  sudo chown "$USER_NAME:$USER_NAME" "$DATA_ROOT"
fi

# --- 2. Docker Engine + Compose plugin (official Docker apt repository) -------
if ! sudo docker compose version >/dev/null 2>&1; then
  dpkg -s docker.io >/dev/null 2>&1 \
    && die "Ubuntu's 'docker.io' package is installed. Remove it (sudo apt remove docker.io) or install the Compose plugin yourself, then re-run."
  log "Installing Docker Engine and the Compose plugin"
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  log "Docker + Compose plugin already installed"
fi
sudo systemctl enable --now docker

if ! id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx docker; then
  log "Adding $USER_NAME to the docker group (active after your next login)"
  sudo usermod -aG docker "$USER_NAME"
fi

# --- 3. Docker daemon: log rotation (keeps the boot disk from filling up) -----
if [[ ! -f /etc/docker/daemon.json ]]; then
  log "Writing /etc/docker/daemon.json (log rotation)"
  sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" }
}
EOF
  NEED_DOCKER_RESTART=1
elif ! sudo grep -q '"max-size"' /etc/docker/daemon.json; then
  warn "/etc/docker/daemon.json exists without log rotation; add log-opts max-size/max-file yourself."
fi

# --- 4. Docker must not start before the volume is mounted --------------------
dropin_dir=/etc/systemd/system/docker.service.d
dropin="$dropin_dir/10-sherpa-volume.conf"
dropin_content=$'[Unit]\nRequiresMountsFor='"$DATA_ROOT"
if ! sudo test -f "$dropin" || [[ "$(sudo cat "$dropin")" != "$dropin_content" ]]; then
  log "Making docker.service wait for $DATA_ROOT"
  sudo mkdir -p "$dropin_dir"
  printf '%s\n' "$dropin_content" | sudo tee "$dropin" >/dev/null
  sudo systemctl daemon-reload
  NEED_DOCKER_RESTART=1
fi
mount_unit="$(systemd-escape -p --suffix=mount "$DATA_ROOT")"
if ! systemctl cat "$mount_unit" >/dev/null 2>&1; then
  warn "systemd has no mount unit for $DATA_ROOT (no /etc/fstab entry?). After a reboot, confirm the volume is mounted before containers matter;"
  warn "the compose file refuses to create data folders on the boot disk, so a missing volume fails loudly instead of silently."
fi

if [[ $NEED_DOCKER_RESTART -eq 1 ]]; then
  log "Restarting Docker to apply configuration"
  sudo systemctl restart docker
fi

# --- 5. Folders on the persistent volume --------------------------------------
log "Creating folders under $DATA_ROOT"
mkdir -p "$DATA_ROOT/pgvector/data" "$DATA_ROOT/traefik" "$SECRETS_DIR/apps"
for app in "${APPS[@]}"; do mkdir -p "$DATA_ROOT/$app"; done
chmod 700 "$SECRETS_DIR" "$SECRETS_DIR/apps" "$DATA_ROOT/traefik"
# The postgres image runs as uid 999; initdb needs an owned, private directory.
sudo chown 999:999 "$DATA_ROOT/pgvector/data"
sudo chmod 700 "$DATA_ROOT/pgvector/data"
# Traefik refuses an acme.json that is not mode 600.
[[ -e "$DATA_ROOT/traefik/acme.json" ]] || install -m 600 /dev/null "$DATA_ROOT/traefik/acme.json"

# --- 6. Secrets / settings file (lives on the volume, outside git) ------------
get_kv() { { grep -E "^$1=" "$ENV_FILE" || true; } | head -n1 | cut -d= -f2-; }
set_kv() {
  local tmp
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  K="$1" V="$2" awk 'BEGIN{FS="="} $1==ENVIRON["K"]{print ENVIRON["K"] "=" ENVIRON["V"]; next} {print}' "$ENV_FILE" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

if [[ ! -f "$ENV_FILE" ]]; then
  log "Creating $ENV_FILE"
  ( umask 077; cp "$REPO_DIR/.env.example" "$ENV_FILE" )
  set_kv DATA_ROOT "$DATA_ROOT"
  set_kv POSTGRES_PASSWORD "$(openssl rand -hex 24)"
fi

email="$(get_kv ACME_EMAIL)"
if [[ -z "$email" || "$email" == *example.com* ]]; then
  email="${ACME_EMAIL:-}"
  if [[ -z "$email" && -t 0 ]]; then
    read -rp "Email for Let's Encrypt expiry notices: " email
  fi
  [[ "$email" == *@*.* ]] \
    || die "ACME_EMAIL is not set. Re-run as: ACME_EMAIL=you@domain ./bootstrap.sh   (or edit $ENV_FILE)"
  set_kv ACME_EMAIL "$email"
fi
ln -sfn "$ENV_FILE" "$REPO_DIR/.env"

# --- 7. Shared Docker networks -------------------------------------------------
for net in sherpa-web sherpa-db; do
  if dk network inspect "$net" >/dev/null 2>&1; then
    log "Docker network $net already exists"
  else
    log "Creating Docker network $net"
    dk network create "$net" >/dev/null
  fi
done

# --- Done ---------------------------------------------------------------------
log "VM is ready."
if [[ "${1:-}" == "--up" ]]; then
  exec "$REPO_DIR/scripts/up.sh"
fi
cat <<EOF

Next steps:
  1. ./scripts/up.sh           start Traefik + PostgreSQL
  2. ./scripts/verify.sh       check volume, containers, pgvector, Traefik
  3. ./scripts/db-create-app.sh des   create a database for each Sherpa
EOF
