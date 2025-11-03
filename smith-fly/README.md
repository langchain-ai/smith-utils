# smith-fly - LangSmith & LangSmith Deployment Installer

Automated installation and management tool for LangSmith and LangSmith Deployment on any Kubernetes cluster.

> ⚠️ **IMPORTANT**: This script is intended for **TEST PURPOSES ONLY**. It is designed for quick testing, development, and reproduction environments. Do not use this for production deployments.

## Purpose

This script automates the deployment of LangSmith and LangSmith Deployment to Kubernetes clusters for **testing and development purposes**. It provides a quick way to spin up environments for reproduction, debugging, and evaluation across multiple cloud providers and on-premise environments.

Key capabilities:
- Configuration generation with secure secrets
- Helm chart installation and upgrades
- Namespace management
- Credential management
- Clean uninstallation for resource cleanup

## Requirements

### Required Tools

- **kubectl** - Kubernetes command-line tool
- **helm** - Kubernetes package manager (v3+)
- **openssl** - For generating secure secrets

### Kubernetes Cluster

- A running Kubernetes cluster with:
  - **CPU**: ~20 cores available
  - **Memory**: ~50Gi available
  - Ingress controller configured (e.g., nginx-ingress, traefik)
  - StorageClass for persistent volumes

### Configuration Files

- `config/.env` - Environment file containing license key and admin email:
```
initialOrgAdminEmail="admin@example.com"
LicenseKey="your-license-key-here"
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
# Install LangSmith only
./smith-fly.sh up -l

# Install LangSmith with specific version
./smith-fly.sh up -l -v 1.2.3

# Install LangSmith with debug output
./smith-fly.sh up -l --debug

# Install LangSmith Deployment (auto-installs LangSmith if needed)
./smith-fly.sh up -ld

# Uninstall everything
./smith-fly.sh down
```

### Command Options

```
Usage: ./smith-fly.sh <up|down> [-l|-ld] [-v VERSION] [--debug]

Actions:
    up      Spin up/install LangSmith or LangSmith Deployment
    down    Delete both LangSmith and LangSmith Deployment

Options:
    -l      Install LangSmith
    -ld     Install LangSmith Deployment
    -v      Specify version (optional)
    --debug Enable Helm debug output (optional)
```

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
kubectl get pods -n ingress-nginx  # or your ingress namespace

# Check ingress class
kubectl get ingressclass
```

#### Database Connection Issues

```bash
# Check PostgreSQL pod
kubectl logs -l app.kubernetes.io/name=postgresql -n <namespace>

# Check Redis pod
kubectl logs -l app.kubernetes.io/name=redis -n <namespace>
```

### Get Namespace Name

The script auto-generates namespace from your hostname:
```bash
# Get your namespace
hostname | tr '[:upper:]' '[:lower:]' | tr '.' '-'
```

### Manual Cleanup

If `./smith-fly.sh down` fails:
```bash
# Set your namespace
NAMESPACE=$(hostname | tr '[:upper:]' '[:lower:]' | tr '.' '-')

# Uninstall Helm releases
helm uninstall langsmith-deployment -n $NAMESPACE
helm uninstall langsmith -n $NAMESPACE

# Delete PVCs
kubectl delete pvc --all -n $NAMESPACE

# Delete namespace
kubectl delete namespace $NAMESPACE
```

## Resource Usage

⚠️ **WARNING**: This installation requires significant resources:

- **CPU**: ~20 cores
- **Memory**: ~50Gi

**Important**: This is a test environment - delete the installation immediately after testing/reproduction to avoid unnecessary resource consumption and costs. Use `./smith-fly.sh down` to clean up all resources.

## Platform Compatibility

✅ **Supported Platforms:**
- AWS (EKS)
- Google Cloud (GKE)
- Azure (AKS)
- On-premise Kubernetes
- Any Kubernetes distribution (k3s, microk8s, etc.)

The script automatically detects ingress endpoints using both hostname (AWS) and IP (GKE, AKS, on-prem) formats.

## Security Notes

- Admin passwords are automatically generated with required symbols
- Secrets are generated using OpenSSL with 32-byte entropy
- Credentials are displayed once after installation - save them securely
- Configuration files containing secrets are created locally - handle with care

**Production Deployments**: For production use, please follow the official LangChain deployment guides which include:
- Proper secret management (e.g., HashiCorp Vault, AWS Secrets Manager)
- TLS/SSL termination
- High availability configuration
- Backup and disaster recovery
- Security hardening and compliance

## Files Structure

```
smith-fly/
├── smith-fly.sh        # Main installation script
├── README.md               # This file
├── .gitignore              # Git ignore file (excludes .env and generated configs)
└── config/
    ├── .env                # User configuration (license, email) - DO NOT COMMIT!
    ├── config.yaml         # Base Helm values
    ├── ls_config.yaml      # Generated LangSmith config (temporary)
    └── ld_config.yaml      # Generated LangSmith Deployment config (temporary)
```

**Important:** The `.gitignore` file is configured to exclude:
- `config/.env` - Contains sensitive credentials
- `config/ls_config.yaml` - Generated configuration with secrets
- `config/ld_config.yaml` - Generated configuration with secrets

## TODO

- [ ] Support TLS/SSL for ingress
- [ ] Support custom namespace names
- [ ] Add health check automation
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
