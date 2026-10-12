#!/usr/bin/env bash
# Runs once when the Postgres volume is first created (docker-entrypoint-initdb.d).
# Creates the least-privilege runtime role. Table grants are applied by the Prisma migrations.
set -euo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rsaas_app') THEN
    CREATE ROLE rsaas_app LOGIN PASSWORD '${APP_DB_PASSWORD}' NOSUPERUSER NOBYPASSRLS;
  ELSE
    ALTER ROLE rsaas_app LOGIN PASSWORD '${APP_DB_PASSWORD}';
  END IF;
END \$\$;
GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO rsaas_app;
SQL
