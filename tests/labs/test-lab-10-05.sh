#!/usr/bin/env bash
# test-lab-10-05.sh — Lab 10-05: Advanced Integration (INT-09 + INT-10 + INT-11)
# Module 10: FreePBX/Asterisk VoIP PBX
# Integrations: FreePBX ↔ SuiteCRM CTI (INT-09)
#               FreePBX → Zammad phone tickets (INT-10)
#               FreePBX ↔ FreeIPA extension provisioning (INT-11)
# Services: MariaDB · OpenLDAP · ldap-seed (init) · Keycloak · WireMock · Mailhog · FreePBX
# Ports:    Web:8360  SIP:5165  AMI:5040  WireMock:8361  KC:8460  LDAP:3894  MH:8660
# Phases:   1-Setup  2-Health  3-LDAPSeed  4-Keycloak  5-FreePBX  6-SuiteCRMCTI  7-Zammad  8-Volumes  9-FreeIPASync
set -euo pipefail

LAB_ID="10-05"
LAB_NAME="Advanced Integration (INT-09 + INT-10 + INT-11)"
MODULE="freepbx"
COMPOSE_FILE="docker/docker-compose.integration.yml"
MOCK_URL="http://localhost:8361"
KC_URL="http://localhost:8460"
LDAP_PORT=3894
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
echo -e "${CYAN}  FreePBX ↔ SuiteCRM CTI (click-to-call + call logging)${NC}"
echo -e "${CYAN}  + LDAP seed (pbxadmin/pbxuser1/pbxuser2) + KC federation${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Setup
# ═══════════════════════════════════════════════════════════════════════════════
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 90s for integration stack to initialize..."
sleep 90

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: Container Health Checks
# ═══════════════════════════════════════════════════════════════════════════════
section "Phase 2: Container Health"

for svc in freepbx-i05-db freepbx-i05-ldap freepbx-i05-kc freepbx-i05-mock freepbx-i05-mail freepbx-i05-app; do
  if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
    pass "Container ${svc} running"
  else
    fail "Container ${svc} not running"
  fi
done

# LDAP seed init container should have exited cleanly
SEED_STATUS=$(docker inspect --format='{{.State.ExitCode}}' freepbx-i05-ldap-seed 2>/dev/null || echo "missing")
if [[ "$SEED_STATUS" == "0" ]]; then
  pass "LDAP seed container exited successfully (exit 0)"
else
  fail "LDAP seed container exit status: ${SEED_STATUS} (expected 0)"
fi

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

# Keycloak health/ready loop (30 × 10s = 300s)
info "Waiting for Keycloak /health/ready (up to 300s)..."
KC_READY=false
for i in $(seq 1 30); do
  if curl -sf "${KC_URL}/health/ready" 2>/dev/null | grep -q '"status".*"UP"'; then
    KC_READY=true; break
  fi
  sleep 10
done
if [ "${KC_READY}" = "true" ]; then
  pass "Keycloak /health/ready: UP"
else
  fail "Keycloak /health/ready: not UP after 300s"
fi

# FreePBX web loop (20 × 10s = 200s)
info "Waiting for FreePBX web (:8360) ..."
FPX_READY=false
for i in $(seq 1 20); do
  if curl -sf http://localhost:8360/admin/config.php > /dev/null 2>&1; then
    FPX_READY=true; break
  fi
  sleep 10
done
if [ "${FPX_READY}" = "true" ]; then
  pass "FreePBX admin web accessible (:8360)"
else
  fail "FreePBX admin web not accessible (:8360)"
fi

if curl -sf http://localhost:8660/api/v2/messages > /dev/null 2>&1; then
  pass "Mailhog accessible (:8660)"
else
  warn "Mailhog not accessible (:8660) — non-critical"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: LDAP Seed Verification
# ═══════════════════════════════════════════════════════════════════════════════
section "Phase 3: LDAP Seed Verification"

USERS_COUNT=$(ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
  -D "cn=admin,dc=lab,dc=local" -w "LdapLab05!" \
  -b "cn=users,cn=accounts,dc=lab,dc=local" "(objectClass=inetOrgPerson)" uid \
  2>/dev/null | grep -c "^uid:" || echo "0")
[[ "${USERS_COUNT}" -ge 3 ]] \
  && pass "LDAP seed: ${USERS_COUNT} inetOrgPerson users (>= 3)" \
  || fail "LDAP seed: only ${USERS_COUNT} users in cn=users,cn=accounts (expected >= 3)"

