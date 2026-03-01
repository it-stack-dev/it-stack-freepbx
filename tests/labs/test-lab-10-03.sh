#!/usr/bin/env bash
# test-lab-10-03.sh — Lab 10-03: Advanced Features
# Module 10: FreePBX/Asterisk VoIP PBX
# Tests: resource limits + AMI interface + recordings/MOH/voicemail volumes + dialplan
set -euo pipefail

LAB_ID="10-03"
LAB_NAME="Advanced Features"
MODULE="freepbx"
COMPOSE_FILE="docker/docker-compose.advanced.yml"
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

info "Waiting for MariaDB (up to 90s)..."
for i in $(seq 1 18); do
  if docker exec freepbx-a03-db mysqladmin ping -uroot -pRootLab03! --silent 2>/dev/null; then
    pass "MariaDB healthy"; break
  fi
  [[ $i -eq 18 ]] && fail "MariaDB timed out"
  sleep 5
done

info "Waiting for Mailhog (up to 60s)..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:8620/api/v2/messages > /dev/null 2>&1; then
    pass "Mailhog reachable on :8620"; break
  fi
  [[ $i -eq 12 ]] && fail "Mailhog not reachable on :8620"
  sleep 5
done

info "Waiting for FreePBX web (up to 4 min)..."
for i in $(seq 1 48); do
  if curl -sf http://localhost:8320/admin/config.php 2>/dev/null | grep -qi 'freepbx\|asterisk\|login'; then
    pass "FreePBX admin UI on :8320"; break
  fi
  [[ $i -eq 48 ]] && fail "FreePBX not reachable on :8320"
  sleep 5
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests"

# Container states
for cname in freepbx-a03-db freepbx-a03-mail freepbx-a03-app; do
  if docker inspect "${cname}" --format '{{.State.Status}}' 2>/dev/null | grep -q running; then
    pass "${cname} running"
  else
    fail "${cname} not running"
  fi
done

# AMI port accessible from host
if nc -z localhost 5038 2>/dev/null; then
  pass "AMI port :5038 accessible"
else
  fail "AMI port :5038 not accessible"
fi

# Asterisk core responding
if docker exec freepbx-a03-app asterisk -rx "core show version" 2>/dev/null | grep -qi asterisk; then
  pass "Asterisk core show version responds"
else
  fail "Asterisk core not responding"
fi

# Asterisk dialplan loaded
CONTEXTS=$(docker exec freepbx-a03-app asterisk -rx "dialplan show" 2>/dev/null | grep -c "^==" || echo 0)
if [[ "${CONTEXTS:-0}" -gt 0 ]]; then
  pass "Asterisk dialplan has ${CONTEXTS} contexts"
else
  fail "Asterisk dialplan empty or not loaded"
fi

# Asterisk channels list
if docker exec freepbx-a03-app asterisk -rx "core show channels" 2>/dev/null | grep -q 'active channel\|0 active'; then
  pass "Asterisk core show channels responds"
else
  fail "Asterisk show channels failed"
fi

# Resource limits applied
MEM_LIMIT=$(docker inspect freepbx-a03-app --format '{{.HostConfig.Memory}}' 2>/dev/null || echo 0)
if [[ "${MEM_LIMIT:-0}" -gt 0 ]]; then
  pass "Memory limit set on freepbx-a03-app (${MEM_LIMIT} bytes)"
else
  fail "No memory limit set on freepbx-a03-app"
fi

# Advanced volumes exist
for vol in freepbx-a03-recordings freepbx-a03-moh freepbx-a03-voicemail freepbx-a03-data freepbx-a03-logs; do
  if docker volume ls --format '{{.Name}}' | grep -q "${vol}"; then
    pass "Volume ${vol} exists"
  else
    fail "Volume ${vol} missing"
  fi
done

# SMTP / Mailhog env
if docker exec freepbx-a03-app printenv SMTP_HOST 2>/dev/null | grep -q 'freepbx-a03-mail'; then
  pass "SMTP_HOST → freepbx-a03-mail"
else
  fail "SMTP_HOST not pointing to Mailhog"
fi

# HTTP response code
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" http://localhost:8320/admin/config.php 2>/dev/null || echo 000)
if [[ "${HTTP_CODE}" =~ ^(200|301|302)$ ]]; then
  pass "FreePBX HTTP ${HTTP_CODE} on :8320"
else
  fail "FreePBX HTTP ${HTTP_CODE}"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo " Lab ${LAB_ID} Results"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0