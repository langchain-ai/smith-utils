# Keycloak OAuth/OIDC + Toggleable Provisioning (SCIM ↔ SSO Groups Sync) for smith-fly

> **Status:** Implemented in `smith-fly.sh` (`--auth keycloak` / `--provisioning`),
> `keycloak/realm-langsmith.json`, and `scripts/{keycloak,scim-token,configure-groups-sync,configure-scim}.sh`.
> **Tested end-to-end on local minikube + Docker** (KC 26.6.4, chart 0.15.12): OAuth login,
> SSO Groups Sync (org + workspace roles), and SCIM create/update/deactivate all work. Known
> limitation: SCIM hard-delete does not propagate on KC 26.x (extension NPE — see §8).
> **Target:** Local-on-Docker first (minikube, docker driver), then AWS EKS.
> **Scope:** Add Keycloak OAuth login to smith-fly, plus a runtime flag to choose
> between **SSO Groups Sync** and **SCIM** for user/role provisioning into LangSmith.

---

## 1. Goal

1. **OAuth via Keycloak** — delegate LangSmith Self-Hosted login to Keycloak (OIDC,
   Authorization Code + Client Secret). smith-fly has **no** OAuth support today; we add it.
2. **Toggleable provisioning** — a single flag selects how org/workspace roles are
   provisioned into LangSmith:
   - `groups-sync` — LangSmith reads group claims from the Keycloak OIDC token at login.
   - `scim` — Keycloak pushes Users/Groups to LangSmith's SCIM endpoint (outbound).
3. Works **locally on Docker** (priority) and on **EKS** (same code path, different TLS/DNS).

---

## 2. Two corrections that shape the design

### 2.1 SCIM direction (important)

