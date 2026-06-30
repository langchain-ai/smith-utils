# smith-fly - LangSmith, LangSmith Deployment & Fleet Installer

Automated installation and management tool for LangSmith, LangSmith Deployment, and Fleet on any Kubernetes cluster.

> ⚠️ **IMPORTANT**: This script is intended for **TEST PURPOSES ONLY**. It is designed for quick testing, development, and reproduction environments. Do not use this for production deployments.

## Purpose

This script automates the deployment of LangSmith, LangSmith Deployment, and Fleet to Kubernetes clusters for **testing and development purposes**. It provides a quick way to spin up environments for reproduction, debugging, and evaluation across multiple cloud providers and on-premise environments.

Key capabilities:

- Configuration generation with secure secrets
- Helm chart installation and upgrades
- Custom namespace support (`-n` flag) with DNS label validation
- Auto-generated namespace from hostname when `-n` is not specified
- Credential management
- Installation status checking
- Clean uninstallation for resource cleanup (single namespace or all at once)
- LangSmith Deployments UI enabled by default (shows in LangSmith menu)
- Shared cluster support (multiple installations without CRD conflicts)
- Fleet support (`-lda` flag, chart v0.15+) deployed as standard Helm-managed Deployments
- Post-install synthetic data population (append `s` to any flag, e.g. `-ls`, `-lds`, `-ldas`) with traces, feedback, datasets, and prompts
- Add-on support (chart v0.15+): Fleet (`a`), Insights (`i`), Polly (`p`) via combinable `-ld`* flags
- Live pod-status progress during Helm installs (updates every 15s with stuck-pod detection)
- Two-phase ALB deploy: auto-provisions ALB hostname before enabling deployment features

## Requirements

### Required Tools

- **kubectl** - Kubernetes command-line tool
- **helm** - Kubernetes package manager (v3+)
- **openssl** - For generating secure secrets (and self-signed TLS certs for OAuth)
- **gnu-sed** (macOS only) - GNU sed is required on macOS (`brew install gnu-sed`)
- **docker** (only for `--auth keycloak`) - runs the local Keycloak IdP via `scripts/keycloak.sh`

