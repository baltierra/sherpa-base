#!/usr/bin/env bash
# Shared helpers for the sherpa-base scripts. Source this file; do not execute it.

# shellcheck disable=SC2034  # variables below are used by the scripts that source this file
DATA_ROOT="${DATA_ROOT:-/media/volume/sherpa-data}"
SECRETS_DIR="${DATA_ROOT}/_secrets"
ENV_FILE="${SECRETS_DIR}/sherpa-base.env"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PG_CONTAINER="sherpa-postgres"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Containers must never start while the volume is missing: they would write
# (or worse, initialise a brand-new empty database) on the boot disk.
require_mount() {
  mountpoint -q "$DATA_ROOT" \
    || die "$DATA_ROOT is not a mount point. Refusing to continue so nothing is written to the boot disk."
}

# docker without sudo when this user is in the docker group (and the group is
# active in this shell), with sudo otherwise.
dk() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}
