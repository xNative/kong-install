#!/usr/bin/env bash
set -Eeuo pipefail

echo "Enabling pg_stat_monitor in postgres database..."

psql   --username "$POSTGRES_USER"   --dbname postgres   -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_monitor;
SQL

echo "Enabling pgvector in ${POSTGRES_DB}..."

psql   --username "$POSTGRES_USER"   --dbname "$POSTGRES_DB"   -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL

echo "PostgreSQL extensions initialized."
