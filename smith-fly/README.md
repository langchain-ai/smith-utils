# smith-fly - LangSmith, LangSmith Deployment & Agent Builder Installer

Automated installation and management tool for LangSmith, LangSmith Deployment, and Agent Builder on any Kubernetes cluster.

> ⚠️ **IMPORTANT**: This script is intended for **TEST PURPOSES ONLY**. It is designed for quick testing, development, and reproduction environments. Do not use this for production deployments.

## Purpose

This script automates the deployment of LangSmith, LangSmith Deployment, and Agent Builder to Kubernetes clusters for **testing and development purposes**. It provides a quick way to spin up environments for reproduction, debugging, and evaluation across multiple cloud providers and on-premise environments.

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
- Agent Builder support (`-lda` flag, chart v0.13+) with two-phase Minikube install
- Post-install synthetic data population (append `s` to any flag, e.g. `-ls`, `-lds`, `-ldas`) with traces, feedback, datasets, and prompts

## Requirements

### Required Tools

- **kubectl** - Kubernetes command-line tool
- **helm** - Kubernetes package manager (v3+)
- **openssl** - For generating secure secrets

Example of [Minikube script](https://github.com/langchain-ai/smith-utils/blob/main/smith-fly/scripts/mac/README.md) to quckly spin up k8s cluster.

### Kubernetes Cluster

- A running Kubernetes cluster with:
  - **CPU**: ~4 cores available (~10 cores for `-lda`)
  - **Memory**: ~8Gi available (~12Gi for `-lda`)
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
  langsmithLicenseKey: ""     # Will be populated by script
  apiKeySalt: ""              # Will be populated by script
  jwtSecret: ""               # Will be populated by script
  initialOrgAdminEmail: ""    # Will be populated by script
  initialOrgAdminPassword: "" # Will be populated by script
```

For LangSmith Deployment, the script adds:
```yaml
config:
  langgraphPlatform:
    enabled: true
    langgraphPlatformLicenseKey: "your-key"  # Automatically populated
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

# Install LangSmith Deployment + Agent Builder (requires chart v0.13+)
./smith-fly.sh up -lda

# Uninstall LangSmith from ALL namespaces (auto-discovers deployments)
./smith-fly.sh down

# Uninstall LangSmith from a specific namespace only
./smith-fly.sh down -n my-namespace
```

### Command Options

```
Usage: ./smith-fly.sh <up|down|status> [-l|-ls|-ld|-lds|-lda|-ldas] [-v VERSION] [-n NAMESPACE] [-i alb|nginx] [--debug]

Actions:
    up      Spin up/install LangSmith, LangSmith Deployment, or Agent Builder
    down    Remove LangSmith from all namespaces (or a specific one with -n)
    status  Check installation status of LangSmith and LangSmith Deployment

Options:
    -l        Install LangSmith (tracing, eval, playground)
    -ls       Install LangSmith + populate with synthetic test data
    -ld       Install LangSmith Deployment (adds LangGraph deployment to -l)
    -lds      Install LangSmith Deployment + populate with synthetic test data
    -lda      Install LangSmith Deployment + Agent Builder (no-code agent creation, v0.13+)
    -ldas     Install LangSmith Deployment + Agent Builder + populate with synthetic test data
    -v        Specify version (optional)
    -n        Custom namespace (must start with a letter, lowercase alphanumeric/hyphens, max 63 chars)
    -i        Ingress type: alb or nginx (auto-detected if not specified)
    --debug   Enable Helm debug output (optional)
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

2. Create `config/config.yaml` with base Helm values (see LangChain documentation for Self-Hosted [LangSmith](https://docs.langchain.com/langsmith/kubernetes) and [LangSmith Deployment](https://docs.langchain.com/langgraph-platform/deploy-self-hosted-full-platform))

3. Run the script:
```bash
./smith-fly.sh up -l
```

## Troubleshooting

### Check Pod Status

```bash
# List all pods in your namespace
kubectl get pods -n <namespace>

# Describe a specific pod
kubectl describe pod <pod-name> -n <namespace>

# View pod logs
kubectl logs <pod-name> -n <namespace>

# Follow logs in real-time
kubectl logs -f <pod-name> -n <namespace>
```

### Check Services

```bash
# List all services
kubectl get svc -n <namespace>

# Describe a specific service
kubectl describe svc <service-name> -n <namespace>
```

### Check Ingress

```bash
# List ingress resources
kubectl get ingress -n <namespace>

# Describe ingress
kubectl describe ingress -n <namespace>

# Get ingress endpoint
kubectl get ingress -n <namespace> -o jsonpath='{.items[0].status.loadBalancer.ingress[0]}'
```

### Check Persistent Volumes

```bash
# List PVCs in namespace
kubectl get pvc -n <namespace>

# Check PVC details
kubectl describe pvc <pvc-name> -n <namespace>
```

### Common Issues

#### Pods Not Starting

```bash
# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Check resource availability
kubectl top nodes
kubectl top pods -n <namespace>
```

#### Ingress Not Working

```bash
# Verify ingress controller is running
# For nginx ingress:
kubectl get pods -n ingress-nginx

# For AWS ALB ingress:
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check available ingress classes
kubectl get ingressclass

# Verify ingress resource
kubectl get ingress -n <namespace> -o yaml
```

#### ClusterRole Ownership Conflict

If you see an error like:
```
ClusterRole "langsmith-operator" in namespace "" exists and cannot be imported into the current release:
invalid ownership metadata; annotation validation error: key "meta.helm.sh/release-namespace" must equal "<your-namespace>": current value is "<other-namespace>"
```

This means another LangSmith Helm release on the cluster already owns the cluster-scoped `ClusterRole`. The script handles this automatically by setting `operator.watchNamespaces` to scope RBAC to your namespace. If you hit this on an older version of the script, update and re-run.

#### Endpoint Shows PENDING (ALB)

If the endpoint shows `PENDING` after installation on AWS EKS, the ALB may have failed to provision:

```bash
# Check ingress events for errors
kubectl get events -n <namespace> --field-selector involvedObject.name=langsmith-ingress

# Check if ALB controller is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

Common causes:
- **Invalid host condition**: ALB rejects `localhost` or other non-FQDN hostnames. The script handles this automatically for new installs by patching the ingress. For existing installs, set `LANGSMITH_HOSTNAME` in `config/.env` to a valid domain, or manually remove the host rule:
  ```bash
  kubectl patch ingress langsmith-ingress -n <namespace> --type=json \
      -p='[{"op":"remove","path":"/spec/rules/0/host"}]'
  ```
- **Missing ALB controller**: Ensure the AWS Load Balancer Controller is installed on the cluster.
- **IAM permissions**: The ALB controller needs permissions to create load balancers.

#### Database Connection Issues

```bash
# Check PostgreSQL pod
kubectl logs -l app.kubernetes.io/name=postgresql -n <namespace>

# Check Redis pod
kubectl logs -l app.kubernetes.io/name=redis -n <namespace>
```

### Get Namespace Name

By default, the script auto-generates a namespace from your hostname. You can override this with the `-n` flag:
```bash
# See the auto-generated namespace
hostname | tr '[:upper:]' '[:lower:]' | tr '.' '-'

# Or use a custom namespace
./smith-fly.sh status -n my-namespace
```

### Manual Cleanup

If `./smith-fly.sh down` fails:
```bash
# Option 1: Remove from a specific namespace
NAMESPACE="my-namespace"

# Option 2: Use auto-generated namespace
NAMESPACE=$(hostname | tr '[:upper:]' '[:lower:]' | tr '.' '-')

# Uninstall Helm release
helm uninstall langsmith -n $NAMESPACE

# Delete PVCs
kubectl delete pvc --all -n $NAMESPACE

# Delete namespace
kubectl delete namespace $NAMESPACE
```

To find all namespaces with LangSmith deployments:
```bash
helm list --all-namespaces --filter '^langsmith$'
```

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

| Cluster Type | Ingress Type | Auto-Detection |
|--------------|--------------|----------------|
| **AWS EKS** | ALB | Detected via `eks.amazonaws.com` labels or `aws://` provider ID |
| **Minikube** | nginx | Auto port-forward to localhost, KEDA CRDs auto-detected |
| **Other clusters** | nginx | Default for GKE, AKS, on-premise, k3s, etc. |

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

When deploying with LangSmith Deployment (`-ld`) on ALB and no `LANGSMITH_HOSTNAME` is set, the script uses a placeholder hostname to satisfy chart validation, then patches the ingress to remove the host rule so the ALB accepts all traffic. The endpoint will be the auto-generated ALB DNS name (e.g., `k8s-testns-langsmit-xxxx.us-east-1.elb.amazonaws.com`). To use a custom domain instead, set `LANGSMITH_HOSTNAME` in `config/.env`.

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
- Agent Builder Fernet encryption key is auto-generated and preserved across upgrades
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
│   ├── .env                # User configuration (license, email) - DO NOT COMMIT!
│   ├── config.yaml         # Base Helm values (includes minimal resource config)
│   └── ls_config.yaml      # Generated LangSmith config (temporary)
└── scripts/
    ├── populate.sh         # Synthetic data population (traces, feedback, datasets, prompts)
    └── mac/
        └── minikube.sh     # macOS Minikube starter with auto resource detection
```

**Important:** The `.gitignore` file is configured to exclude:
- `config/.env` - Contains sensitive credentials
- `config/ls_config.yaml` - Generated configuration with secrets

## TODO

- [ ] Support TLS/SSL for ingress
- [x] Support custom namespace names (via `-n` flag with DNS label validation)
- [x] Multi-namespace teardown (`down` auto-discovers all LangSmith deployments)
- [x] Add installation status check (`status` action)
- [x] Support multiple ingress types (ALB/nginx via `-i` flag)
- [x] Auto-detect cluster type for ingress (EKS -> ALB, others -> nginx)
- [x] Configure replicas in `config.yaml` (default: 1 per component)
- [x] Support shared clusters (automatic CRD and ClusterRole conflict handling)
- [x] Preserve secrets when upgrading LangSmith to LangSmith Deployment
- [x] ALB hostname fix (auto-patch ingress when no custom hostname is set)
- [x] Minikube support with auto port-forward and KEDA detection
- [x] Minimal resource configuration for local development
- [x] Agent Builder support (`-lda` flag) with two-phase Minikube install
- [x] Known-bad version range detection (0.13.17–0.13.22 bootstrap regression)
- [x] Improved teardown (LGP CRD cleanup, all PVCs, released PV cleanup)
- [ ] Support external database configuration
- [ ] Add metrics collection integration
- [ ] Support air-gapped installations


## License

This script is provided as-is for **testing and development purposes only**. It comes with no warranties or guarantees. Refer to LangChain's licensing for the deployed products.

## Support

For issues related to:
- **Script functionality**: Check troubleshooting section above
- **LangSmith/LangSmith Deployment**: Consult [LangChain documentation](https://docs.smith.langchain.com/) for Self-Hosted [LangSmith](https://docs.langchain.com/langsmith/kubernetes) and [LangSmith Deployment](https://docs.langchain.com/langgraph-platform/deploy-self-hosted-full-platform)
- **Kubernetes**: Check your cluster provider documentation
- [LangChain Support portal](https://support.langchain.com/)
