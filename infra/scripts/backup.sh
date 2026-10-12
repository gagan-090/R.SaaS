#!/usr/bin/env bash
# Logical backup of the compose database into ./backups/ (gitignored).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$ROOT/backups"
FILE="$ROOT/backups/rsaas-$(date -u +%Y%m%dT%H%M%SZ).dump"
docker compose -f "$ROOT/infra/docker-compose.yml" --env-file "$ROOT/.env.local" exec -T db \
  pg_dump -U rsaas_owner -d rsaas -Fc > "$FILE"
echo "Backup written: $FILE"
