#!/bin/bash

##############################################################################
# keycloak.sh — local Keycloak (Docker) for smith-fly OAuth/OIDC + SCIM
#
# Brings up a Keycloak instance over HTTPS that LangSmith Self-Hosted can use as
# an OIDC provider (--auth keycloak), importing keycloak/realm-langsmith.json.
#
# Usage:
#   scripts/keycloak.sh up   --ls-host <langsmith-host> [--kc-host <keycloak-host>]
#   scripts/keycloak.sh down
#
# Key env vars (override as needed):
#   KEYCLOAK_IMAGE          default quay.io/keycloak/keycloak:26.6
#   KEYCLOAK_ADMIN          default admin
#   KEYCLOAK_ADMIN_PASSWORD default admin
#   OAUTH_CLIENT_SECRET     client secret to bake into the realm (generated if unset)
#   SCIM_JAR                path to the outbound-SCIM extension JAR (mitodl/keycloak-scim).
#                           Only needed for --provisioning scim. Mounted into
#                           /opt/keycloak/providers/. See docs/keycloak-oauth-scim.md §3.
#   KC_HTTPS_PORT           default 8443
#
# Issuer reachability (§5.2): KC_HOSTNAME is pinned so issued tokens carry the
# exact issuer string LangSmith validates against. The LangSmith pods must be able
# to resolve <kc-host> to this container (e.g. host.minikube.internal, or a shared
# *.nip.io name). Set KEYCLOAK_ISSUER_URL in config/.env to the value printed below.
#
# TLS trust (§5.1): this is self-signed. LangSmith's platform-backend must trust the
# Keycloak cert for server-to-server JWKS/token fetches, and Keycloak must trust the
# LangSmith cert for the outbound SCIM push. For local dev the simplest path is to
# mount each CA into the other (documented in the README); production uses real CAs.
##############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REALM_SRC="${REPO_DIR}/keycloak/realm-langsmith.json"

CONTAINER_NAME="smith-fly-keycloak"
KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.6}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KC_HTTPS_PORT="${KC_HTTPS_PORT:-8443}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[keycloak]${NC} $*"; }
warn() { echo -e "${YELLOW}[keycloak]${NC} $*"; }
err()  { echo -e "${RED}[keycloak]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[keycloak]${NC} $*"; }

usage() {
    cat <<EOF
Usage:
  $0 up   --ls-host <langsmith-host> [--kc-host <keycloak-host>]
  $0 down

  --ls-host   LangSmith host (no scheme), used for OAuth redirect/origin URIs,
              e.g. langsmith.192-168-49-2.nip.io
  --kc-host   Keycloak host (no scheme) that LangSmith pods + browser resolve to.
              Default: localhost
EOF
    exit 1
}

require_docker() {
    if ! command -v docker &>/dev/null; then
        err "docker is required but not found. Install Docker and retry."
        exit 1
    fi
}

down() {
    require_docker
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        log "Removing container ${CONTAINER_NAME}..."
        docker rm -f "$CONTAINER_NAME" >/dev/null
        ok "Keycloak container removed"
    else
        log "No ${CONTAINER_NAME} container running"
    fi
}

