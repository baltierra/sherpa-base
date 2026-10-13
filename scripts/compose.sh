#!/usr/bin/env bash
# Wrapper around `docker compose` for the base stack.
#   ./scripts/compose.sh ps
#   ./scripts/compose.sh logs -f traefik
#   ./scripts/compose.sh --profile test up -d whoami
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE. Run ./bootstrap.sh first."

# Only commands that start containers need the volume; `down`, `logs`, `ps`
# must still work if the volume has gone missing.
for arg in "$@"; do
  case "$arg" in
    up|start|restart|create|run) require_mount; break ;;
  esac
done

dk compose --env-file "$ENV_FILE" -f "$REPO_DIR/compose.yaml" "$@"
