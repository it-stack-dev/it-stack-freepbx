#!/usr/bin/env bash
# test-lab-10-02.sh — Lab 10-02: External Dependencies
# Module 10: FreePBX/Asterisk VoIP PBX
# Tests: external MariaDB connectivity + Mailhog SMTP relay + multi-container
set -euo pipefail

LAB_ID="10-02"
LAB_NAME="External Dependencies"
MODULE="freepbx"
COMPOSE_FILE="docker/docker-compose.lan.yml"
PASS=0
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }

CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    info "Cleaning up..."
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}========================================${NC}"

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

info "Waiting for external MariaDB (freepbx-l02-db, up to 90s)..."
for i in $(seq 1 18); do
  if docker exec freepbx-l02-db mysqladmin ping -uroot -pRootLab02! --silent 2>/dev/null; then
    pass "External MariaDB healthy"; break
  fi
  [[ $i -eq 18 ]] && fail "External MariaDB timed out"
  sleep 5
done

info "Waiting for Mailhog (freepbx-l02-mail, up to 60s)..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:8610/api/v2/messages > /dev/null 2>&1; then
    pass "Mailhog UI reachable on :8610"; break
  fi
  [[ $i -eq 12 ]] && fail "Mailhog not reachable on :8610"
  sleep 5
done

info "Waiting for FreePBX web (up to 3 min)..."
for i in $(seq 1 36); do
  if curl -sf http://localhost:8310/admin/config.php 2>/dev/null | grep -qi 'freepbx\|asterisk\|login'; then
    pass "FreePBX admin UI reachable on :8310"; break
  fi
  [[ $i -eq 36 ]] && fail "FreePBX admin UI not reachable on :8310"
  sleep 5
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests"

# Container states
for cname in freepbx-l02-db freepbx-l02-mail freepbx-l02-app; do
  if docker inspect "${cname}" --format '{{.State.Status}}' 2>/dev/null | grep -q running; then
    pass "${cname} running"
  else
    fail "${cname} not running"
  fi
done

# External DB connectivity from app
if docker exec freepbx-l02-app mysql -hfreepbx-l02-db -uasterisk -pAsteriskLab02! asterisk \
     -e "SELECT 1;" > /dev/null 2>&1; then
  pass "App connects to external MariaDB (asterisk DB)"
else
  fail "App cannot connect to external MariaDB"
fi

# DB has FreePBX tables
TABLE_COUNT=$(docker exec freepbx-l02-db mysql -uroot -pRootLab02! asterisk \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='asterisk';" \
  --skip-column-names 2>/dev/null || echo 0)
if [[ "${TABLE_COUNT:-0}" -gt 5 ]]; then
  pass "External DB has ${TABLE_COUNT} FreePBX tables"
else
  fail "External DB has only ${TABLE_COUNT:-0} tables (expected >5)"
fi

# Mailhog API
if curl -sf http://localhost:8610/api/v2/messages | grep -q 'total\|items'; then
  pass "Mailhog API returns valid JSON"
else
  fail "Mailhog API not valid"
fi

# FreePBX HTTP code
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" http://localhost:8310/admin/config.php 2>/dev/null || echo 000)
if [[ "${HTTP_CODE}" =~ ^(200|301|302)$ ]]; then
  pass "FreePBX HTTP ${HTTP_CODE} on :8310"
else
  fail "FreePBX HTTP ${HTTP_CODE} (expected 200/301/302)"
fi

# Asterisk/SIP active
if docker exec freepbx-l02-app asterisk -rx "core show version" 2>/dev/null | grep -qi asterisk; then
  pass "Asterisk core responding"
else
  fail "Asterisk core not responding"
fi

# Environment variables
for envvar in DB_HOST DB_NAME DB_USER DB_PASS ADMIN_PASSWORD SMTP_HOST; do
  if docker exec freepbx-l02-app printenv "${envvar}" > /dev/null 2>&1; then
    pass "Env var ${envvar} set"
  else
    fail "Env var ${envvar} missing"
  fi
done

# Volumes
for vol in freepbx-l02-db-data freepbx-l02-data freepbx-l02-logs; do
  if docker volume ls --format '{{.Name}}' | grep -q "${vol}"; then
    pass "Volume ${vol} exists"
  else
    fail "Volume ${vol} missing"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo " Lab ${LAB_ID} Results"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0