configure_groups_scope() {
    local kc_host="$1" port="$2"
    local base="https://${kc_host}:${port}"
    local rs="${kc_host}:${port}:127.0.0.1"

    log "Waiting for Keycloak realm to be ready..."
    local i token
    for i in $(seq 1 60); do
        if [ "$(curl -sk --resolve "$rs" -o /dev/null -w '%{http_code}' "${base}/realms/langsmith/.well-known/openid-configuration" 2>/dev/null)" = "200" ]; then
            break
        fi
        sleep 2
    done

    token=$(curl -sk --resolve "$rs" -X POST "${base}/realms/master/protocol/openid-connect/token" \
        -d client_id=admin-cli -d "username=${KEYCLOAK_ADMIN}" -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
        -d grant_type=password 2>/dev/null | jq -r '.access_token // empty')
    if [ -z "$token" ]; then
        warn "Could not get Keycloak admin token — 'groups' client scope NOT configured."
        warn "SSO Groups Sync will not work until it's added. Re-run this script or add it in the admin console."
        return 1
    fi

    # Create the groups client scope (idempotent: skip if it already exists).
    local scope_id
    scope_id=$(curl -sk --resolve "$rs" "${base}/admin/realms/langsmith/client-scopes" \
        -H "Authorization: Bearer $token" 2>/dev/null | jq -r '.[] | select(.name=="groups") | .id')
    if [ -z "$scope_id" ]; then
        log "Creating 'groups' client scope + group-membership mapper..."
        curl -sk --resolve "$rs" -X POST "${base}/admin/realms/langsmith/client-scopes" \
            -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
            -d '{"name":"groups","protocol":"openid-connect","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"},"protocolMappers":[{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","claim.name":"groups"}}]}' >/dev/null 2>&1
        scope_id=$(curl -sk --resolve "$rs" "${base}/admin/realms/langsmith/client-scopes" \
            -H "Authorization: Bearer $token" 2>/dev/null | jq -r '.[] | select(.name=="groups") | .id')
    fi

    # Assign 'groups' as a default client scope on the langsmith client.
    local cid
    cid=$(curl -sk --resolve "$rs" "${base}/admin/realms/langsmith/clients?clientId=langsmith" \
        -H "Authorization: Bearer $token" 2>/dev/null | jq -r '.[0].id // empty')
    if [ -n "$cid" ] && [ -n "$scope_id" ]; then
        curl -sk --resolve "$rs" -X PUT \
            "${base}/admin/realms/langsmith/clients/${cid}/default-client-scopes/${scope_id}" \
            -H "Authorization: Bearer $token" >/dev/null 2>&1
        ok "'groups' client scope created and assigned to client 'langsmith'"
    else
        warn "Could not assign 'groups' scope (client id='${cid}', scope id='${scope_id}')"
    fi
}

