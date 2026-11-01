#!/usr/bin/env bash
# =============================================================================
# Sets up the whole warehouse in Docker with one command: starts SQL Server, creates the
# database, installs every object and runs the pipeline. Add --test to run the tests too.
#
#   ./deploy/deploy.sh            reset database, deploy objects, run pipeline
#   ./deploy/deploy.sh --no-reset deploy objects (keep data), run pipeline
#   ./deploy/deploy.sh --test     ... and then run all automated tests
#
# Requires Docker with the compose plugin and a .env file (see .env.example).
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

RESET=1
RUN_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --no-reset) RESET=0 ;;
    --test)     RUN_TESTS=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if [ ! -f .env ]; then
  echo "No .env file found. Copy .env.example to .env and set MSSQL_SA_PASSWORD." >&2
  exit 1
fi
# shellcheck disable=SC1091
set -a; source .env; set +a

SQLCMD=(docker compose exec -T sqlserver /opt/mssql-tools18/bin/sqlcmd
        -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b -I)
VARS=(-v RepoRoot=/dwh DataRoot=/dwh/data/ BulkCodepage=RAW)

echo ">> Starting SQL Server container"
docker compose up -d

echo ">> Waiting for SQL Server to accept connections"
for i in $(seq 1 60); do
  if "${SQLCMD[@]}" -Q "SELECT 1" > /dev/null 2>&1; then break; fi
  if [ "$i" -eq 60 ]; then echo "SQL Server did not start in time." >&2; exit 1; fi
  sleep 2
done

if [ "$RESET" -eq 1 ]; then
  echo ">> Creating a fresh DataWarehouse database"
  "${SQLCMD[@]}" -i /dwh/scripts/init_database.sql
fi

echo ">> Deploying objects"
"${SQLCMD[@]}" "${VARS[@]}" -i /dwh/scripts/deploy_objects.sql

echo ">> Running the pipeline"
"${SQLCMD[@]}" -d DataWarehouse -Q "EXEC etl.usp_run_pipeline;" -W -s " | "

if [ "$RUN_TESTS" -eq 1 ]; then
  echo ">> Running the automated tests"
  "${SQLCMD[@]}" "${VARS[@]}" -i /dwh/tests/run_all_tests.sql
fi

echo ">> Done. Connect with SSMS/Azure Data Studio to localhost,${MSSQL_PORT:-1433} (user sa)."
