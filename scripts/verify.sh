#!/usr/bin/env bash
# Post-deploy health check. Exits non-zero if anything looks wrong.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

log "Volume"
if mountpoint -q "$DATA_ROOT"; then
  ok "$DATA_ROOT is mounted ($(findmnt -no SOURCE,FSTYPE "$DATA_ROOT" | tr -s ' ' ' '))"
else
  bad "$DATA_ROOT is NOT a mount point"
fi
pg_dev="$(findmnt -T "$DATA_ROOT/pgvector/data" -no SOURCE 2>/dev/null || true)"
vol_dev="$(findmnt -no SOURCE "$DATA_ROOT" 2>/dev/null || true)"
if [[ -n "$pg_dev" && "$pg_dev" == "$vol_dev" ]]; then
  ok "PostgreSQL data directory is on the volume ($pg_dev)"
else
  bad "PostgreSQL data directory is not on the volume (found '${pg_dev:-nothing}')"
fi

log "Containers"
for c in sherpa-socket-proxy sherpa-traefik sherpa-postgres; do
  state="$(dk inspect -f '{{.State.Status}}{{if .State.Health}} / {{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || echo missing)"
  case "$state" in
    "running"|"running / healthy") ok "$c: $state" ;;
    *) bad "$c: $state" ;;
  esac
done

log "PostgreSQL + pgvector"
ver="$(dk exec -i "$PG_CONTAINER" psql -U postgres -tAc 'SHOW server_version' 2>/dev/null || true)"
if [[ -n "$ver" ]]; then ok "server_version $ver"; else bad "cannot query PostgreSQL"; fi
for db in postgres template1; do
  v="$(dk exec -i "$PG_CONTAINER" psql -U postgres -d "$db" -tAc "SELECT extversion FROM pg_extension WHERE extname='vector'" 2>/dev/null || true)"
  if [[ -n "$v" ]]; then ok "pgvector $v in $db"; else bad "pgvector missing in $db"; fi
done

log "Traefik"
if routers="$(curl -fsS --max-time 5 http://127.0.0.1:8080/api/http/routers 2>/dev/null)"; then
  ok "API reachable on 127.0.0.1:8080"
  printf '%s' "$routers" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    print("         router %-30s %s" % (r["name"], r.get("status", "?")))
'
else
  bad "Traefik API not reachable on 127.0.0.1:8080"
fi

echo
if [[ $fail -eq 0 ]]; then log "All checks passed."; else die "Some checks failed (see above)."; fi