up() {
    local ls_host="" kc_host="localhost"
    while [ $# -gt 0 ]; do
        case "$1" in
            --ls-host) ls_host="$2"; shift 2 ;;
            --kc-host) kc_host="$2"; shift 2 ;;
            *) err "Unknown option: $1"; usage ;;
        esac
    done

    [ -z "$ls_host" ] && { err "--ls-host is required"; usage; }
    [ -f "$REALM_SRC" ] || { err "Realm file not found: ${REALM_SRC}"; exit 1; }
    require_docker

    # Client secret: reuse from env or generate one to print + bake into the realm.
    local client_secret="${OAUTH_CLIENT_SECRET:-}"
    if [ -z "$client_secret" ]; then
        client_secret="$(openssl rand -hex 24)"
    fi

    # Render the realm with host + secret substituted (never mutate the source file).
    local workdir
    workdir="$(mktemp -d)"
    local realm_rendered="${workdir}/realm-langsmith.json"
    sed -e "s/__LANGSMITH_HOST__/${ls_host}/g" \
        -e "s/__CLIENT_SECRET__/${client_secret}/g" \
        "$REALM_SRC" > "$realm_rendered"

    # Persistent self-signed cert. Re-running this script must NOT rotate the cert:
    # the LangSmith install bakes this cert into its CA-trust bundle (config.customCa),
    # and a rotated cert makes the platform-backend OIDC init fail x509 verification
    # and crash. Regenerate only if absent or the kc-host changed.
    local cert_dir="${REPO_DIR}/keycloak/.certs"
    mkdir -p "$cert_dir"
    if [ -f "${cert_dir}/kc.crt" ] && [ -f "${cert_dir}/kc.key" ] && \
       [ "$(cat "${cert_dir}/kc.host" 2>/dev/null)" = "$kc_host" ]; then
        log "Reusing existing Keycloak cert for ${kc_host} (${cert_dir}/kc.crt)"
    else
        log "Generating self-signed cert for Keycloak host ${kc_host}..."
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "${cert_dir}/kc.key" -out "${cert_dir}/kc.crt" \
            -days 365 -subj "/CN=${kc_host}" \
            -addext "subjectAltName=DNS:${kc_host},DNS:localhost" 2>/dev/null
        echo "$kc_host" > "${cert_dir}/kc.host"
    fi

    # Optional SCIM extension JAR (outbound). Only for --provisioning scim.
    local scim_mount=()
    if [ -n "${SCIM_JAR:-}" ]; then
        if [ -f "$SCIM_JAR" ]; then
            log "Mounting outbound-SCIM extension: ${SCIM_JAR}"
            scim_mount=(-v "$(cd "$(dirname "$SCIM_JAR")" && pwd)/$(basename "$SCIM_JAR"):/opt/keycloak/providers/$(basename "$SCIM_JAR"):ro")
        else
            warn "SCIM_JAR set but file not found: ${SCIM_JAR} — starting without it"
        fi
    fi

    down  # idempotent: clear any previous instance

    local issuer="https://${kc_host}:${KC_HTTPS_PORT}/realms/langsmith"
    log "Starting Keycloak (${KEYCLOAK_IMAGE})..."
    docker run -d --name "$CONTAINER_NAME" \
        -p "${KC_HTTPS_PORT}:8443" \
        -e KEYCLOAK_ADMIN="$KEYCLOAK_ADMIN" \
        -e KEYCLOAK_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD" \
        -e KC_HOSTNAME="https://${kc_host}:${KC_HTTPS_PORT}" \
        -e KC_HTTPS_CERTIFICATE_FILE=/opt/keycloak/conf/kc.crt \
        -e KC_HTTPS_CERTIFICATE_KEY_FILE=/opt/keycloak/conf/kc.key \
        -v "${realm_rendered}:/opt/keycloak/data/import/realm-langsmith.json:ro" \
        -v "${cert_dir}/kc.crt:/opt/keycloak/conf/kc.crt:ro" \
        -v "${cert_dir}/kc.key:/opt/keycloak/conf/kc.key:ro" \
        ${scim_mount[@]+"${scim_mount[@]}"} \
        "$KEYCLOAK_IMAGE" \
        start-dev --import-realm >/dev/null

    ok "Keycloak starting as container ${CONTAINER_NAME}"

    # Post-import: create the 'groups' client scope + group-membership mapper and
    # assign it to the langsmith client. Done via the admin API (not realm import)
    # because an explicit clientScopes array in the import suppresses Keycloak's
    # auto-creation of the built-in scopes (email/profile/roles/...), which LangSmith
    # needs. Without this, requesting the 'groups' scope fails with invalid_scope.
    configure_groups_scope "$kc_host" "$KC_HTTPS_PORT"

    echo ""
    echo "=========================================================================="
    echo -e "${BLUE}Add these to config/.env (for ./smith-fly.sh up -ld --auth keycloak):${NC}"
    echo ""
    echo "KEYCLOAK_ISSUER_URL=\"${issuer}\""
    echo "OAUTH_CLIENT_ID=\"langsmith\""
    echo "OAUTH_CLIENT_SECRET=\"${client_secret}\""
    echo ""
    echo -e "${BLUE}Admin console:${NC} https://${kc_host}:${KC_HTTPS_PORT}/admin/ (${KEYCLOAK_ADMIN}/${KEYCLOAK_ADMIN_PASSWORD})"
    echo -e "${BLUE}Seed users:${NC}   ls-admin / Passw0rd!  (LS:Organization Admins)"
    echo -e "             ls-editor / Passw0rd! (LS:Organization User:Production:Editor)"
    echo ""
    echo -e "${YELLOW}Ensure LangSmith pods can resolve '${kc_host}' to this container (§5.2).${NC}"
    echo "=========================================================================="
    echo ""

    if [ -n "${SCIM_JAR:-}" ]; then
        echo -e "${BLUE}SCIM extension loaded. After LangSmith is up, finish the outbound-SCIM setup:${NC}"
        echo "  1. kubectl port-forward svc/langsmith-platform-backend -n <ns> 1986:1986"
        echo "  2. ${SCRIPT_DIR}/scim-token.sh http://localhost:<frontend-pf-port> <org-admin-PAT>"
        echo "  3. ${SCRIPT_DIR}/configure-scim.sh --token <scim-token>"
        echo -e "  ${YELLOW}Note: on KC 26.x the extension does NOT propagate hard user deletes (NPE);${NC}"
        echo -e "  ${YELLOW}      disable users in Keycloak to deprovision (propagates as active=false).${NC}"
        echo ""
    fi

    log "Realm + certs staged in ${workdir} (safe to delete once the container is up)"
}

case "${1:-}" in
    up)   shift; up "$@" ;;
    down) down ;;
    *)    usage ;;
esac
