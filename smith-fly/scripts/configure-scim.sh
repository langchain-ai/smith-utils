#!/bin/bash

##############################################################################
# configure-scim.sh — register LangSmith as an outbound SCIM target in the local
# Keycloak (mitodl/keycloak-scim extension). Creates the SCIM User Federation
# provider on the `langsmith` realm and enables the `scim` event listener.
#
# Run this AFTER, in order:
#   1. scripts/keycloak.sh up --ls-host <h> --kc-host <h>   (with SCIM_JAR set so
#      the mitodl extension is loaded)
#   2. ./smith-fly.sh up -l --auth keycloak --provisioning scim   (LangSmith up)
#   3. a SCIM bearer token minted via scripts/scim-token.sh
#
# Reachability (local minikube): Keycloak runs in Docker and must reach LangSmith's
# SCIM resource endpoint, served by platform-backend on :1986 at /scim/v2. Expose it
# to the Keycloak container via the host gateway with a port-forward:
#   kubectl port-forward svc/langsmith-platform-backend -n <namespace> 1986:1986
# then the container reaches it at http://host.docker.internal:1986/scim/v2 (the
# default below). On EKS/prod, pass --scim-endpoint https://<host>/scim/v2 instead
# and ensure the IdP->/scim/v2 network path is open.
#
# Usage:
#   scripts/configure-scim.sh --token <scim-bearer-token> \
#       [--scim-endpoint http://host.docker.internal:1986/scim/v2] \
#       [--kc-host host.minikube.internal] [--kc-port 8443]
#
# Env: KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD (default admin/admin), REALM (langsmith).
#
# NOTE (Keycloak 26.x): the mitodl extension loads and handles create/update/deactivate,
# but its hard-DELETE handler NPEs on 26.x (it reads the already-deleted user model).
# Deprovision by DISABLING users in Keycloak (propagates as active=false), not deleting.
##############################################################################

set -euo pipefail

REALM="${REALM:-langsmith}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"

TOKEN=""
SCIM_ENDPOINT="http://host.docker.internal:1986/scim/v2"
KC_HOST="host.minikube.internal"
KC_PORT="8443"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[scim]${NC} $*"; }
warn() { echo -e "${YELLOW}[scim]${NC} $*"; }
err()  { echo -e "${RED}[scim]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[scim]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 --token <scim-bearer-token> [options]

  --token          LangSmith SCIM bearer token (from scripts/scim-token.sh). Required.
  --scim-endpoint  SCIM resource URL Keycloak pushes to.
                   Default: ${SCIM_ENDPOINT}
  --kc-host        Keycloak host. Default: ${KC_HOST}
  --kc-port        Keycloak HTTPS port. Default: ${KC_PORT}
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --token) TOKEN="$2"; shift 2 ;;
        --scim-endpoint) SCIM_ENDPOINT="$2"; shift 2 ;;
        --kc-host) KC_HOST="$2"; shift 2 ;;
        --kc-port) KC_PORT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
done

[ -z "$TOKEN" ] && { err "--token is required (mint one with scripts/scim-token.sh)"; usage; }

BASE="https://${KC_HOST}:${KC_PORT}"
# Keycloak is published on the host loopback; resolve its hostname there so this works
# whether or not the host has an /etc/hosts entry for it.
RSV="${KC_HOST}:${KC_PORT}:127.0.0.1"
KC() { curl -sk --resolve "$RSV" "$@"; }

log "Authenticating to Keycloak admin API (${BASE})..."
ADM=$(KC -X POST "${BASE}/realms/master/protocol/openid-connect/token" \
    -d client_id=admin-cli -d "username=${KEYCLOAK_ADMIN}" -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d grant_type=password | jq -r '.access_token // empty')
[ -z "$ADM" ] && { err "Could not get Keycloak admin token"; exit 1; }

REALMID=$(KC "${BASE}/admin/realms/${REALM}" -H "Authorization: Bearer $ADM" | jq -r '.id // empty')
[ -z "$REALMID" ] && { err "Realm '${REALM}' not found"; exit 1; }

# Verify the scim provider is actually loaded (extension JAR present).
if ! KC "${BASE}/admin/realms/${REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
     -H "Authorization: Bearer $ADM" >/dev/null 2>&1; then
    warn "Could not query components; continuing anyway."
fi

# Replace any existing langsmith-scim provider (idempotent re-runs).
EXIST=$(KC "${BASE}/admin/realms/${REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
    -H "Authorization: Bearer $ADM" | jq -r '.[] | select(.name=="langsmith-scim") | .id')
if [ -n "$EXIST" ]; then
    log "Removing existing langsmith-scim provider..."
    KC -X DELETE "${BASE}/admin/realms/${REALM}/components/${EXIST}" -H "Authorization: Bearer $ADM" >/dev/null
fi

log "Creating SCIM User Federation provider (endpoint: ${SCIM_ENDPOINT})..."
CC=$(KC -o /dev/null -w '%{http_code}' -X POST "${BASE}/admin/realms/${REALM}/components" \
    -H "Authorization: Bearer $ADM" -H "Content-Type: application/json" \
    -d "{\"name\":\"langsmith-scim\",\"providerId\":\"scim\",\"providerType\":\"org.keycloak.storage.UserStorageProvider\",\"parentId\":\"${REALMID}\",\"config\":{\"endpoint\":[\"${SCIM_ENDPOINT}\"],\"auth-mode\":[\"BEARER\"],\"auth-pass\":[\"${TOKEN}\"],\"content-type\":[\"application/scim+json\"],\"propagation-user\":[\"true\"],\"propagation-group\":[\"true\"],\"sync-import\":[\"false\"]}}")
if [ "$CC" != "201" ]; then
    err "Failed to create SCIM provider (HTTP ${CC}). Is the SCIM extension JAR loaded? (SCIM_JAR on keycloak.sh up)"
    exit 1
fi
ok "SCIM federation provider 'langsmith-scim' created"

log "Enabling the 'scim' event listener on realm '${REALM}'..."
LIST=$(KC "${BASE}/admin/realms/${REALM}" -H "Authorization: Bearer $ADM" | jq -c '(.eventsListeners + ["scim"]) | unique')
PC=$(KC -o /dev/null -w '%{http_code}' -X PUT "${BASE}/admin/realms/${REALM}" \
    -H "Authorization: Bearer $ADM" -H "Content-Type: application/json" -d "{\"eventsListeners\": ${LIST}}")
[ "$PC" = "204" ] && ok "Event listener enabled (listeners: ${LIST})" || warn "Listener update returned HTTP ${PC}"

echo ""
ok "SCIM target configured. Test it:"
echo "  - Create/disable a user in Keycloak (realm ${REALM})."
echo "  - Watch the push:   docker logs -f smith-fly-keycloak 2>&1 | grep -i scim"
echo "  - Read back:        GET <scim-endpoint>/Users  (Authorization: Bearer <token>)"
echo ""
warn "Hard-deleting a Keycloak user does NOT propagate on KC 26.x (extension NPE) — disable users to deprovision."