The Keycloak article that kicked this off
([SCIM Realm API as an Experimental Feature](https://www.keycloak.org/2026/04/scim-as-experimental-feature),
Keycloak 26.6, `--features=scim-api`) makes **Keycloak a SCIM _server_** — i.e. other
systems provision *into* Keycloak. That is the **opposite** of what we need.

Provisioning users/groups **into LangSmith** requires **Keycloak as a SCIM _client_**
(outbound push). Vanilla Keycloak — including 26.6 — does **not** do outbound SCIM yet
(it's on the roadmap, server-side prioritized first). So the SCIM path needs a community
extension:

- **Primary:** [mitodl/keycloak-scim](https://github.com/mitodl/keycloak-scim) — best-documented
  outbound SCIM 2.0 client; deploys as a fat JAR into `/opt/keycloak/providers/`, event-listener
  driven, exponential-backoff retry, eventual consistency.
- **Lightweight fallback:** [Termindiego25/keycloak-scim-outbound](https://github.com/Termindiego25/keycloak-scim-outbound)
  — admin-console configurable, group-based filtering.
- **Do NOT use** [Captain-P-Goldfish/scim-for-keycloak](https://github.com/Captain-P-Goldfish/scim-for-keycloak)
  for this — it's *inbound* (SCIM server) and the OSS version is EOL at kc-21.

Sources: [Keycloak SCIM survey feedback](https://www.keycloak.org/2026/02/scim-support-survey-feedback),
[SCIM Realm API article](https://www.keycloak.org/2026/04/scim-as-experimental-feature).

### 2.2 Both modes share one OIDC + group-naming foundation

SSO Groups Sync and SCIM both map to LangSmith roles via the **same** group-naming
convention and separator. So **OAuth is the common base layer**, and provisioning mode is
a switch layered on top — not two independent integrations.

**Group naming convention** (LangSmith side, identical for both modes):

- Org admins: `LS:Organization Admins` (or `LS:OrganizationAdmins` — spaces may be omitted
  in the **org-role token** for IdPs that disallow spaces).
- Workspace-scoped: `<prefix><org_role><sep><workspace_name><sep><workspace_role>`
  - e.g. `LS:Organization User:Production:Editor`, `LS:Organization User:Engineering:Admin`.
- Separator defaults to `:`; configurable per-org (`:` `-` `_` ` ` `&`) via
  `PATCH /api/v1/orgs/current/info` with `{"scim_group_name_separator": "-"}`.
- Workspace names/roles treat spaces literally; only the org-role token is space-flexible.
- Renaming groups is **not** supported via SCIM (names are persistent, must match LangSmith).

---

## 3. Current state of smith-fly (where we hook in)

| Area | Today | File / location |
|---|---|---|
| Auth | `authType: mixed` + `basicAuth.enabled: true`, hardcoded. No OAuth/SCIM/Keycloak. | `config/config.yaml`, `langsmith-config.yaml` |
| Flag parsing | Hand-rolled `case` over `-l/-ld/-ld[aip]/-v/-n/-i/--debug/--config-dir` | `parse_arguments()` — `smith-fly.sh:498` |
| Config injection | base `config.yaml` → copy to `ls_config.yaml` → `sed` values in → `helm upgrade --install` | `create_langsmith_config()` — `smith-fly.sh:1107`; `install_langsmith()` — `smith-fly.sh:1208` |
| Secret handling | `generate_secrets()` / `load_existing_secrets()` (preserved across upgrades) | `smith-fly.sh:1001`, `:1041` |
| Version guards | `is_version_v15_plus` gate for Fleet/Insights/Polly | `parse_arguments()` ~`:626` |

The script already uses both `sed -i` value replacement **and** temp-file insert
(`/anchor/r tempfile`) and `--set` flags — we reuse those same patterns for the OAuth block.

---

## 4. Proposed CLI surface

```bash
# Base auth unchanged (default): basic auth
./smith-fly.sh up -ld

# OAuth via Keycloak, no provisioning automation
./smith-fly.sh up -ld --auth keycloak

# OAuth + SSO Groups Sync
./smith-fly.sh up -ld --auth keycloak --provisioning groups-sync

# OAuth + SCIM (outbound from Keycloak)
./smith-fly.sh up -ld --auth keycloak --provisioning scim
```

**New flags / globals (in `parse_arguments()`):**

- `--auth basic|keycloak` (default `basic`). `keycloak` swaps the basicAuth block for the oauth block.
- `--provisioning none|groups-sync|scim` (default `none`). The toggle. Requires `--auth keycloak`.
- New globals: `AUTH_MODE`, `PROVISIONING_MODE`.
- Keycloak coordinates read from `config/.env`: `KEYCLOAK_ISSUER_URL`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` (+ optional `OAUTH_SCOPES`).

**Validation rules:**

- `--provisioning groups-sync|scim` with `--auth basic` → error.
- `--auth keycloak` missing any of the three `.env` values → error with guidance.
- `--provisioning groups-sync` → require chart **≥ 0.15.0-rc.3** (reuse a `is_version_v15_plus`-style guard).
- One-directional: cannot switch OAuth→basic in place (LangSmith limitation, see §8).

---

## 5. The hard parts for local-on-Docker (solve these, not the YAML)

These are the real failure points for local OIDC. The plan must address both.

### 5.1 HTTPS is mandatory for LangSmith SSO

Today local runs use nginx + `nip.io` over **HTTP** with `config.deployment.tlsEnabled: false`.
**OAuth mode requires `https`.** (The PKCE-without-secret flow is deprecated *and* incompatible
with SCIM, so we do not use it.)

**Plan (Phase 4):**
- Generate a self-signed cert for the LangSmith host (`*.nip.io` / `localhost`).
- Create a TLS secret; enable ingress TLS + `config.deployment.tlsEnabled: true`.
- Trust the cert inside the Keycloak container (and vice versa) so server-to-server
  token/JWKS fetches don't fail on cert validation.

### 5.2 Issuer-URL reachability (split horizon) — #1 cause of redirect loops

The **browser** redirects to Keycloak at one URL; the LangSmith **pods** validate tokens
against the issuer/JWKS from *inside* the cluster. Both must resolve to the **same issuer
string** or you get `invalid issuer` / `ERR_TOO_MANY_REDIRECTS`.

**Plan (Phase 4):**
- Run Keycloak in Docker, reachable from both the host browser and minikube pods via a
  single name (e.g. `host.minikube.internal` mapping, or a shared `*.nip.io` host).
- Set Keycloak `KC_HOSTNAME` so issued tokens carry that **exact** issuer.
- Set `oauthIssuerUrl` to the same value.
- If the resolved `sub` and the SCIM `externalId` differ, use `ISSUER_SUB_CLAIM_OVERRIDES`
  (env on `platform-backend`) to pick the right claim. (For Azure Entra the default uses `oid`;
  self-hosted installs also default to `oid` for the `sub` mapping.)

---

## 6. Phased implementation

### Phase 0 — Keycloak bring-up (Docker, local)

- `scripts/keycloak.sh up|down` wraps `docker run` of Keycloak (`start-dev`), mounting the
  outbound-SCIM extension JAR into `/opt/keycloak/providers/` (only needed for the SCIM path).
- `keycloak/realm-langsmith.json` realm-import defining:
  - Confidential client: Authorization Code + client secret.
  - Redirect URI: `https://<host>/api/v1/oauth/custom-oidc/callback`.
  - Post-logout redirect URI: `https://<host>` (pairs with `OAUTH_IDP_LOGOUT_ENABLED=true`).
  - Scopes: `openid email profile` (+ `groups` for groups-sync).
  - **Groups client scope/mapper** emitting group names in `LS:Organization …` format into the ID token.
  - 2–3 seed users + groups (e.g. one in `LS:Organization Admins`).
- `KC_HOSTNAME` set per §5.2.

### Phase 1 — OAuth base layer (common to both modes)

- Add a **disabled** `oauth:` block + commented `basicAuth` to `config/config.yaml`.
- In `create_langsmith_config()`, when `AUTH_MODE=keycloak`:
  - comment/remove `basicAuth` (cannot coexist with OAuth),
  - inject `oauth.enabled/oauthClientId/oauthClientSecret/oauthIssuerUrl/oauthScopes`,
  - set `config.hostname: https://<host>`, keep `authType: mixed`,
  - add session env via `platformBackend.deployment.extraEnv`
    (`OAUTH_SESSION_MAX_SEC`, optional `OAUTH_OVERRIDE_TOKEN_EXPIRY`),
  - set `OAUTH_IDP_LOGOUT_ENABLED=true`.
- Turn on local TLS (Phase 4) for the keycloak path.
- **Exit check:** log in to LangSmith through Keycloak.

```yaml
# ls_config.yaml (rendered when --auth keycloak)
config:
  authType: mixed
  hostname: https://langsmith.<host>
  oauth:
    enabled: true
    oauthClientId: "<from .env>"
    oauthClientSecret: "<from .env>"
    oauthIssuerUrl: "https://keycloak.<host>/realms/langsmith"
    oauthScopes: "email,profile,openid"      # groups-sync adds ",groups"
  # basicAuth:        <-- commented out; OAuth and basic auth cannot coexist
platformBackend:
  deployment:
    extraEnv:
      - name: OAUTH_SESSION_MAX_SEC
        value: "86400"
      - name: OAUTH_IDP_LOGOUT_ENABLED
        value: "true"
```

### Phase 2 — `groups-sync` mode

- Append `,groups` to `oauthScopes`.
- Set `SELF_HOSTED_JIT_PROVISIONING_ENABLED=false` via `commonEnv`
  (recommended — JIT and group sync conflict).
- **Post-install** (UI or API, **not** Helm — per-provider setting on the SSO provider record):
  enable **SSO Groups Sync**, set **Groups claim field** = `groups`
  (Settings → Members and roles → SSO Configuration → SSO Groups Sync).
  Provide `scripts/configure-groups-sync.sh` using an org-admin PAT, and also print manual steps.
- Chart **≥ 0.15.0-rc.3** (app 0.15.2rc1) required.
- **Exit check:** Keycloak user in `LS:Organization Admins` logs in → lands as org admin;
  user in `LS:Organization User:Production:Editor` → editor in that workspace.

### Phase 3 — `scim` mode

> **Verified locally (minikube + Docker, KC 26.6.4, chart 0.15.12):** create + update/deactivate
> propagate Keycloak → LangSmith. **Hard delete does NOT propagate** — see caveat below.

- **Keycloak side:** load the outbound-SCIM extension (mitodl/keycloak-scim) by passing
  `SCIM_JAR=/path/to/keycloak-scim-1.0-SNAPSHOT-all.jar` to `scripts/keycloak.sh up`. It mounts
  into `/opt/keycloak/providers/`; both SPIs register on 26.6 (a JPA migration creates the
  `SCIM_RESOURCE` mapping table). Then register the target with `scripts/configure-scim.sh`
  (creates the SCIM User Federation provider + enables the `scim` event listener via the admin
  API — config keys: `endpoint`, `auth-mode=BEARER`, `auth-pass=<token>`, `content-type`,
  `propagation-user/group`). Attribute mapping notes:
  - `externalId` ← `sub` (must match the OIDC `sub` LangSmith resolves, see §5.2),
  - `userName` ← Keycloak username by default (LangSmith stores the email separately; the
    extension does not remap `userName`←email),
  - group `displayName` ← the `LS:…` group name.
- **LangSmith side:** generate a SCIM bearer token (needs an org-admin PAT/service key). The
  **token-management** endpoint is served through the frontend proxy, not platform-backend
  directly:
  ```bash
  curl -X POST $LANGCHAIN_ENDPOINT/api/v1/platform/orgs/current/scim/tokens \
    -H "X-Api-Key: $LANGCHAIN_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"description": "keycloak-local"}'
  # token value (lsv2_…) is returned ONCE; not retrievable later.
  ```
  Wrapped in `scripts/scim-token.sh`. (The SCIM **resource** endpoint `/scim/v2` is served by
  `platform-backend:1986`; the token API path above is the frontend-proxied route.)
- **Local reachability (the reverse split-horizon):** SCIM is outbound (Keycloak → LangSmith),
  so the Keycloak *container* must reach LangSmith's `/scim/v2`. Locally:
  `kubectl port-forward svc/langsmith-platform-backend -n <ns> 1986:1986` (loopback is fine —
  Docker Desktop proxies it), then point the provider at `http://host.docker.internal:1986/scim/v2`.
  This bypasses the ingress TLS + Host-routing entirely. On EKS, use `https://<host>/scim/v2`.
- Set `ISSUER_SUB_CLAIM_OVERRIDES` if `sub` ≠ what the extension sends as `externalId`.
- Disable JIT (`SELF_HOSTED_JIT_PROVISIONING_ENABLED=false`) — done automatically by smith-fly.sh
  for `--provisioning scim`.
- **Exit check:** create a user in Keycloak → appears in LangSmith (`active:true`); disable →
  `active:false`. (Group membership → workspace role propagates via `propagation-group`.)

> SCIM connections typically need HTTP/1.1+ (HTTP/1.0 → `426 Upgrade Required`).

### Phase 4 — Local TLS + issuer plumbing

Implements §5.1 and §5.2; applied to both the LangSmith ingress and the Keycloak container.
Encapsulated so EKS swaps in real DNS/ACM with no logic change.

### Phase 5 — Docs & EKS deltas

- README usage section + this doc.
- **EKS differences:**
  - Real hostname + ACM/real TLS (no self-signed, no `nip.io`).
  - Keycloak as its own Helm release or a fully external IdP (not the local Docker container).
  - ALB callback URL; in-cluster reachability is simpler (real DNS resolves everywhere).
  - Open the network path IdP → `/scim/v2` (security groups / ingress) for the SCIM path.

---

## 7. Files touched

| File | Change | New? |
|---|---|---|
| `smith-fly.sh` | `parse_arguments`: `--auth`, `--provisioning`, validation + version guards; `create_langsmith_config`→`inject_oauth_config`: basicAuth→oauth swap + `config.initialOrgAdminEmail`; `apply_oauth_hostname_tls` + `setup_local_tls` + `setup_oauth_ca_trust` (config.customCa); `oauth_helm_set_flags` (session/JIT env, commonEnv list form) | edit |
| `config/config.yaml` | explanatory comments only (basicAuth removed / oauth injected at runtime; tlsEnabled flipped at runtime) | edit |
| `config/.env.example` | `KEYCLOAK_ISSUER_URL`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OAUTH_SCOPES`, `ISSUER_SUB_CLAIM_OVERRIDES` | edit |
| `keycloak/realm-langsmith.json` | realm/client/groups/users import (no clientScopes override — built-ins auto-create; `groups` scope added post-import) | new |
| `scripts/keycloak.sh` | Keycloak Docker up/down, **persistent** self-signed cert, SCIM JAR mount, post-import `groups` scope setup | new |
| `scripts/scim-token.sh` | generate LangSmith SCIM bearer token | new |
| `scripts/configure-groups-sync.sh` | enable SSO Groups Sync post-install | new |
| `scripts/configure-scim.sh` | register LangSmith SCIM target in Keycloak (federation provider + `scim` listener) | new |
| `README.md` | usage + EKS deltas | edit |

---

## 8. Constraints / risks to confirm before building

- **Enterprise license required** — SSO *and* SCIM are Enterprise features. The `config/.env`
  `LicenseKey` must enable them.
- **No basic + OAuth coexistence**, and **no OAuth → basic rollback** in self-hosted. Switching
  `--auth` is effectively one-directional; revert by tearing down (`./smith-fly.sh down`) and reinstalling.
  Also unsupported: switching between OAuth-with-secret and OAuth-without-secret.
- **Outbound-SCIM extension is third-party/unofficial.** mitodl's is the maintained outbound choice;
  `scim-for-keycloak` OSS is EOL. If running an unofficial plugin is unacceptable, `groups-sync`
  alone covers most testing needs (no extension, no token).
- **SCIM hard-delete is broken on Keycloak 26.x** (verified on 26.6.4). The mitodl extension
  (latest release Sep 2024) loads and handles create/update/**deactivate**, but its `USER_DELETE`
  handler NPEs (`UserModel.isEmailVerified()` on a null user — KC 26 changed how the deleted user
  is passed to event listeners). **Deprovision by disabling users** (propagates as `active=false`),
  not deleting. To get hard-delete propagation you'd need a newer/patched extension build or a
  Keycloak version the extension was built against (≤ 25.x).
- **Chart version floor:** groups-sync needs ≥ 0.15.0-rc.3.
- **JIT vs provisioning conflict:** disable JIT when using either groups-sync or SCIM.
- **Email change limitation:** changing a user's email via SCIM is unsupported once the user has
  multiple linked login methods (`email update not supported with linked login methods`).

---

## 9. Suggested build order

1. Phase 0 + Phase 1 + Phase 4 → **log in via Keycloak over HTTPS** (the real milestone).
2. Phase 2 → groups-sync (quick win, no extension).
3. Phase 3 → SCIM (adds the extension + token plumbing).
4. Phase 5 → docs + EKS.

---

## 10. Reference (LangSmith docs)

- Self-hosted SSO (OAuth2.0/OIDC), session controls, sub-claim override, SSO Groups Sync:
  `/langsmith/self-host-sso`
- User management — SCIM setup, group naming, separator, attribute mapping, token generation:
  `/langsmith/user-management`
- Self-hosted user management / groups sync: `/langsmith/self-host-user-management`
- JIT vs invites vs SCIM precedence: `/langsmith/jit-invite-sso`
- FAQ — "Can I use SCIM without SAML SSO?" → **Self-hosted: yes, with OAuth + Client Secret**: `/langsmith/faq`
