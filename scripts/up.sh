#!/usr/bin/env bash
# Pull images and (re)start the base stack: traefik, socket-proxy, postgres.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_mount
for net in sherpa-web sherpa-db; do
  dk network inspect "$net" >/dev/null 2>&1 \
    || die "Docker network '$net' is missing. Run ./bootstrap.sh first."
done

log "Pulling images"
"$REPO_DIR/scripts/compose.sh" pull
log "Starting the base stack"
"$REPO_DIR/scripts/compose.sh" up -d
"$REPO_DIR/scripts/compose.sh" ps
log "Next: ./scripts/verify.sh"