Example of [Minikube script](https://github.com/langchain-ai/smith-utils/blob/main/smith-fly/scripts/mac/README.md) to quckly spin up k8s cluster.

### Kubernetes Cluster

- A running Kubernetes cluster with:
  - **CPU**: ~~4 cores available (~~10 cores for `-lda` and add-ons)
  - **Memory**: ~~8Gi available (~~12Gi for `-lda` and add-ons)
  - Ingress controller configured:
    - **AWS EKS**: ALB Ingress Controller (auto-detected)
    - **Non-AWS**: nginx-ingress controller (auto-detected)
  - StorageClass for persistent volumes

### Configuration Files

- `config/.env` - Environment file containing license key and admin email:

```
initialOrgAdminEmail="admin@example.com"
LicenseKey="your-license-key-here"
# Optional: Custom hostname for LangSmith (leave empty for auto-detection)
# LANGSMITH_HOSTNAME="langsmith.example.com"
```

**Note:** The `.env` file should not be committed to version control. Add it to `.gitignore` to keep sensitive information secure.

- `config/config.yaml` - Base Helm values configuration

**Example `config/config.yaml` structure:**

```yaml
config:
  deployment:
    enabled: false            # Toggled to true by script for -ld* flags
    ingressHealthCheckEnabled: false
    tlsEnabled: false
  langsmithLicenseKey: ""     # Will be populated by script
  apiKeySalt: ""              # Will be populated by script
  jwtSecret: ""               # Will be populated by script
  initialOrgAdminEmail: ""    # Will be populated by script
  initialOrgAdminPassword: "" # Will be populated by script
```

For LangSmith Deployment, the script dynamically enables `config.deployment` and injects `config.hostname`. Add-ons (Fleet, Insights, Polly) are emitted as **top-level** blocks (the chart v0.15+ model — standalone Deployments, not the deprecated `config.agentBuilder` bootstrap path), each with an auto-generated Fernet encryption key:

```yaml
config:
  deployment:
    enabled: true
  hostname: "auto-detected-or-custom"
fleet:                       # -lda
  enabled: true
  namePrefix: "fleet"
  encryptionKey: "..."
insights:                    # -ldi
  enabled: true
  namePrefix: "insights"
  encryptionKey: "..."
polly:                       # -ldp
  enabled: true
  namePrefix: "polly"
  encryptionKey: "..."
```

## Usage

### Basic Commands

```bash
# Check installation status
./smith-fly.sh status
./smith-fly.sh status -n my-namespace    # Check status in a specific namespace

# Install LangSmith (ingress type auto-detected based on cluster)
./smith-fly.sh up -l

# Install LangSmith in a custom namespace
./smith-fly.sh up -l -n my-namespace

# Install LangSmith with ALB ingress (override auto-detect for AWS EKS)
./smith-fly.sh up -l -i alb

# Install LangSmith with nginx ingress (override auto-detect)
./smith-fly.sh up -l -i nginx

# Install LangSmith with specific version
./smith-fly.sh up -l -v 1.2.3

# Install LangSmith with debug output
./smith-fly.sh up -l --debug

# Install LangSmith Deployment (auto-installs LangSmith if needed)
./smith-fly.sh up -ld

# Install LangSmith Deployment with specific ingress (override auto-detect)
./smith-fly.sh up -ld -i nginx

# Install LangSmith and populate with synthetic test data
./smith-fly.sh up -ls

# Install LangSmith Deployment + Fleet (requires chart v0.15+)
./smith-fly.sh up -lda

# Install LangSmith Deployment + Insights
./smith-fly.sh up -ldi

# Install LangSmith Deployment + Polly
./smith-fly.sh up -ldp

# Install LangSmith Deployment + Fleet + Insights + Polly (all add-ons)
./smith-fly.sh up -ldaip

# OAuth login via Keycloak over HTTPS (see "OAuth / SSO via Keycloak" below)
./smith-fly.sh up -ld --auth keycloak

# OAuth + SSO Groups Sync (group claims -> roles; chart >= 0.15.0-rc.3)
./smith-fly.sh up -ld --auth keycloak --provisioning groups-sync

# OAuth + SCIM (Keycloak pushes users/groups outbound to LangSmith)
./smith-fly.sh up -ld --auth keycloak --provisioning scim

# Uninstall LangSmith from ALL namespaces (auto-discovers deployments)
./smith-fly.sh down

# Uninstall LangSmith from a specific namespace only
./smith-fly.sh down -n my-namespace
```

### Command Options

```
Usage: ./smith-fly.sh <up|down|status> [-l|-ls|-ld|-lds|-ld[a][i][p]] [-v VERSION] [-n NAMESPACE] [-i alb|nginx] [--debug]

Actions:
    up      Spin up/install LangSmith, LangSmith Deployment, or add-ons
    down    Remove LangSmith from all namespaces (or a specific one with -n)
    status  Check installation status of LangSmith and LangSmith Deployment

Options:
    -l        Install LangSmith (tracing, eval, playground)
    -ls       Install LangSmith + populate with synthetic test data
    -ld       Install LangSmith Deployment (adds LangGraph deployment to -l)
    -lds      Install LangSmith Deployment + populate with synthetic test data
    -lda      Install LangSmith Deployment + Fleet (no-code agent creation, v0.15+)
    -ldas     Install LangSmith Deployment + Fleet + populate with synthetic test data
    -v        Specify version (optional)
    -n        Custom namespace (must start with a letter, lowercase alphanumeric/hyphens, max 63 chars)
    -i        Ingress type: alb or nginx (auto-detected if not specified)
    -l              Install LangSmith (tracing, eval, playground)
    -ld             Install LangSmith Deployment (adds LangGraph deployment to -l)
    -ld[a][i][p]    Install LangSmith Deployment with optional add-ons (v0.15+):
                      a = Fleet (no-code agent creation)
                      i = Insights
                      p = Polly
                    Letters combine freely: -lda -ldi -ldp -ldai -ldip -ldaip
    -v              Specify version (optional)
    -n              Custom namespace (must start with a letter, lowercase alphanumeric/hyphens, max 63 chars)
    -i              Ingress type: alb or nginx (auto-detected if not specified)
    --auth          basic|keycloak (default basic). keycloak = OAuth/OIDC login over HTTPS
    --provisioning  none|groups-sync|scim (default none; requires --auth keycloak)
```

> **Namespace rules**: The `-n` value must start with a lowercase letter (`a-z`), contain only lowercase alphanumeric characters or hyphens, and be at most 63 characters. Purely numeric namespaces (e.g., `15265`) are rejected because they cause Helm YAML serialization errors. Use a prefixed name instead (e.g., `ls-15265`).

### Status Output Example

```
==========================================================================
LangSmith Installation Status
==========================================================================

Namespace: my-namespace

LangSmith:
  Status:   Installed
  Chart:    langsmith-0.12.34
  Version:  0.12.73
  Pods:     14/14 Running

Ingress:   http://192.168.49.2.nip.io

==========================================================================
```

> **Note**: For nginx ingress, IP addresses are automatically converted to `nip.io` DNS names for Kubernetes Ingress compatibility.

### Configuration Setup

1. Create `config/.env` file:

```bash
cat > config/.env << EOF
initialOrgAdminEmail="admin@example.com"
LicenseKey="your-license-key-here"
EOF
```

1. Create `config/config.yaml` with base Helm values (see LangChain documentation for Self-Hosted [LangSmith](https://docs.langchain.com/langsmith/kubernetes) and [LangSmith Deployment](https://docs.langchain.com/langgraph-platform/deploy-self-hosted-full-platform))
2. Run the script:

```bash
./smith-fly.sh up -l
```

## OAuth / SSO via Keycloak

`--auth keycloak` delegates LangSmith login to a Keycloak OIDC provider, and
`--provisioning` chooses how org/workspace roles flow into LangSmith. OAuth is the
shared base layer; provisioning is a switch on top. Full design + constraints:
[`docs/keycloak-oauth-scim.md`](docs/keycloak-oauth-scim.md).

> **Enterprise license required** — SSO and SCIM are LangSmith Enterprise features.
> OAuth requires **HTTPS**: the keycloak path generates a self-signed cert, stores it
> as the `langsmith-tls` secret, and enables `config.deployment.tlsEnabled`.

**Local (minikube + Docker) quickstart:**

```bash
# 1. Bring up Keycloak (imports keycloak/realm-langsmith.json). Use a host the
#    LangSmith pods can also resolve (issuer reachability, see doc §5.2).
./scripts/keycloak.sh up --ls-host langsmith.localhost --kc-host keycloak.localhost

# 2. Copy the printed KEYCLOAK_ISSUER_URL / OAUTH_CLIENT_ID / OAUTH_CLIENT_SECRET
#    into config/.env (see config/.env.example).

# 3. Install LangSmith with OAuth + groups-sync
./smith-fly.sh up -ld --auth keycloak --provisioning groups-sync -v 0.15.2

# 4. Enable SSO Groups Sync post-install (groups claim = "groups")
./scripts/configure-groups-sync.sh https://<endpoint> <org-admin-PAT>

# Tear down Keycloak when done
./scripts/keycloak.sh down
```

Seed users in the realm: `ls-admin` (`LS:Organization Admins`) and `ls-editor`
(`LS:Organization User:Production:Editor`), both password `Passw0rd!`.

**SCIM** (`--provisioning scim`) additionally needs the third-party outbound-SCIM
extension JAR ([`mitodl/keycloak-scim`](https://github.com/mitodl/keycloak-scim))
mounted into Keycloak (`SCIM_JAR=/path/to.jar ./scripts/keycloak.sh up ...`), a LangSmith
SCIM token (`./scripts/scim-token.sh <endpoint> <org-admin-PAT>`), and registering the
target in Keycloak (`./scripts/configure-scim.sh --token <scim-token>`). The Keycloak
container reaches LangSmith's SCIM endpoint via `host.docker.internal:1986` after
`kubectl port-forward svc/langsmith-platform-backend -n <ns> 1986:1986`.

Verified locally (KC 26.6, chart 0.15.12): SCIM **create / update / deactivate** propagate
Keycloak → LangSmith. **Known limitation:** SCIM **hard-delete does not propagate** on
Keycloak 26.x — the Sep-2024 extension NPEs in its delete handler. Deprovision by *disabling*
users in Keycloak (propagates as `active=false`), not deleting.

**Caveats:** OAuth and basic auth cannot coexist, and self-hosted does not support
reverting OAuth → basic in place — switch back by tearing down (`down`) and
reinstalling. Disable JIT when provisioning is active (the script sets
`SELF_HOSTED_JIT_PROVISIONING_ENABLED=false` automatically).

### EKS / production deltas

- Real hostname + ACM/real TLS — no self-signed cert, no `nip.io`. Point `--ls-host`
  at the real DNS name and skip the `langsmith-tls` self-signed secret.
- Run Keycloak as its own Helm release or use a fully external IdP — not the local
  Docker container. Set `KEYCLOAK_ISSUER_URL` to that provider's issuer.
- In-cluster reachability is simpler (real DNS resolves everywhere), avoiding the
  split-horizon issuer problem.
- For SCIM, open the network path IdP → `/scim/v2` (security groups / ingress).

## Resource Usage

### Minimal Resource Configuration

For local development or resource-constrained environments (e.g., Minikube), a minimal configuration with reduced resource limits is available in `config/config.yaml`. This sets memory limits for all components to work within ~16Gi total memory.

### Replica Configuration

All component replicas are configured in `config/config.yaml` with a default of 1 replica per component. This can be adjusted by editing the config file before installation:

```yaml
backend:
  deployment:
    replicas: 1  # Adjust as needed

frontend:
  deployment:
    replicas: 1  # Adjust as needed

# ... other components
```

**Important**: This is a test environment - delete the installation immediately after testing/reproduction to avoid unnecessary resource consumption and costs. Use `./smith-fly.sh down` to clean up all resources.

## Platform Compatibility

✅ **Supported Platforms:**

- AWS (EKS)
- Google Cloud (GKE)
- Azure (AKS)
- Minikube (with automatic port-forward and localhost endpoint)
- On-premise Kubernetes
- Any Kubernetes distribution (k3s, microk8s, etc.)

### Shared Cluster Support

The script supports deploying multiple LangSmith installations in different namespaces on the same cluster using the `-n` flag. It handles two common conflict sources automatically:

- **CRDs**: Skips CRD creation (`operator.createCRDs=false`) when `lgps.apps.langchain.ai` already exists from another installation.
- **ClusterRole**: Sets `operator.watchNamespaces` to the target namespace so the chart creates a namespaced `Role`/`RoleBinding` instead of a cluster-scoped `ClusterRole`. This avoids the `"invalid ownership metadata"` error that occurs when a `ClusterRole "langsmith-operator"` already exists and is owned by a different release namespace.

```bash
# Deploy to multiple namespaces on the same cluster
./smith-fly.sh up -l -n team-alpha
./smith-fly.sh up -l -n team-beta

# Tear down all deployments at once
./smith-fly.sh down

# Or tear down a specific namespace
./smith-fly.sh down -n team-alpha
```

### Ingress Configuration

The script **auto-detects** the cluster type and configures the appropriate ingress:


| Cluster Type       | Ingress Type | Auto-Detection                                                  |
| ------------------ | ------------ | --------------------------------------------------------------- |
| **AWS EKS**        | ALB          | Detected via `eks.amazonaws.com` labels or `aws://` provider ID |
| **Minikube**       | nginx        | Auto port-forward to localhost, KEDA CRDs auto-detected         |
| **Other clusters** | nginx        | Default for GKE, AKS, on-premise, k3s, etc.                     |


Use the `-i` flag to override auto-detection if needed:

```bash
./smith-fly.sh up -l -i alb    # Force ALB ingress
./smith-fly.sh up -l -i nginx  # Force nginx ingress
```

**ALB Ingress (AWS EKS):**

```yaml
ingress:
  ingressClassName: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
```

When deploying with LangSmith Deployment (`-ld*`) on ALB and no `LANGSMITH_HOSTNAME` is set, the script runs a two-phase deploy: Phase 1 installs base LangSmith to provision the ALB, then Phase 2 upgrades with the real ALB hostname and all deployment features. The endpoint will be the auto-generated ALB DNS name (e.g., `k8s-testns-langsmit-xxxx.us-east-1.elb.amazonaws.com`). To use a custom domain instead, set `LANGSMITH_HOSTNAME` in `config/.env`.

On subsequent upgrades, the script preserves the existing ALB by patching `managedFields` instead of deleting the ingress, preventing ALB re-creation and DNS hostname changes.

**nginx Ingress (Non-AWS):**

```yaml
ingress:
  ingressClassName: nginx
  annotations: {}
```

The script automatically detects ingress endpoints using both hostname (AWS) and IP (GKE, AKS, on-prem) formats. For nginx ingress with IP addresses, the script automatically converts them to `nip.io` DNS names (e.g., `192.168.49.2.nip.io`) for Kubernetes Ingress compatibility.

## Security Notes

- Admin passwords are automatically generated with required symbols
- Secrets are generated using OpenSSL with 32-byte entropy
- Fernet encryption keys for Fleet, Insights, and Polly are auto-generated and preserved across upgrades
- Credentials are displayed once after installation - save them securely
- Configuration files containing secrets are created locally - handle with care
- When deploying LangSmith Deployment on top of an existing LangSmith installation (`up -ld` after `up -l`), secrets are automatically preserved from the existing configuration to ensure consistency

**Production Deployments**: For production use, please follow the official LangChain deployment guides which include:

- Proper secret management (e.g., HashiCorp Vault, AWS Secrets Manager)
- TLS/SSL termination
- High availability configuration
- Backup and disaster recovery
- Security hardening and compliance

## Files Structure

```
smith-fly/
├── smith-fly.sh            # Main installation script
├── README.md               # This file
├── .gitignore              # Git ignore file (excludes .env and generated configs)
├── config/
│   ├── .env                # User configuration (license, email, Keycloak coords) - DO NOT COMMIT!
│   ├── config.yaml         # Base Helm values (includes minimal resource config)
│   └── ls_config.yaml      # Generated LangSmith config (temporary)
├── keycloak/
│   └── realm-langsmith.json  # Keycloak realm import (client, role groups, seed users)
└── scripts/
    ├── populate.sh         # Synthetic data population (traces, feedback, datasets, prompts)
    ├── keycloak.sh         # Local Keycloak (Docker) up/down for --auth keycloak
    ├── scim-token.sh       # Generate a LangSmith SCIM bearer token (--provisioning scim)
    ├── configure-groups-sync.sh  # Enable SSO Groups Sync post-install (--provisioning groups-sync)
    ├── configure-scim.sh   # Register LangSmith as a SCIM target in Keycloak (--provisioning scim)
    └── mac/
        └── minikube.sh     # macOS Minikube starter with auto resource detection
```

**Important:** The `.gitignore` file is configured to exclude:

- `config/.env` - Contains sensitive credentials
- `config/ls_config.yaml` - Generated configuration with secrets

## TODO

- Support TLS/SSL for ingress
- Support custom namespace names (via `-n` flag with DNS label validation)
- Multi-namespace teardown (`down` auto-discovers all LangSmith deployments)
- Add installation status check (`status` action)
- Support multiple ingress types (ALB/nginx via `-i` flag)
- Auto-detect cluster type for ingress (EKS -> ALB, others -> nginx)
- Configure replicas in `config.yaml` (default: 1 per component)
- Support shared clusters (automatic CRD and ClusterRole conflict handling)
- Preserve secrets when upgrading LangSmith to LangSmith Deployment
- ALB hostname fix (auto-patch ingress when no custom hostname is set)
- Minikube support with auto port-forward and KEDA detection
- Minimal resource configuration for local development
- Fleet support (`-lda` flag) as standalone Helm-managed Deployments (chart v0.15+)
- Insights add-on support (`-ldi` flag, v0.15+)
- Polly add-on support (`-ldp` flag, v0.15+)
- Combinable add-on flags (`-ldaip` for all add-ons at once)
- Live pod-status progress during Helm installs (stuck-pod detection)
- Two-phase ALB deploy (auto-provisions ALB before enabling deployment)
- ALB ingress preservation via managedFields patch (no ALB re-creation on upgrades)
- Deployment block in `config.yaml` with disabled defaults
- Improved teardown (LGP CRD cleanup, all PVCs, released PV cleanup)
- Support external database configuration
- Add metrics collection integration
- Support air-gapped installations

## License

This script is provided as-is for **testing and development purposes only**. It comes with no warranties or guarantees. Refer to LangChain's licensing for the deployed products.

## Support

For issues related to:

- **Script functionality**: Check troubleshooting section above
- **LangSmith/LangSmith Deployment**: Consult [LangChain documentation](https://docs.smith.langchain.com/) for Self-Hosted [LangSmith](https://docs.langchain.com/langsmith/kubernetes) and [LangSmith Deployment](https://docs.langchain.com/langgraph-platform/deploy-self-hosted-full-platform)
- **Kubernetes**: Check your cluster provider documentation
- [LangChain Support portal](https://support.langchain.com/)