GROUPS_COUNT=$(ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
  -D "cn=admin,dc=lab,dc=local" -w "LdapLab05!" \
  -b "cn=groups,cn=accounts,dc=lab,dc=local" "(objectClass=groupOfNames)" cn \
  2>/dev/null | grep -c "^cn:" || echo "0")
[[ "${GROUPS_COUNT}" -ge 2 ]] \
  && pass "LDAP seed: ${GROUPS_COUNT} groups (>= 2)" \
  || fail "LDAP seed: only ${GROUPS_COUNT} groups (expected >= 2)"

PBXADMIN_COUNT=$(ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
  -D "cn=admin,dc=lab,dc=local" -w "LdapLab05!" \
  -b "cn=users,cn=accounts,dc=lab,dc=local" "(uid=pbxadmin)" uid telephoneNumber \
  2>/dev/null | grep -c "^uid:" || echo "0")
[[ "${PBXADMIN_COUNT}" -ge 1 ]] \
  && pass "LDAP seed: pbxadmin user present" \
  || fail "LDAP seed: pbxadmin user not found"

ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
  -D "cn=readonly,dc=lab,dc=local" -w "ReadOnly05!" \
  -b "dc=lab,dc=local" -s base "(objectClass=*)" >/dev/null 2>&1 \
  && pass "LDAP readonly bind successful" \
  || fail "LDAP readonly bind failed"

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: Keycloak LDAP Federation + OIDC Client
# ═══════════════════════════════════════════════════════════════════════════════
section "Phase 4: Keycloak LDAP Federation + OIDC Client"

