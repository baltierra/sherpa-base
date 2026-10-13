-- Runs ONCE, when the data directory is first created (empty volume path).
-- It does not re-run on later restarts or when an existing data directory is reattached.
--
-- Installing pgvector in template1 means every database created later
-- (scripts/db-create-app.sh) already has the `vector` extension.
\connect template1
CREATE EXTENSION IF NOT EXISTS vector;

\connect postgres
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
