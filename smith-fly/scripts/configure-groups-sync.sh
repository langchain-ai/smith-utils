#!/bin/bash

##############################################################################
# configure-groups-sync.sh — enable LangSmith SSO Groups Sync after install
#
# SSO Groups Sync is a per-provider setting on the SSO provider record and is set
# post-install (it is NOT a Helm value). This script:
#   1. Sets the org's SCIM group-name separator via the documented API (default ":").
#   2. Prints the manual UI steps to enable Groups Sync + the groups claim field,
#      since the provider-record toggle has no stable public API.
#
# Usage:
#   scripts/configure-groups-sync.sh <langsmith-endpoint> <org-admin-api-key> [separator]
#
#   <separator>  one of  :  -  _  (space)  &   (default ":")
#
# Self-signed local TLS: uses curl -k. Drop -k against a real CA.
##############################################################################

set -euo pipefail

ENDPOINT="${1:-}"
API_KEY="${2:-}"
SEPARATOR="${3:-:}"

if [ -z "$ENDPOINT" ] || [ -z "$API_KEY" ]; then
    echo "Usage: $0 <langsmith-endpoint> <org-admin-api-key> [separator]" >&2
    exit 1
fi

ENDPOINT="${ENDPOINT%/}"

echo "[groups-sync] Setting SCIM group-name separator to '${SEPARATOR}'..." >&2
for p in "/api/v1/orgs/current/info" "/v1/orgs/current/info"; do
    url="${ENDPOINT}${p}"
    resp="$(curl -sk -w '\n%{http_code}' -X PATCH "$url" \
        -H "X-Api-Key: ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"scim_group_name_separator\": \"${SEPARATOR}\"}" || true)"
    code="$(printf '%s' "$resp" | tail -n1)"
    if [ "$code" = "200" ] || [ "$code" = "204" ]; then
        echo "[groups-sync] Separator set (HTTP ${code}) via ${p}" >&2
        break
    fi
    echo "[groups-sync] HTTP ${code} at ${p}; trying next path if any..." >&2
done

cat <<'EOF'

==========================================================================
Finish enabling SSO Groups Sync in the LangSmith UI (no stable API):

  Settings → Members and roles → SSO Configuration → SSO Groups Sync
    1. Toggle "SSO Groups Sync" ON.
    2. Set "Groups claim field" = groups
    3. Save.

Then confirm group naming matches Keycloak (created by realm-langsmith.json):
    LS:Organization Admins
    LS:Organization User:Production:Editor

A Keycloak user in "LS:Organization Admins" should land as an org admin on
next login; a user in "LS:Organization User:Production:Editor" as an editor
in the Production workspace.
==========================================================================
EOF
