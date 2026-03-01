#!/usr/bin/env bash
# test-lab-10-05.sh — Lab 10-05: Advanced Integration
# Module 10: FreePBX/Asterisk VoIP PBX
# Services: MariaDB · OpenLDAP · Keycloak · WireMock (SuiteCRM-mock) · Mailhog · FreePBX
# Ports:    Web:8360  SIP:5165  AMI:5040  WireMock:8361  KC:8460  LDAP:3894  MH:8660
set -euo pipefail

LAB_ID="10-05"
LAB_NAME="Advanced Integration"
MODULE="freepbx"
COMPOSE_FILE="docker/docker-compose.integration.yml"
MOCK_URL="http://localhost:8361"
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
echo -e "${CYAN}  FreePBX ↔ SuiteCRM CTI (WireMock) + Zammad webhook${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 45s for integration stack to initialize..."
sleep 45

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

for svc in freepbx-i05-db freepbx-i05-ldap freepbx-i05-kc freepbx-i05-mock freepbx-i05-mail freepbx-i05-app; do
  if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
    pass "Container ${svc} running"
  else
    fail "Container ${svc} not running"
  fi
done

if docker exec freepbx-i05-db mysqladmin ping -uroot -pRootLab05! --silent 2>/dev/null; then
  pass "MariaDB accepting connections"
else
  fail "MariaDB not responding"
fi

if curl -sf "${MOCK_URL}/__admin/health" > /dev/null 2>&1; then
  pass "WireMock admin health endpoint accessible"
else
  fail "WireMock not accessible at ${MOCK_URL}"
fi

if curl -sf http://localhost:8360/admin/config.php > /dev/null 2>&1; then
  pass "FreePBX admin web accessible (:8360)"
else
  fail "FreePBX admin web not accessible (:8360)"
fi

# ── PHASE 3: Functional Tests — Integration ───────────────────────────────────
section "Phase 3: Functional Tests — Advanced Integration"

# ── 3a: WireMock stub creation (SuiteCRM CTI + Zammad webhooks) ──────────
info "Registering WireMock stubs for SuiteCRM CTI API..."

# Register SuiteCRM calls/save stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "urlPathPattern": "/index.php.*module=Calls.*"},
    "response": {"status": 200, "body": "{\\"result\\":{\\"id\\":\\"call-001\\",\\"status\\":\\"success\\"}}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock stub: SuiteCRM calls/save registered"
else
  fail "WireMock stub: SuiteCRM calls/save failed (status: ${HTTP_STATUS})"
fi

# Register SuiteCRM contacts lookup stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "GET", "urlPathPattern": "/index.php.*module=Contacts.*"},
    "response": {"status": 200, "body": "{\\"result\\":[{\\"id\\":\\"contact-001\\",\\"name\\":\\"Test User\\"}]}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock stub: SuiteCRM contacts/lookup registered"
else
  fail "WireMock stub: SuiteCRM contacts/lookup failed (status: ${HTTP_STATUS})"
fi

# Register Zammad ticket creation stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "url": "/api/v1/tickets"},
    "response": {"status": 201, "body": "{\\"id\\":1001,\\"title\\":\\"Call from FreePBX\\",\\"state\\":\\"new\\"}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock stub: Zammad ticket POST registered"
else
  fail "WireMock stub: Zammad ticket POST failed (status: ${HTTP_STATUS})"
fi

# ── 3b: Verify WireMock stubs accessible ─────────────────────────────────────
info "Verifying integration endpoints via WireMock..."

if curl -sf "${MOCK_URL}/api/v1/tickets" \
     -X POST -H "Content-Type: application/json" \
     -d '{"title":"Test call from FreePBX","customer":"ext101"}' | grep -q 'id'; then
  pass "WireMock Zammad tickets endpoint responds correctly"
else
  fail "WireMock Zammad tickets endpoint not responding"
fi

if curl -sf "${MOCK_URL}/index.php?module=Contacts&action=index" | grep -q 'contact-001'; then
  pass "WireMock SuiteCRM contacts endpoint responds correctly"
else
  fail "WireMock SuiteCRM contacts endpoint not responding"
fi

# ── 3c: Integration env vars in FreePBX container ──────────────────────────
info "Verifying integration env vars in FreePBX container..."

if docker exec freepbx-i05-app env | grep -q 'SUITECRM_URL=http://freepbx-i05-mock'; then
  pass "SUITECRM_URL env var set correctly"
else
  fail "SUITECRM_URL not set in FreePBX container"
fi

if docker exec freepbx-i05-app env | grep -q 'ZAMMAD_WEBHOOK_URL=http://freepbx-i05-mock'; then
  pass "ZAMMAD_WEBHOOK_URL env var set correctly"
else
  fail "ZAMMAD_WEBHOOK_URL not set in FreePBX container"
fi

if docker exec freepbx-i05-app env | grep -q 'SUITECRM_API_KEY=lab-integration-key-05'; then
  pass "SUITECRM_API_KEY env var set correctly"
else
  fail "SUITECRM_API_KEY not set in FreePBX container"
fi

# ── 3d: Connectivity from FreePBX container to WireMock ──────────────────────
info "Testing FreePBX → WireMock (SuiteCRM) connectivity..."

if docker exec freepbx-i05-app curl -sf \
     http://freepbx-i05-mock:8080/index.php?module=Contacts\&action=index \
     > /dev/null 2>&1; then
  pass "FreePBX container → WireMock (SuiteCRM mock) reachable"
else
  fail "FreePBX container cannot reach WireMock (SuiteCRM mock)"
fi

# ── 3e: Mappings count check ─────────────────────────────────────────────────
MAPPING_COUNT=$(curl -sf "${MOCK_URL}/__admin/mappings" | grep -o '"id"' | wc -l || echo 0)
if [ "${MAPPING_COUNT}" -ge 3 ]; then
  pass "WireMock has ${MAPPING_COUNT} stubs registered (expected ≥3)"
else
  fail "WireMock only has ${MAPPING_COUNT} stubs (expected ≥3)"
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
