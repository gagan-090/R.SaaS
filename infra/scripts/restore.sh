#!/usr/bin/env bash
# Restore a dump made by backup.sh. DESTRUCTIVE: replaces the current database contents.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="${1:?usage: restore.sh backups/<file>.dump}"
read -r -p "This replaces the rsaas database with $FILE. Type 'restore' to continue: " ok
[[ "$ok" == "restore" ]] || { echo "aborted"; exit 1; }
docker compose -f "$ROOT/infra/docker-compose.yml" --env-file "$ROOT/.env.local" exec -T db \
  pg_restore -U rsaas_owner -d rsaas --clean --if-exists < "$FILE"
echo "Restored from $FILE"