KC_TOKEN=$(curl -sf "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=Admin05!" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
[[ -n "$KC_TOKEN" ]] \
  && pass "Keycloak admin token obtained" \
  || { fail "Keycloak admin token failed"; }

if [[ -n "$KC_TOKEN" ]]; then
  # Realm it-stack
  REALM_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${KC_URL}/admin/realms" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack"}')
  [[ "$REALM_HTTP" =~ ^(201|409)$ ]] \
    && pass "Realm it-stack created/exists (HTTP $REALM_HTTP)" \
    || fail "Realm it-stack creation failed (HTTP $REALM_HTTP)"

  # LDAP federation (FreeIPA-style, vendor=rhds)
  LDAP_COMP_PAYLOAD=$(cat <<'EOLDAP'
{
  "name": "freepbx-lab-ldap",
  "providerId": "ldap",
  "providerType": "org.keycloak.storage.UserStorageProvider",
  "config": {
    "enabled": ["true"],
    "priority": ["0"],
    "vendor": ["rhds"],
    "connectionUrl": ["ldap://freepbx-i05-ldap:389"],
    "bindDn": ["cn=readonly,dc=lab,dc=local"],
    "bindCredential": ["ReadOnly05!"],
    "usersDn": ["cn=users,cn=accounts,dc=lab,dc=local"],
    "userObjectClasses": ["inetOrgPerson"],
    "usernameLDAPAttribute": ["uid"],
    "uuidLDAPAttribute": ["uid"],
    "rdnLDAPAttribute": ["uid"],
    "searchScope": ["1"],
    "syncRegistrations": ["true"],
    "importEnabled": ["true"],
    "batchSizeForSync": ["100"],
    "editMode": ["READ_ONLY"],
    "pagination": ["true"]
  }
}
EOLDAP
)
  COMP_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${KC_URL}/admin/realms/it-stack/components" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$LDAP_COMP_PAYLOAD")
  [[ "$COMP_HTTP" =~ ^(201|409)$ ]] \
    && pass "Keycloak LDAP federation 'freepbx-lab-ldap' created/exists (HTTP $COMP_HTTP)" \
    || fail "Keycloak LDAP federation creation failed (HTTP $COMP_HTTP)"

  # Full LDAP sync
  KC_COMP_ID=$(curl -sf \
    "${KC_URL}/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
    -H "Authorization: Bearer $KC_TOKEN" \
    | python3 -c "import sys,json; comps=json.load(sys.stdin); print(comps[0]['id'] if comps else '')" 2>/dev/null || echo "")
  if [[ -n "$KC_COMP_ID" ]]; then
    SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "${KC_URL}/admin/realms/it-stack/user-storage/${KC_COMP_ID}/sync?action=triggerFullSync" \
      -H "Authorization: Bearer $KC_TOKEN")
    [[ "$SYNC_HTTP" == "200" ]] \
      && pass "Keycloak triggered LDAP full sync (HTTP $SYNC_HTTP)" \
      || fail "Keycloak LDAP full sync failed (HTTP $SYNC_HTTP)"

    KC_USER_COUNT=$(curl -sf "${KC_URL}/admin/realms/it-stack/users" \
      -H "Authorization: Bearer $KC_TOKEN" \
      | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    [[ "${KC_USER_COUNT}" -ge 3 ]] \
      && pass "Keycloak LDAP sync: ${KC_USER_COUNT} users in realm (>= 3)" \
      || fail "Keycloak LDAP sync: only ${KC_USER_COUNT} users (expected >= 3)"

    # pbxadmin present after sync
    PBXADMIN_KC=$(curl -sf "${KC_URL}/admin/realms/it-stack/users?username=pbxadmin" \
      -H "Authorization: Bearer $KC_TOKEN" \
      | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    [[ "${PBXADMIN_KC}" -ge 1 ]] \
      && pass "Keycloak: pbxadmin synced from LDAP" \
      || fail "Keycloak: pbxadmin not found after LDAP sync"
  else
    fail "Could not retrieve Keycloak LDAP component ID for sync"
  fi

  # Register OIDC client 'freepbx'
  OIDC_CLIENT_PAYLOAD=$(cat <<'EOOIDC'
{
  "clientId": "freepbx",
  "name": "FreePBX OIDC",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "redirectUris": ["http://localhost:8360/*"],
  "webOrigins": ["http://localhost:8360"]
}
EOOIDC
)
  OIDC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${KC_URL}/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$OIDC_CLIENT_PAYLOAD")
  [[ "$OIDC_HTTP" =~ ^(201|409)$ ]] \
    && pass "Keycloak OIDC client 'freepbx' created/exists (HTTP $OIDC_HTTP)" \
    || fail "Keycloak OIDC client creation failed (HTTP $OIDC_HTTP)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5: FreePBX Service Ports
# ═══════════════════════════════════════════════════════════════════════════════
section "Phase 5: FreePBX Service Ports"

# AMI port (exposed as 5040)
AMI_OPEN=$(docker exec freepbx-i05-app nc -z localhost 5038 2>/dev/null && echo "open" || echo "closed")
if [[ "$AMI_OPEN" == "open" ]]; then
  pass "AMI port 5038 reachable inside FreePBX container"
else
  warn "AMI port 5038 not yet open (Asterisk may still be loading)"
fi

# SIP port internal check
SIP_OPEN=$(docker exec freepbx-i05-app nc -z localhost 5060 2>/dev/null && echo "open" || echo "closed")
if [[ "$SIP_OPEN" == "open" ]]; then
  pass "SIP port 5060 reachable inside FreePBX container"
else
  warn "SIP port 5060 not yet open"
fi

# FreePBX web admin responds
if curl -sf http://localhost:8360/admin/config.php > /dev/null 2>&1; then
  pass "FreePBX admin web (:8360) confirms responsive"
else
  fail "FreePBX admin web (:8360) not responding"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 6: SuiteCRM CTI WireMock Stubs (INT-09)
# ═══════════════════════════════════════════════════════════════════════════════
section "Phase 6: SuiteCRM CTI WireMock Stubs (INT-09)"

info "Registering WireMock stubs for SuiteCRM CTI API..."

# SuiteCRM calls/save stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "urlPathPattern": "/index.php.*module=Calls.*"},
    "response": {"status": 200,
                 "body": "{\"result\":{\"id\":\"call-001\",\"status\":\"success\"}}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
[ "${HTTP_STATUS}" = "201" ] \
  && pass "WireMock stub: SuiteCRM calls/save registered" \
  || fail "WireMock stub: SuiteCRM calls/save failed (HTTP $HTTP_STATUS)"

# SuiteCRM contacts/lookup stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "GET", "urlPathPattern": "/index.php.*module=Contacts.*"},
    "response": {"status": 200,
                 "body": "{\"result\":[{\"id\":\"contact-001\",\"name\":\"pbxuser1\",\"phone\":\"101\"}]}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
[ "${HTTP_STATUS}" = "201" ] \
  && pass "WireMock stub: SuiteCRM contacts/lookup registered" \
  || fail "WireMock stub: SuiteCRM contacts/lookup failed (HTTP $HTTP_STATUS)"

# Verify calls/save mock responds
if curl -sf -X POST \
     "${MOCK_URL}/index.php?module=Calls&action=Save" \
     -H "Content-Type: application/json" \
     -d '{"name":"TestCall","duration_hours":0,"duration_minutes":1,"status":"Held"}' \
     | grep -q 'call-001'; then
  pass "WireMock SuiteCRM calls/save returns call-001"
else
  fail "WireMock SuiteCRM calls/save not responding correctly"
fi

# Verify contacts/lookup mock responds
if curl -sf "${MOCK_URL}/index.php?module=Contacts&action=index&searchFormTab=basic_search&query=true&phone=101" \
     | grep -q 'contact-001'; then
  pass "WireMock SuiteCRM contacts/lookup returns contact-001"
else
  fail "WireMock SuiteCRM contacts/lookup not responding correctly"
fi

# FreePBX container → WireMock (SuiteCRM mock) reachable
if docker exec freepbx-i05-app curl -sf \
     "http://freepbx-i05-mock:8080/index.php?module=Contacts&action=index" \
     > /dev/null 2>&1; then
  pass "FreePBX container → WireMock (SuiteCRM mock) reachable"
else
  fail "FreePBX container cannot reach WireMock (SuiteCRM mock)"
fi

# Integration env vars
for envvar in "SUITECRM_URL=http://freepbx-i05-mock" "SUITECRM_API_KEY=lab-integration-key-05" "SUITECRM_CALLS_ENDPOINT=/index.php" "SUITECRM_CONTACTS_ENDPOINT=/index.php"; do
  KEY="${envvar%%=*}"
  VAL="${envvar#*=}"
  if docker exec freepbx-i05-app env | grep -q "${KEY}=${VAL}"; then
    pass "Env: ${KEY} set correctly"
  else
    fail "Env: ${KEY} not set or wrong value in FreePBX container"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 7: Zammad Webhook WireMock Stub
# ═══════════════════════════════════════════════════════════════════════════════
section "Phase 7: Zammad Webhook WireMock Stub"

HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "url": "/api/v1/tickets"},
    "response": {"status": 201,
                 "body": "{\"id\":1001,\"title\":\"Call from FreePBX\",\"state\":\"new\"}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
[ "${HTTP_STATUS}" = "201" ] \
  && pass "WireMock stub: Zammad ticket POST registered" \
  || fail "WireMock stub: Zammad ticket POST failed (HTTP $HTTP_STATUS)"

if curl -sf -X POST "${MOCK_URL}/api/v1/tickets" \
     -H "Content-Type: application/json" \
     -d '{"title":"Test call from FreePBX","customer":"ext101"}' \
     | grep -q '"id"'; then
  pass "WireMock Zammad tickets endpoint responds correctly"
else
  fail "WireMock Zammad tickets endpoint not responding"
fi

if docker exec freepbx-i05-app env | grep -q 'ZAMMAD_WEBHOOK_URL=http://freepbx-i05-mock'; then
  pass "ZAMMAD_WEBHOOK_URL env var set correctly"
else
  fail "ZAMMAD_WEBHOOK_URL not set in FreePBX container"
fi

if docker exec freepbx-i05-app curl -sf \
     "http://freepbx-i05-mock:8080/api/v1/tickets" \
     -X POST -H "Content-Type: application/json" \
     -d '{"title":"PhoneCall","state":"new"}' > /dev/null 2>&1; then
  pass "FreePBX container → WireMock Zammad webhook reachable"
else
  fail "FreePBX container cannot reach WireMock Zammad webhook"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 8: Volume Assertions + Summary Env Check
# ═══════════════════════════════════════════════════════════════════════════════
section "Phase 8: Volume Assertions + Env Summary"

# WireMock stubs count (expect at least 3: calls/save, contacts, zammad tickets)
MAPPING_COUNT=$(curl -sf "${MOCK_URL}/__admin/mappings" | grep -o '"id"' | wc -l || echo 0)
if [ "${MAPPING_COUNT}" -ge 3 ]; then
  pass "WireMock has ${MAPPING_COUNT} stubs registered (expected ≥3)"
else
  fail "WireMock only has ${MAPPING_COUNT} stubs (expected ≥3)"
fi

# Declared Docker volumes present
for vol in freepbx-i05-mariadb-data freepbx-i05-asterisk-config freepbx-i05-asterisk-sounds; do
  if docker volume inspect "${vol}" >/dev/null 2>&1; then
    pass "Docker volume ${vol} present"
  else
    warn "Docker volume ${vol} not found (may vary by compose version)"
  fi
done

# Core env checks
for envkey in DB_HOST LDAP_ENABLED KEYCLOAK_URL; do
  if docker exec freepbx-i05-app env | grep -q "^${envkey}="; then
    pass "Env: ${envkey} defined"
  else
    warn "Env: ${envkey} not set in FreePBX container"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 9: FreeIPA LDAP Extension Provisioning (INT-11)
# ═══════════════════════════════════════════════════════════════════════════════
section "Phase 9: FreeIPA LDAP Extension Provisioning (INT-11)"

FREEIPA_LDAP_PORT=3894
FREEIPA_BIND_DN_R="cn=readonly,dc=lab,dc=local"
FREEIPA_BIND_PW_R="ReadOnly05!"
FREEIPA_BASE_DN_R="cn=users,cn=accounts,dc=lab,dc=local"

# 9.1 -- LDAP port accessible
if nc -z localhost "${FREEIPA_LDAP_PORT}" 2>/dev/null; then
  pass "INT-11: FreeIPA-style LDAP :${FREEIPA_LDAP_PORT} accessible"
else
  fail "INT-11: FreeIPA-style LDAP :${FREEIPA_LDAP_PORT} not accessible"
fi

# 9.2 -- Users with telephoneNumber found via docker exec LDAP search
if docker exec freepbx-i05-ldap ldapsearch -x \
     -H ldap://localhost \
     -D "${FREEIPA_BIND_DN_R}" -w "${FREEIPA_BIND_PW_R}" \
     -b "${FREEIPA_BASE_DN_R}" \
     '(telephoneNumber=*)' uid telephoneNumber -LLL 2>/dev/null \
   | grep -q '^uid:'; then
  pass "INT-11: Users with telephoneNumber found in FreeIPA-style LDAP"
else
  fail "INT-11: No users with telephoneNumber found in FreeIPA-style LDAP"
fi

# 9.3 -- Specific extensions present (100, 101, 102)
for uid_exten in "pbxadmin:100" "pbxuser1:101" "pbxuser2:102"; do
  uid_val="${uid_exten%%:*}"
  exten_val="${uid_exten##*:}"
  if docker exec freepbx-i05-ldap ldapsearch -x \
       -H ldap://localhost \
       -D "${FREEIPA_BIND_DN_R}" -w "${FREEIPA_BIND_PW_R}" \
       -b "${FREEIPA_BASE_DN_R}" \
       "(uid=${uid_val})" telephoneNumber -LLL 2>/dev/null \
     | grep -q "telephoneNumber: ${exten_val}"; then
    pass "INT-11: uid=${uid_val} has telephoneNumber=${exten_val}"
  else
    fail "INT-11: uid=${uid_val} telephoneNumber=${exten_val} not found"
  fi
done

# 9.4 -- FreePBX env vars for FreeIPA LDAP sync
for envkey in FREEIPA_LDAP_URL FREEIPA_BIND_DN FREEIPA_BASE_DN FREEIPA_EXTEN_ATTR; do
  if docker exec freepbx-i05-app env 2>/dev/null | grep -q "^${envkey}="; then
    pass "INT-11: Env ${envkey} set in FreePBX container"
  else
    warn "INT-11: Env ${envkey} not set in FreePBX container (expected from compose INT-11)"
  fi
done

# 9.5 -- FreePBX container can reach LDAP server
if docker exec freepbx-i05-app sh -c \
     'nc -z freepbx-i05-ldap 389 2>/dev/null && echo ok' 2>/dev/null \
   | grep -q ok; then
  pass "INT-11: FreePBX container can reach OpenLDAP (FreeIPA proxy) :389"
else
  fail "INT-11: FreePBX container cannot reach OpenLDAP :389"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "  Lab ${LAB_ID}: INT-09 + INT-10 + INT-11 Complete"
echo -e "  INT-09: FreePBX \u2194 SuiteCRM CTI"
echo -e "  INT-10: FreePBX \u2192 Zammad phone tickets"
echo -e "  INT-11: FreePBX \u2194 FreeIPA extension provisioning"
echo -e "  ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}============================================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
