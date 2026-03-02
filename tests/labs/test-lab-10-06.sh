#!/usr/bin/env bash
# test-lab-10-06.sh — Lab 10-06: Production Deployment
# Module 10: FreePBX/Asterisk VoIP PBX
# Services: MariaDB · OpenLDAP · Keycloak · Mailhog · FreePBX (workers mode)
# Ports:    Web:8380  SIP:5167/udp  AMI:5042  KC:8480  LDAP:3898  MH:8680
set -euo pipefail

LAB_ID="10-06"
LAB_NAME="Production Deployment"
MODULE="freepbx"
COMPOSE_FILE="docker/docker-compose.production.yml"
PASS=0
FAIL=0
CLEANUP=true

for arg in "$@"; do [ "$arg" = "--no-cleanup" ] && CLEANUP=false; done

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }

cleanup() {
  if [ "${CLEANUP}" = "true" ]; then
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  Lab ${LAB_ID}: ${LAB_NAME} — ${MODULE}${NC}"
echo -e "${CYAN}  Production: restart=unless-stopped, healthchecks, resource limits${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 60s for production stack to initialize..."
sleep 60

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

for svc in freepbx-p06-db freepbx-p06-ldap freepbx-p06-kc freepbx-p06-mail freepbx-p06-app; do
  if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
    pass "Container ${svc} running"
  else
    fail "Container ${svc} not running"
  fi
done

if docker exec freepbx-p06-db mysqladmin ping -uroot -pRootProd06! --silent 2>/dev/null; then
  pass "MariaDB accepting connections"
else
  fail "MariaDB not responding"
fi

if curl -sf http://localhost:8480/realms/master > /dev/null 2>&1; then
  pass "Keycloak realms/master reachable (:8480)"
else
  fail "Keycloak not reachable (:8480)"
fi

if curl -sf http://localhost:8680/api/v2/messages > /dev/null 2>&1; then
  pass "Mailhog UI reachable (:8680)"
else
  fail "Mailhog not reachable (:8680)"
fi

if curl -sf http://localhost:8380/admin/config.php > /dev/null 2>&1; then
  pass "FreePBX admin web accessible (:8380)"
else
  fail "FreePBX admin web not accessible (:8380)"
fi

# ── PHASE 3: Functional Tests — Production Grade ─────────────────────────────
section "Phase 3: Functional Tests — Production Deployment"

# ── 3a: Compose config validation ───────────────────────────────────────────────
if docker compose -f "${COMPOSE_FILE}" config -q 2>/dev/null; then
  pass "Compose file syntax valid"
else
  fail "Compose file syntax error"
fi

# ── 3b: Resource limits defined on app container ──────────────────────────────
info "Verifying resource limits on freepbx-p06-app..."
MEM_LIMIT=$(docker inspect freepbx-p06-app --format '{{.HostConfig.Memory}}' 2>/dev/null || echo 0)
if [ "${MEM_LIMIT}" -gt 0 ] 2>/dev/null; then
  pass "Memory limit set on freepbx-p06-app (${MEM_LIMIT} bytes)"
else
  fail "Memory limit not set on freepbx-p06-app"
fi

CPU_QUOTA=$(docker inspect freepbx-p06-app --format '{{.HostConfig.NanoCpus}}' 2>/dev/null || echo 0)
if [ "${CPU_QUOTA}" -gt 0 ] 2>/dev/null; then
  pass "CPU limit set on freepbx-p06-app"
else
  fail "CPU limit not set on freepbx-p06-app"
fi

# ── 3c: Restart policy check ───────────────────────────────────────────────────
RESTART_POLICY=$(docker inspect freepbx-p06-app --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "none")
if [ "${RESTART_POLICY}" = "unless-stopped" ]; then
  pass "Restart policy: unless-stopped"
else
  fail "Restart policy not set to unless-stopped (got: ${RESTART_POLICY})"
fi

# ── 3d: Production env vars ───────────────────────────────────────────────────
if docker exec freepbx-p06-app env | grep -q 'IT_STACK_ENV=production'; then
  pass "IT_STACK_ENV=production set"
else
  fail "IT_STACK_ENV not set to production"
fi

if docker exec freepbx-p06-app env | grep -q 'IT_STACK_LAB=06'; then
  pass "IT_STACK_LAB=06 set"
else
  fail "IT_STACK_LAB not set to 06"
fi

if docker exec freepbx-p06-app env | grep -q 'KEYCLOAK_URL=http://freepbx-p06-kc'; then
  pass "KEYCLOAK_URL points to freepbx-p06-kc"
else
  fail "KEYCLOAK_URL not configured correctly"
fi

# ── 3e: Database backup test ───────────────────────────────────────────────────
info "Testing database backup (mysqldump)..."
if docker exec freepbx-p06-db mysqldump \
     -uroot -pRootProd06! asterisk > /dev/null 2>&1; then
  pass "Database backup (mysqldump asterisk) succeeds"
else
  fail "Database backup (mysqldump asterisk) failed"
fi

# ── 3f: Keycloak admin API ───────────────────────────────────────────────────────
info "Testing Keycloak admin API..."
KC_TOKEN=$(curl -sf -X POST http://localhost:8480/realms/master/protocol/openid-connect/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=admin-cli&grant_type=password&username=admin&password=Admin06!' \
  2>/dev/null | grep -o '"access_token":"[^"]*' | cut -d'"' -f4 || echo "")
if [ -n "${KC_TOKEN}" ]; then
  pass "Keycloak admin token obtained"
  REALM_LIST=$(curl -sf http://localhost:8480/admin/realms \
    -H "Authorization: Bearer ${KC_TOKEN}" 2>/dev/null | grep -o '"realm"' | wc -l || echo 0)
  if [ "${REALM_LIST}" -ge 1 ]; then
    pass "Keycloak realm list accessible (${REALM_LIST} realm entry found)"
  else
    fail "Keycloak admin API realm list empty"
  fi
else
  fail "Keycloak admin token not obtained"
fi

# ── 3g: LDAP connectivity from app container ───────────────────────────────────
if docker exec freepbx-p06-app curl -sf telnet://freepbx-p06-ldap:389 \
     --connect-timeout 3 > /dev/null 2>&1 || nc -z freepbx-p06-ldap 389 2>/dev/null || \
     docker exec freepbx-p06-ldap ldapsearch -x -H ldap://localhost \
       -b dc=lab,dc=local -D cn=admin,dc=lab,dc=local -w LdapProd06! cn=admin > /dev/null 2>&1; then
  pass "LDAP service responding on port 389"
else
  fail "LDAP service not responding on port 389"
fi

# ── 3h: Restart resilience test ──────────────────────────────────────────────────
info "Testing DB restart resilience..."
docker restart freepbx-p06-db > /dev/null 2>&1
sleep 15
if docker exec freepbx-p06-db mysqladmin ping -uroot -pRootProd06! --silent 2>/dev/null; then
  pass "MariaDB recovers after restart"
else
  fail "MariaDB did not recover after restart"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "  Lab ${LAB_ID} Complete"
echo -e "  ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}============================================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi

LAB_ID="10-06"
LAB_NAME="Production Deployment"
MODULE="freepbx"
COMPOSE_FILE="docker/docker-compose.production.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 30s for ${MODULE} to initialize..."
sleep 30

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps | grep -q "running\|Up"; then
    pass "Container is running"
else
    fail "Container is not running"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 06 — Production Deployment)"

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:5060/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 10-06 pending implementation"

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
