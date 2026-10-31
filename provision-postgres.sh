#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
[ -f "$here/config.env" ] && . "$here/config.env"

PG_USER="${PG_USER:-ci}"
PG_PASSWORD="${PG_PASSWORD:-ci}"
PG_DB="${PG_DB:-ci}"
PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-128MB}"
PG_MAX_CONNECTIONS="${PG_MAX_CONNECTIONS:-100}"

[ "$(id -u)" -eq 0 ] || { echo "provision-postgres.sh must run as root" >&2; exit 1; }

if ! command -v psql >/dev/null 2>&1; then
  apt-get update && apt-get install -y postgresql
fi

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PG_USER}') THEN
    CREATE ROLE ${PG_USER} LOGIN PASSWORD '${PG_PASSWORD}';
  END IF;
END \$\$;
SQL
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" | grep -q 1; then
  sudo -u postgres createdb -O "${PG_USER}" "${PG_DB}"
fi

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
ALTER SYSTEM SET shared_buffers  = '${PG_SHARED_BUFFERS}';
ALTER SYSTEM SET max_connections = ${PG_MAX_CONNECTIONS};
SQL
systemctl restart postgresql

echo "== postgres provisioned =="
sudo -u postgres psql -tAc "show shared_buffers; show max_connections;"
echo "role/db: ${PG_USER}/${PG_DB} on localhost:5432"
echo "NOTE: keep 5432 bound to localhost and do NOT expose it — this is a CI-local DB."
