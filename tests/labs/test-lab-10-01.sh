#!/usr/bin/env bash
# test-lab-10-01.sh — FreePBX Lab 01: Standalone
# Module 10 | Lab 01 | Tests: basic FreePBX/Asterisk functionality in isolation
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/../docker/docker-compose.standalone.yml"
CLEANUP=true
for arg in "$@"; do [[ "$arg" == "--no-cleanup" ]] && CLEANUP=false; done

WEB_PORT=8301
DB_PASS="RootLab01!"
ADMIN_PASS="Admin01!"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)) || true; }
fail() { echo "[FAIL] $1"; ((FAIL++)) || true; }
section() { echo ""; echo "=== $1 ==="; }

cleanup() {
  if [[ "$CLEANUP" == "true" ]]; then
    echo "Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

section "Starting Lab 01 Standalone Stack"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for MariaDB and FreePBX to initialize (this may take 2-3 minutes)..."

section "MariaDB Health Check"
for i in $(seq 1 30); do
  status=$(docker inspect freepbx-s01-db --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 5
done
[[ "$(docker inspect freepbx-s01-db --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "MariaDB healthy" || fail "MariaDB not healthy"

section "FreePBX Web Health Check"
for i in $(seq 1 60); do
  status=$(docker inspect freepbx-s01-app --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break
  echo "  Waiting for FreePBX ($i/60)..."
  sleep 10
done
[[ "$(docker inspect freepbx-s01-app --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "FreePBX app healthy" || fail "FreePBX app not healthy"

section "FreePBX Web UI Check"
http_code=$(curl -so /dev/null -w "%{http_code}" "http://localhost:${WEB_PORT}/admin/config.php" 2>/dev/null || echo "000")
[[ "$http_code" =~ ^(200|302|401)$ ]] && pass "FreePBX admin page accessible (HTTP $http_code)" || fail "FreePBX admin page returned HTTP $http_code"

section "Database Connectivity"
db_check=$(docker exec freepbx-s01-db mysql -u root -p"${DB_PASS}" -e "SHOW DATABASES;" 2>/dev/null | grep -c "asterisk" || echo 0)
[[ "$db_check" -ge 1 ]] && pass "Asterisk database exists in MariaDB" || fail "Asterisk database not found"

# Check asterisk DB has tables (FreePBX sets up via DB init)
table_check=$(docker exec freepbx-s01-db mysql -u asterisk -p"AsteriskLab01!" asterisk -e "SHOW TABLES;" 2>/dev/null | wc -l || echo 0)
[[ "$table_check" -gt 0 ]] && pass "Asterisk DB has tables (FreePBX initialized)" || fail "Asterisk DB has no tables yet"

section "Container Configuration"
restart_policy=$(docker inspect freepbx-s01-app --format '{{.HostConfig.RestartPolicy.Name}}')
[[ "$restart_policy" == "unless-stopped" ]] && pass "Restart policy: unless-stopped" || fail "Unexpected restart policy: $restart_policy"

# Check environment variables
admin_pass_set=$(docker inspect freepbx-s01-app --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "ADMIN_PASSWORD" | cut -d= -f2)
[[ "$admin_pass_set" == "${ADMIN_PASS}" ]] && pass "ADMIN_PASSWORD env var set correctly" || fail "ADMIN_PASSWORD not set correctly"

db_host=$(docker inspect freepbx-s01-app --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^DB_HOST=" | cut -d= -f2)
[[ "$db_host" == "freepbx-s01-db" ]] && pass "DB_HOST env var set correctly" || fail "DB_HOST not set (got: $db_host)"

section "Named Volumes"
docker volume ls | grep -q "freepbx-s01-db-data" && pass "Volume freepbx-s01-db-data exists" || fail "Volume freepbx-s01-db-data missing"
docker volume ls | grep -q "freepbx-s01-data" && pass "Volume freepbx-s01-data exists" || fail "Volume freepbx-s01-data missing"

section "Network"
docker network ls | grep -q "freepbx-s01-net" && pass "Network freepbx-s01-net exists" || fail "Network freepbx-s01-net missing"

echo ""
echo "================================================"
echo "Lab 01 Results: ${PASS} passed, ${FAIL} failed"
echo "================================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1