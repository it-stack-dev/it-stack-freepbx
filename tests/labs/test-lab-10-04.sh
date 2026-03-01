#!/usr/bin/env bash
# test-lab-10-04.sh — Lab 10-04: SSO Integration
# Module 10: FreePBX/Asterisk VoIP PBX
# freepbx with Keycloak OIDC/SAML authentication
set -euo pipefail

LAB_ID="10-04"
LAB_NAME="SSO Integration"
MODULE="freepbx"
COMPOSE_FILE="docker/docker-compose.sso.yml"
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
info "Phase 3: Functional Tests (Lab 04 — SSO Integration)"

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:5060/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

# ── 3a: Keycloak realm + OIDC client ─────────────────────────────────────────
info "Creating it-stack realm and freepbx OIDC client via Keycloak API..."

KC_TOKEN=$(curl -sf -X POST "http://localhost:8440/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=Admin04!" \
  | grep -o '"access_token":"[^"]*' | cut -d'"' -f4 || echo "")

if [ -n "${KC_TOKEN}" ]; then
  pass "Keycloak admin token obtained"
else
  fail "Failed to get Keycloak admin token"
  KC_TOKEN=""
fi

if [ -n "${KC_TOKEN}" ]; then
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "http://localhost:8440/admin/realms" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack Lab"}' || echo "000")
  if [ "${HTTP_STATUS}" = "201" ] || [ "${HTTP_STATUS}" = "409" ]; then
    pass "Keycloak it-stack realm created (status: ${HTTP_STATUS})"
  else
    fail "Failed to create it-stack realm (status: ${HTTP_STATUS})"
  fi
fi

if [ -n "${KC_TOKEN}" ]; then
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "http://localhost:8440/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"clientId":"freepbx","enabled":true,"protocol":"openid-connect","publicClient":false,"redirectUris":["http://localhost:8340/*"]}' || echo "000")
  if [ "${HTTP_STATUS}" = "201" ] || [ "${HTTP_STATUS}" = "409" ]; then
    pass "Keycloak freepbx OIDC client created (status: ${HTTP_STATUS})"
  else
    fail "Failed to create freepbx OIDC client (status: ${HTTP_STATUS})"
  fi
fi

if curl -sf "http://localhost:8440/realms/it-stack/.well-known/openid-configuration" | grep -q 'issuer'; then
  pass "Keycloak OIDC discovery endpoint returns issuer"
else
  fail "Keycloak OIDC discovery endpoint missing issuer"
fi

# ── 3b: LDAP integration ──────────────────────────────────────────────────────
info "Testing LDAP integration..."

if docker exec freepbx-s04-ldap ldapsearch -x -H ldap://localhost \
     -b dc=lab,dc=local -D cn=admin,dc=lab,dc=local -w LdapLab04! \
     '(objectClass=*)' dn 2>/dev/null | grep -q 'dn:'; then
  pass "LDAP base DC dc=lab,dc=local has entries"
else
  fail "LDAP base DC search returned no entries"
fi

if docker exec freepbx-s04-app curl -sf http://freepbx-s04-kc:8080/realms/master > /dev/null 2>&1; then
  pass "Keycloak reachable from FreePBX container"
else
  fail "Keycloak not reachable from FreePBX container"
fi

if docker exec freepbx-s04-app env | grep -q 'LDAP_ENABLED=TRUE'; then
  pass "LDAP_ENABLED=TRUE set in FreePBX container"
else
  fail "LDAP_ENABLED not set in FreePBX container"
fi

if docker exec freepbx-s04-app env | grep -q 'LDAP_HOST=freepbx-s04-ldap'; then
  pass "LDAP_HOST correctly set to freepbx-s04-ldap"
else
  fail "LDAP_HOST not set correctly in FreePBX container"
fi

# ── 3c: VoIP ports ────────────────────────────────────────────────────────────
if nc -z localhost 5164 2>/dev/null; then
  pass "SIP port 5164 reachable"
else
  warn "SIP port 5164 not yet reachable (FreePBX may still be initializing)"
fi

if nc -z localhost 5039 2>/dev/null; then
  pass "AMI port 5039 reachable"
else
  warn "AMI port 5039 not yet reachable"
fi

# ── 3d: All 5 containers running ──────────────────────────────────────────────
for svc in freepbx-s04-db freepbx-s04-ldap freepbx-s04-kc freepbx-s04-mail freepbx-s04-app; do
  if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
    pass "Container ${svc} running"
  else
    fail "Container ${svc} not running"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "  Lab ${LAB_ID} Complete"
echo -e "  ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}============================================================${NC}"

# Cleanup
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
