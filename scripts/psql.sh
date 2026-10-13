#!/usr/bin/env bash
# Open psql as the superuser inside the Postgres container.
#   ./scripts/psql.sh                    # interactive, database "postgres"
#   ./scripts/psql.sh -d des             # a specific database
#   ./scripts/psql.sh -c '\l'            # one-off command
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tty_flag=()
if [[ -t 0 && -t 1 ]]; then tty_flag=(-t); fi

dk exec -i "${tty_flag[@]}" "$PG_CONTAINER" psql -U postgres "$@"
