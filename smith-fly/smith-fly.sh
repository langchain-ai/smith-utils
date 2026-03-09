#!/bin/bash

##############################################################################
# LangSmith and LangSmith Deployment Installation Script for Kubernetes Clusters
# 
# Description: Automates the installation and management of LangSmith and 
#              LangSmith Deployment on any Kubernetes cluster (cross-platform)
# 
# Usage: ./smith-fly.sh <up|down|status> [-l|-ld] [-v VERSION] [-n NAMESPACE]
# 
# Date: 2025-10-14
##############################################################################

set -euo pipefail

# For debugging
# set -x

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
ENV_FILE="${CONFIG_DIR}/.env"
CONFIG_YAML="${CONFIG_DIR}/config.yaml"
LS_CONFIG_YAML="${CONFIG_DIR}/ls_config.yaml"

ACTION=""
INSTALL_LS=false
INSTALL_LD=false
VERSION=""
DEBUG=false
NAMESPACE=""
INGRESS_TYPE=""  # Empty means auto-detect; 'alb' or 'nginx' if explicitly set
IS_V12_PLUS=true  # Default to true (latest version assumes v12+)
initialOrgAdminEmail=""
LicenseKey=""
apiKeySalt=""
jwtSecret=""
initialOrgAdminPassword=""
LANGSMITH_HOSTNAME=""  # Optional: custom hostname for LangSmith (can be set via .env)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect sed command (use gsed on macOS for GNU sed compatibility)
if [[ "$OSTYPE" == "darwin"* ]]; then
    if command -v gsed &> /dev/null; then
        SED_CMD="gsed"
    else
        echo -e "${RED}[ERROR]${NC} GNU sed (gsed) is required on macOS. Install with: brew install gnu-sed"
        exit 1
    fi
else
    SED_CMD="sed"
fi

##############################################################################
# Function: log
# Description: Logs messages with timestamp
##############################################################################
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        INFO)
            echo -e "${BLUE}[${timestamp}] [INFO]${NC} ${message}"
            ;;
        SUCCESS)
            echo -e "${GREEN}[${timestamp}] [SUCCESS]${NC} ${message}"
            ;;
        WARNING)
            echo -e "${YELLOW}[${timestamp}] [WARNING]${NC} ${message}"
            ;;
        ERROR)
            echo -e "${RED}[${timestamp}] [ERROR]${NC} ${message}"
            ;;
        *)
            echo -e "[${timestamp}] ${message}"
            ;;
    esac
}

##############################################################################
# Function: cleanup_on_error
# Description: Cleanup temporary files on script error
##############################################################################
cleanup_on_error() {
    log ERROR "Script failed. Cleaning up temporary files..."
    # Add any cleanup logic needed on error
}

# Set trap for error handling
trap cleanup_on_error ERR

##############################################################################
# Function: is_version_v12_plus
# Description: Checks if specified version is >= 0.12.0
# Returns: 0 if version >= 0.12.0 or empty (latest), 1 otherwise
##############################################################################
is_version_v12_plus() {
    local version="$1"
    local major minor
    
    # Handle empty/latest case as v12+ (default to latest)
    if [ -z "$version" ]; then
        return 0
    fi
    
    # Parse version string (e.g., "0.12.3" -> major=0, minor=12)
    IFS='.' read -r major minor _ <<< "$version"
    
    # Handle non-numeric values gracefully
    if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
        log WARNING "Unable to parse version '$version', assuming v12+"
        return 0
    fi
    
    # Check if version >= 0.12.0
    if [ "$major" -gt 0 ] || [ "$minor" -ge 12 ]; then
        return 0  # v12+
    fi
    
    return 1  # pre-v12
}

##############################################################################
# Function: detect_version
# Description: Sets IS_V12_PLUS based on specified VERSION
##############################################################################
detect_version() {
    if is_version_v12_plus "$VERSION"; then
        IS_V12_PLUS=true
        log INFO "Version detected as v12+ (new config format)"
    else
        IS_V12_PLUS=false
        log INFO "Version detected as pre-v12 (legacy config format)"
    fi
}

##############################################################################
# Function: detect_cluster_type
# Description: Detects if the current Kubernetes cluster is AWS EKS
# Returns: 0 if EKS detected, 1 otherwise
##############################################################################
detect_cluster_type() {
    # Check node labels for EKS-specific labels
    if kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "eks.amazonaws.com"; then
        return 0  # EKS detected
    fi
    
    # Check node provider ID for AWS (format: aws://region/instance-id)
    if kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -q "^aws://"; then
        return 0  # AWS detected
    fi
    
    return 1  # Not EKS
}

##############################################################################
# Function: is_minikube_cluster
# Description: Detects if the current Kubernetes cluster is Minikube
# Returns: 0 if Minikube detected, 1 otherwise
##############################################################################
is_minikube_cluster() {
    # Check if minikube command exists and is the current context
    if command -v minikube &> /dev/null; then
        local current_context
        current_context=$(kubectl config current-context 2>/dev/null || echo "")
        if [ "$current_context" = "minikube" ]; then
            return 0  # Minikube detected
        fi
    fi
    
    # Check node labels for minikube-specific labels
    if kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "minikube.k8s.io"; then
        return 0  # Minikube detected
    fi
    
    # Check node name contains "minikube"
    if kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -qi "minikube"; then
        return 0  # Minikube detected
    fi
    
    return 1  # Not Minikube
}

##############################################################################
# Function: is_keda_installed
# Description: Checks if KEDA (Kubernetes Event-Driven Autoscaling) is installed
# Returns: 0 if KEDA CRDs exist, 1 otherwise
##############################################################################
is_keda_installed() {
    kubectl get crd scaledobjects.keda.sh &> /dev/null
}

##############################################################################
# Function: start_minikube_port_forward
# Description: Starts port-forward to ingress-nginx-controller in background
#              for Minikube installations where direct IP access doesn't work
# Returns: 0 on success, 1 on failure
##############################################################################
start_minikube_port_forward() {
    local port="${1:-8080}"
    
    log INFO "Starting port-forward to ingress-nginx-controller on port ${port}..."
    
    # Check if ingress-nginx-controller service exists
    if ! kubectl get svc ingress-nginx-controller -n ingress-nginx &> /dev/null; then
        log WARNING "ingress-nginx-controller service not found in ingress-nginx namespace"
        return 1
    fi
    
    # Kill any existing port-forward on the same port
    pkill -f "kubectl port-forward.*ingress-nginx-controller.*${port}:80" 2>/dev/null || true
    
    # Start port-forward in background
    nohup kubectl port-forward svc/ingress-nginx-controller -n ingress-nginx "${port}:80" > /dev/null 2>&1 &
    local pf_pid=$!
    
    # Wait a moment and verify it started
    sleep 2
    if kill -0 "$pf_pid" 2>/dev/null; then
        log SUCCESS "Port-forward started successfully (PID: ${pf_pid})"
        log INFO "LangSmith is accessible at http://localhost:${port}"
        return 0
    else
        log ERROR "Failed to start port-forward"
        return 1
    fi
}

##############################################################################
# Function: stop_minikube_port_forward
# Description: Stops any running port-forward to ingress-nginx-controller
#              Used during uninstallation on Minikube
##############################################################################
stop_minikube_port_forward() {
    local port="${1:-8080}"
    
    log INFO "Checking for running port-forward processes..."
    
    # Find and kill port-forward processes for ingress-nginx-controller
    local pf_pids
    pf_pids=$(pgrep -f "kubectl port-forward.*ingress-nginx-controller" 2>/dev/null || echo "")
    
    if [ -n "$pf_pids" ]; then
        log INFO "Stopping port-forward processes: ${pf_pids}"
        pkill -f "kubectl port-forward.*ingress-nginx-controller" 2>/dev/null || true
        sleep 1
        
        # Verify processes were killed
        if pgrep -f "kubectl port-forward.*ingress-nginx-controller" &>/dev/null; then
            log WARNING "Some port-forward processes may still be running"
        else
            log SUCCESS "Port-forward processes stopped successfully"
        fi
    else
        log INFO "No port-forward processes found"
    fi
}

##############################################################################
# Function: set_ingress_type
# Description: Auto-detects cluster type and sets ingress accordingly
#              User-specified -i flag takes precedence over auto-detection
##############################################################################
set_ingress_type() {
    # If user explicitly set ingress type via -i flag, use that
    if [ -n "$INGRESS_TYPE" ]; then
        log INFO "Using user-specified ingress type: ${INGRESS_TYPE}"
        return
    fi
    
    # Auto-detect based on cluster type
    log INFO "Auto-detecting cluster type for ingress configuration..."
    
    if detect_cluster_type; then
        INGRESS_TYPE="alb"
        log SUCCESS "AWS EKS detected - using ALB ingress"
    else
        INGRESS_TYPE="nginx"
        log INFO "Non-EKS cluster detected - using nginx ingress (default)"
    fi
}

##############################################################################
# Function: show_usage
# Description: Displays script usage information
##############################################################################
show_usage() {
    cat << EOF
Usage: $0 <up|down|status> [-l|-ld] [-v VERSION] [-n NAMESPACE] [-i alb|nginx] [--debug]

Actions:
    up      Spin up/install LangSmith or LangSmith Deployment
    down    Remove LangSmith from all namespaces (or a specific one with -n)
    status  Check installation status of LangSmith and LangSmith Deployment

Options (for 'up' action):
    -l      Install LangSmith
    -ld     Install LangSmith Deployment
    -v      Specify version (optional)
    -n      Custom namespace (must start with a letter, lowercase alphanumeric/hyphens, max 63 chars)
    -i      Ingress type: alb or nginx (auto-detected if not specified)
    --debug Enable Helm debug output (optional)

Examples:
    $0 up -l                     # Install LangSmith (ingress auto-detected based on cluster)
    $0 up -l -n my-namespace     # Install LangSmith in custom namespace
    $0 up -l -i alb              # Install LangSmith with ALB ingress (override auto-detect)
    $0 up -l -i nginx            # Install LangSmith with nginx ingress (override auto-detect)
    $0 up -l -v 0.12.3           # Install LangSmith v12+ with specific version
    $0 up -l -v 0.11.5           # Install LangSmith pre-v12 with legacy config format
    $0 up -l --debug             # Install LangSmith with debug output
    $0 up -ld                    # Install LangSmith Deployment (automatically installs LangSmith if not present)
    $0 up -ld -i nginx           # Install LangSmith Deployment with nginx ingress
    $0 up -ld -v 0.11.0          # Install LangSmith Deployment with pre-v12 config format
    $0 down                      # Remove LangSmith from ALL namespaces (auto-discovers deployments)
    $0 down -n my-namespace      # Remove LangSmith from a specific namespace only
    $0 status                    # Check installation status of LangSmith and LangSmith Deployment
    $0 status -n my-namespace    # Check status in a custom namespace

Notes:
    - At least one of -l or -ld must be specified with "up"
    - When installing LangSmith Deployment (-ld), LangSmith is automatically installed if not already present
    - The "down" action removes LangSmith from all namespaces (or a specific one with -n)
    - Configuration is read from ${ENV_FILE}
    - Namespace is auto-generated from hostname unless overridden with -n
    - Version >= 0.12.0 uses new config format (config.deployment, config.hostname)
    - Version < 0.12.0 uses legacy config format (config.langgraphPlatform, langgraphPlatformLicenseKey)
    - Ingress type is auto-detected: AWS EKS -> ALB, other clusters -> nginx
    - Use -i flag to override auto-detection (e.g., -i alb or -i nginx)

EOF
    exit 1
}

##############################################################################
# Function: check_prerequisites
# Description: Validates that required tools are installed
##############################################################################
check_prerequisites() {
    log INFO "Checking prerequisites..."
    
    local missing_tools=()
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    fi
    
    # Check openssl
    if ! command -v openssl &> /dev/null; then
        missing_tools+=("openssl")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log ERROR "Missing required tools: ${missing_tools[*]}"
        log ERROR "Please install the missing tools and try again."
        exit 1
    fi
    
    log SUCCESS "All prerequisites are installed"
}

##############################################################################
# Function: parse_arguments
# Description: Parses command line arguments
##############################################################################
parse_arguments() {
    if [ $# -eq 0 ]; then
        show_usage
    fi
    
    # First argument should be action (up, down, or status)
    case "$1" in
        up|down|status)
            ACTION="$1"
            shift
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            log ERROR "Invalid action: $1"
            show_usage
            ;;
    esac
    
    # Parse remaining arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            -l)
                INSTALL_LS=true
                shift
                ;;
            -ld)
                INSTALL_LD=true
                shift
                ;;
            -v)
                if [ $# -lt 2 ]; then
                    log ERROR "-v option requires a version argument"
                    show_usage
                fi
                VERSION="$2"
                shift 2
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            -n)
                if [ $# -lt 2 ]; then
                    log ERROR "-n option requires a namespace argument"
                    show_usage
                fi
                NAMESPACE="$2"
                if ! validate_namespace "$NAMESPACE"; then
                    show_usage
                fi
                shift 2
                ;;
            -i)
                if [ $# -lt 2 ]; then
                    log ERROR "-i option requires an argument (alb or nginx)"
                    show_usage
                fi
                case "$2" in
                    alb|nginx)
                        INGRESS_TYPE="$2"
                        ;;
                    *)
                        log ERROR "Invalid ingress type: $2. Must be 'alb' or 'nginx'"
                        show_usage
                        ;;
                esac
                shift 2
                ;;
            *)
                log ERROR "Unknown option: $1"
                show_usage
                ;;
        esac
    done
    
    # Validate that at least one of -l or -ld is specified for 'up' action
    if [ "$ACTION" = "up" ]; then
        if [ "$INSTALL_LS" = false ] && [ "$INSTALL_LD" = false ]; then
            log ERROR "At least one of -l or -ld must be specified with 'up' action"
            show_usage
        fi
    fi
    
    # For 'down' action, remove both regardless of flags
    if [ "$ACTION" = "down" ]; then
        INSTALL_LS=true
        INSTALL_LD=true
        log INFO "Down action will remove both LangSmith and LangSmith Deployment"
    fi
    
    # Skip verbose logging for status action
    if [ "$ACTION" != "status" ]; then
        log INFO "Action: ${ACTION}"
        log INFO "Install LangSmith: ${INSTALL_LS}"
        log INFO "Install LangSmith Deployment: ${INSTALL_LD}"
        log INFO "Ingress Type: ${INGRESS_TYPE}"
        
        if [ -n "$VERSION" ]; then
            log INFO "Version: ${VERSION}"
        fi
        
        # Detect version format (v12+ or legacy)
        detect_version
    fi
}

##############################################################################
# Function: load_configuration
# Description: Loads configuration from env file
##############################################################################
load_configuration() {
    log INFO "Loading configuration from ${ENV_FILE}..."
    
    if [ ! -f "$ENV_FILE" ]; then
        log ERROR "Configuration file not found: ${ENV_FILE}"
        exit 1
    fi
    
    if [ ! -r "$ENV_FILE" ]; then
        log ERROR "Configuration file is not readable: ${ENV_FILE}"
        exit 1
    fi
    
    # Source the env file
    source "$ENV_FILE"
    
    # Validate required variables
    if [ -z "${initialOrgAdminEmail:-}" ]; then
        log ERROR "initialOrgAdminEmail not found in ${ENV_FILE}"
        exit 1
    fi
    
    if [ -z "${LicenseKey:-}" ]; then
        log ERROR "LicenseKey not found in ${ENV_FILE}"
        exit 1
    fi
    
    # Load optional LANGSMITH_HOSTNAME if set in .env
    if [ -n "${LANGSMITH_HOSTNAME:-}" ]; then
        log INFO "Custom hostname configured: ${LANGSMITH_HOSTNAME}"
    fi
    
    log SUCCESS "Configuration loaded successfully"
}

##############################################################################
# Function: validate_namespace
# Description: Validates that namespace conforms to Kubernetes DNS label rules
#              and does not start with a digit (avoids Helm YAML number coercion)
# Arguments:  $1 - namespace string to validate
# Returns:    0 on success, exits with error on failure
##############################################################################
validate_namespace() {
    local ns="$1"

    # Must not be empty
    if [ -z "$ns" ]; then
        log ERROR "Namespace cannot be empty"
        return 1
    fi

    # Max 63 characters (RFC 1123 DNS label)
    if [ "${#ns}" -gt 63 ]; then
        log ERROR "Namespace '${ns}' exceeds 63 characters (got ${#ns})"
        return 1
    fi

    # Must start with a lowercase letter (a-z).
    # Purely numeric namespaces cause Helm YAML serialization to treat the
    # value as an integer, which breaks metadata.namespace (expects a string).
    if [[ ! "$ns" =~ ^[a-z] ]]; then
        log ERROR "Namespace '${ns}' must start with a lowercase letter (a-z)"
        log ERROR "Purely numeric or digit-leading namespaces break Helm YAML serialization"
        log INFO  "Hint: prefix with a string, e.g. 'ls-${ns}'"
        return 1
    fi

    # Must consist only of lowercase alphanumeric characters or hyphens
    if [[ ! "$ns" =~ ^[a-z][a-z0-9-]*$ ]]; then
        log ERROR "Namespace '${ns}' contains invalid characters"
        log ERROR "Only lowercase letters, digits, and hyphens are allowed"
        return 1
    fi

    # Must not end with a hyphen
    if [[ "$ns" =~ -$ ]]; then
        log ERROR "Namespace '${ns}' must not end with a hyphen"
        return 1
    fi

    return 0
}

##############################################################################
# Function: setup_namespace
# Description: Creates namespace based on hostname
##############################################################################
setup_namespace() {
    log INFO "Setting up namespace..."
    
    # Use custom namespace if provided via -n, otherwise generate from hostname
    if [ -z "$NAMESPACE" ]; then
        NAMESPACE=$(hostname | tr '[:upper:]' '[:lower:]' | tr '.' '-')
        # Strip leading digits/hyphens from auto-generated namespace
        NAMESPACE=$(echo "$NAMESPACE" | sed 's/^[^a-z]*//')
    fi
    
    # Validate namespace before proceeding
    if ! validate_namespace "$NAMESPACE"; then
        exit 1
    fi

    log INFO "Using namespace: ${NAMESPACE}"
    
    # Create namespace if it doesn't exist
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log INFO "Creating namespace: ${NAMESPACE}"
        kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
        log SUCCESS "Namespace created: ${NAMESPACE}"
    else
        log INFO "Namespace already exists: ${NAMESPACE}"
    fi
}

##############################################################################
# Function: setup_helm_repo
# Description: Adds and updates LangChain Helm repository
##############################################################################
setup_helm_repo() {
    log INFO "Setting up Helm repository..."
    
    helm repo add langchain https://langchain-ai.github.io/helm/ 2>/dev/null || true
    helm repo update
    
    log SUCCESS "Helm repository updated"
}

##############################################################################
# Function: generate_secrets
# Description: Generates secure random secrets
##############################################################################
generate_secrets() {
    log INFO "Generating secure secrets..."
    
    apiKeySalt=$(openssl rand -base64 32)
    jwtSecret=$(openssl rand -base64 32)
    
    # Generate strong password with guaranteed required symbols
    # Required symbols: !#$%()+,-./:?@[\]^_{~}
    # Strategy: Generate base alphanumeric + always append required symbols
    local base_part=$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)
    local symbol_part="!@#"
    local random_part=$(head -c 4 /dev/urandom | base64 | tr -dc 'A-Za-z0-9!#$%()+,-./:?@[\]^_{~}' | head -c 4)
    
    # Combine and ensure we have a strong password with required symbols
    initialOrgAdminPassword="${base_part}${symbol_part}${random_part}"
    
    log SUCCESS "Secrets generated successfully"
}

##############################################################################
# Function: load_existing_secrets
# Description: Loads existing secrets from ls_config.yaml if it exists
# Returns: 0 if secrets were loaded, 1 if not found or invalid
##############################################################################
load_existing_secrets() {
    if [ ! -f "$LS_CONFIG_YAML" ]; then
        log INFO "No existing LangSmith config found, will generate new secrets"
        return 1
    fi
    
    log INFO "Found existing LangSmith config, loading secrets..."
    
    # Extract existing secrets from ls_config.yaml using grep and sed
    # IMPORTANT: Use --color=never to prevent ANSI escape codes from corrupting values
    local existing_salt existing_jwt existing_password
    
    existing_salt=$(grep --color=never -E '^\s*apiKeySalt:' "$LS_CONFIG_YAML" 2>/dev/null | $SED_CMD 's/.*apiKeySalt:\s*"\?\([^"]*\)"\?.*/\1/' | head -1)
    existing_jwt=$(grep --color=never -E '^\s*jwtSecret:' "$LS_CONFIG_YAML" 2>/dev/null | $SED_CMD 's/.*jwtSecret:\s*"\?\([^"]*\)"\?.*/\1/' | head -1)
    existing_password=$(grep --color=never -E '^\s*initialOrgAdminPassword:' "$LS_CONFIG_YAML" 2>/dev/null | $SED_CMD 's/.*initialOrgAdminPassword:\s*"\?\([^"]*\)"\?.*/\1/' | head -1)
    
    # Validate that all secrets exist and don't contain ANSI escape codes
    # Check for control characters that indicate corrupted values
    if [ -n "$existing_salt" ] && [ -n "$existing_jwt" ] && [ -n "$existing_password" ]; then
        # Verify no ANSI escape sequences (control characters) are present
        if echo "$existing_salt$existing_jwt$existing_password" | grep -q $'\x1b'; then
            log WARNING "Existing secrets contain control characters, will generate new ones"
            return 1
        fi
        
        apiKeySalt="$existing_salt"
        jwtSecret="$existing_jwt"
        initialOrgAdminPassword="$existing_password"
        log SUCCESS "Loaded existing secrets from ${LS_CONFIG_YAML}"
        return 0
    fi
    
    log WARNING "Existing config missing some secrets, will generate new ones"
    return 1
}

##############################################################################
# Function: create_langsmith_config
# Description: Creates LangSmith configuration file with substituted values
##############################################################################
create_langsmith_config() {
    log INFO "Creating LangSmith configuration file..."
    
    if [ ! -f "$CONFIG_YAML" ]; then
        log ERROR "Base configuration file not found: ${CONFIG_YAML}"
        exit 1
    fi
    
    # Try to load existing secrets from ls_config.yaml before overwriting
    # This preserves secrets across deployments (e.g., when adding LangGraph on top of LangSmith)
    if [ -z "$apiKeySalt" ] || [ -z "$jwtSecret" ] || [ -z "$initialOrgAdminPassword" ]; then
        load_existing_secrets || true
    fi
    
    # Copy base config to LangSmith config
    cp "$CONFIG_YAML" "$LS_CONFIG_YAML"
    
    # Generate secrets only if not already loaded from existing config
    if [ -z "$apiKeySalt" ] || [ -z "$jwtSecret" ] || [ -z "$initialOrgAdminPassword" ]; then
        generate_secrets
    else
        log INFO "Using existing secrets (preserved from previous deployment)"
    fi
    
    # Escape special characters for sed
    escaped_email=$(printf '%s\n' "$initialOrgAdminEmail" | sed 's/[\/&]/\\&/g')
    escaped_license=$(printf '%s\n' "$LicenseKey" | sed 's/[\/&]/\\&/g')
    escaped_salt=$(printf '%s\n' "$apiKeySalt" | sed 's/[\/&]/\\&/g')
    escaped_jwt=$(printf '%s\n' "$jwtSecret" | sed 's/[\/&]/\\&/g')
    escaped_password=$(printf '%s\n' "$initialOrgAdminPassword" | sed 's/[\/&]/\\&/g')
    
    # Use sed to replace values in the config file
    $SED_CMD -i.bak \
        -e "s/langsmithLicenseKey:.*/langsmithLicenseKey: \"${escaped_license}\"/" \
        -e "s/apiKeySalt:.*/apiKeySalt: \"${escaped_salt}\"/" \
        -e "s/initialOrgAdminEmail:.*/initialOrgAdminEmail: \"${escaped_email}\"/" \
        -e "s/initialOrgAdminPassword:.*/initialOrgAdminPassword: \"${escaped_password}\"/" \
        -e "s/jwtSecret:.*/jwtSecret: \"${escaped_jwt}\"/" \
        "$LS_CONFIG_YAML"
    
    # Handle ingress type configuration
    if [ "$INGRESS_TYPE" = "nginx" ]; then
        log INFO "Configuring nginx ingress..."
        # Replace ALB ingress with nginx configuration
        $SED_CMD -i.bak \
            -e "s/ingressClassName: alb/ingressClassName: nginx/" \
            -e "/alb.ingress.kubernetes.io/d" \
            "$LS_CONFIG_YAML"
        # Add empty annotations for nginx
        $SED_CMD -i.bak \
            -e "s/annotations:/annotations: {}/" \
            "$LS_CONFIG_YAML"
        rm -f "${LS_CONFIG_YAML}.bak"
    else
        log INFO "Using ALB ingress (default)..."
    fi
    
    # Add langgraphPlatformLicenseKey only for pre-v12 when LangSmith Deployment is being installed
    # As of v12, langgraphPlatformLicenseKey is deprecated and not needed
    if [ "$INSTALL_LD" = true ] && [ "$IS_V12_PLUS" = false ]; then
        log INFO "Adding langgraphPlatformLicenseKey for pre-v12 deployment"
        if ! grep -q "langgraphPlatformLicenseKey" "$LS_CONFIG_YAML"; then
            # Use temp file for inserting after langsmithLicenseKey
            local temp_insert=$(mktemp)
            echo "  langgraphPlatformLicenseKey: \"${LicenseKey}\"" > "$temp_insert"
            $SED_CMD -i.bak "/langsmithLicenseKey:/r $temp_insert" "$LS_CONFIG_YAML"
            rm -f "$temp_insert"
        else
            $SED_CMD -i.bak "s/langgraphPlatformLicenseKey:.*/langgraphPlatformLicenseKey: \"${escaped_license}\"/" "$LS_CONFIG_YAML"
        fi
        rm -f "${LS_CONFIG_YAML}.bak"
    fi
    
    # Remove backup file
    rm -f "${LS_CONFIG_YAML}.bak"
    
    log SUCCESS "LangSmith configuration file created: ${LS_CONFIG_YAML}"
}

##############################################################################
# Function: install_langsmith
# Description: Installs LangSmith using Helm
##############################################################################
install_langsmith() {
    log INFO "Installing LangSmith..."
    
    # Create configuration
    create_langsmith_config
    
    # Scope operator to this namespace in the values file to ensure the chart
    # renders namespaced Role/RoleBinding instead of cluster-scoped ClusterRole.
    log INFO "Setting operator.watchNamespaces=${NAMESPACE} in values file"
    $SED_CMD -i.bak "s/watchNamespaces:.*/watchNamespaces: \"${NAMESPACE}\"/" "$LS_CONFIG_YAML"
    rm -f "${LS_CONFIG_YAML}.bak"
    
    # Build helm command (quote paths to handle spaces in directory names)
    local helm_cmd="helm upgrade --install langsmith langchain/langsmith"
    helm_cmd+=" --namespace \"${NAMESPACE}\""
    helm_cmd+=" --values \"${LS_CONFIG_YAML}\""
    helm_cmd+=" --wait --timeout 30m"
    helm_cmd+=" --hide-notes"
    
    # Add version if specified
    if [ -n "$VERSION" ]; then
        helm_cmd+=" --version ${VERSION}"
        log INFO "Installing LangSmith version: ${VERSION}"
    fi
    
    # Set frontend service type to ClusterIP when using Ingress resources
    # Both ALB and nginx ingress controllers use Ingress resources, not LoadBalancer services
    # The ingress controller handles external traffic routing, not the service directly
    if [ "$INGRESS_TYPE" = "nginx" ] || [ "$INGRESS_TYPE" = "alb" ]; then
        helm_cmd+=" --set frontend.service.type=ClusterIP"
        log INFO "Set frontend.service.type=ClusterIP for ${INGRESS_TYPE} ingress"
    fi
    
    # Check if CRDs already exist (shared cluster scenario)
    # Skip CRD creation to avoid ownership conflicts with other releases
    if kubectl get crd lgps.apps.langchain.ai &> /dev/null; then
        log INFO "CRD lgps.apps.langchain.ai already exists, skipping CRD creation"
        helm_cmd+=" --set operator.createCRDs=false"
    fi
    
    # Scope operator to this namespace to avoid ClusterRole ownership conflicts
    # on shared clusters where another release already owns "langsmith-operator"
    helm_cmd+=" --set operator.watchNamespaces=${NAMESPACE}"
    log INFO "Scoping operator to namespace: ${NAMESPACE} (avoids ClusterRole conflicts)"
    
    # Check if KEDA is installed - disable if not available (typical for Minikube/local clusters)
    if ! is_keda_installed; then
        log INFO "KEDA not installed, disabling KEDA integration for operator"
        helm_cmd+=" --set operator.kedaEnabled=false"
    fi
    
    # Add debug flag if enabled
    if [ "$DEBUG" = true ]; then
        helm_cmd+=" --debug"
        log INFO "Debug mode enabled"
    fi
    
    log INFO "Executing: ${helm_cmd}"
    
    # Execute helm install
    eval "$helm_cmd"
    
    log SUCCESS "LangSmith installed successfully"
}

##############################################################################
# Function: get_ingress_hostname
# Description: Retrieves the ingress hostname/IP for LangSmith
# Returns: Ingress endpoint (hostname or IP) via stdout
# Note: Log messages are sent to stderr to avoid capturing them in $()
##############################################################################
get_ingress_hostname() {
    local endpoint=""
    local max_attempts=30
    local attempt=0
    
    log INFO "Retrieving ingress hostname for LangSmith Deployment configuration..." >&2
    
    while [ $attempt -lt $max_attempts ]; do
        # Try Ingress resource first (v12+ and ALB/nginx ingress configurations)
        # Try hostname first (AWS ELB), then IP (GKE, AKS, on-prem)
        endpoint=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        
        if [ -z "$endpoint" ]; then
            endpoint=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        fi
        
        # Fallback: Try LoadBalancer service (pre-v12 compatibility)
        if [ -z "$endpoint" ]; then
            endpoint=$(kubectl get svc langsmith-frontend -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        fi
        
        if [ -z "$endpoint" ]; then
            endpoint=$(kubectl get svc langsmith-frontend -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        fi
        
        if [ -n "$endpoint" ]; then
            log SUCCESS "Found ingress endpoint: ${endpoint}" >&2
            echo "$endpoint"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log INFO "Waiting for ingress endpoint... (attempt ${attempt}/${max_attempts})" >&2
        sleep 10
    done
    
    log WARNING "Could not retrieve ingress hostname after ${max_attempts} attempts" >&2
    echo "<pending-ingress-hostname>"
}

##############################################################################
# Function: check_langsmith_installed
# Description: Checks if LangSmith is already installed
##############################################################################
check_langsmith_installed() {
    if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "langsmith"; then
        return 0
    else
        return 1
    fi
}

##############################################################################
# Function: get_helm_release_info
# Description: Gets helm release information for a given release name
# Arguments: $1 - release name (e.g., langsmith)
# Returns: version and status via global variables
##############################################################################
get_helm_release_info() {
    local release_name="$1"
    local helm_output
    
    helm_output=$(helm list -n "$NAMESPACE" --filter "^${release_name}$" -o json 2>/dev/null)
    
    if [ -z "$helm_output" ] || [ "$helm_output" = "[]" ]; then
        echo "not_installed"
        return 0
    fi
    
    # Parse JSON output for version and status
    local chart_version app_version status
    chart_version=$(echo "$helm_output" | grep -o '"chart":"[^"]*"' | head -1 | cut -d'"' -f4)
    app_version=$(echo "$helm_output" | grep -o '"app_version":"[^"]*"' | head -1 | cut -d'"' -f4)
    status=$(echo "$helm_output" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    echo "${status}|${chart_version}|${app_version}"
    return 0
}

##############################################################################
# Function: get_pod_status_summary
# Description: Gets pod status summary for a given label selector
# Arguments: $1 - label selector (e.g., app.kubernetes.io/instance=langsmith)
##############################################################################
get_pod_status_summary() {
    local label_selector="$1"
    local total running pending failed
    local pod_output
    
    # Get pod list once and reuse
    pod_output=$(kubectl get pods -n "$NAMESPACE" -l "$label_selector" --no-headers 2>/dev/null || echo "")
    
    if [ -z "$pod_output" ]; then
        echo "No pods found"
        return
    fi
    
    # Count pods by status (tr -d removes whitespace/newlines for clean integers)
    total=$(echo "$pod_output" | wc -l | tr -d ' \n')
    running=$(echo "$pod_output" | grep -c "Running" 2>/dev/null || true)
    running=${running:-0}
    pending=$(echo "$pod_output" | grep -c "Pending" 2>/dev/null || true)
    pending=${pending:-0}
    failed=$(echo "$pod_output" | grep -cE "(Failed|Error|CrashLoopBackOff)" 2>/dev/null || true)
    failed=${failed:-0}
    
    # Build status string
    local status_str="${running}/${total} Running"
    if [ "$pending" -gt 0 ] 2>/dev/null; then
        status_str+=", ${pending} Pending"
    fi
    if [ "$failed" -gt 0 ] 2>/dev/null; then
        status_str+=", ${failed} Failed"
    fi
    
    echo "$status_str"
}

##############################################################################
# Function: show_status
# Description: Displays installation status of LangSmith
##############################################################################
show_status() {
    echo ""
    echo "=========================================================================="
    echo -e "${BLUE}LangSmith Installation Status${NC}"
    echo "=========================================================================="
    echo ""
    echo -e "Namespace: ${GREEN}${NAMESPACE}${NC}"
    echo ""
    
    # Check LangSmith status
    echo -e "${BLUE}LangSmith:${NC}"
    local ls_info
    ls_info=$(get_helm_release_info "langsmith")
    
    # Extract fields first to check if we have valid data
    local ls_status ls_chart ls_app
    ls_status=$(echo "$ls_info" | cut -d'|' -f1)
    ls_chart=$(echo "$ls_info" | cut -d'|' -f2)
    ls_app=$(echo "$ls_info" | cut -d'|' -f3)
    
    if [ -z "$ls_info" ] || [ "$ls_info" = "not_installed" ] || [ -z "$ls_status" ] || [ "$ls_status" = "not_installed" ]; then
        echo -e "  Status:   ${YELLOW}Not Installed${NC}"
    else
        if [ "$ls_status" = "deployed" ]; then
            echo -e "  Status:   ${GREEN}Installed${NC}"
        else
            echo -e "  Status:   ${YELLOW}${ls_status}${NC}"
        fi
        echo -e "  Chart:    ${ls_chart}"
        [ -n "$ls_app" ] && echo -e "  Version:  ${ls_app}"
        
        # Get pod status
        local pod_status
        pod_status=$(get_pod_status_summary "app.kubernetes.io/instance=langsmith")
        echo -e "  Pods:     ${pod_status}"
    fi
    echo ""
    
    # Check ingress endpoint
    local endpoint=""
    endpoint=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -z "$endpoint" ]; then
        endpoint=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    fi
    
    if [ -n "$endpoint" ]; then
        echo -e "Ingress:   ${GREEN}http://${endpoint}${NC}"
    else
        echo -e "Ingress:   ${YELLOW}Not available${NC}"
    fi
    
    echo ""
    echo "=========================================================================="
    echo ""
}

##############################################################################
# Function: install_langsmith_deployment
# Description: Installs LangSmith Deployment using Helm
##############################################################################
install_langsmith_deployment() {
    log INFO "Installing LangSmith Deployment..."
    
    # For v12+, LangSmith needs config.deployment.enabled=true to show Deployments UI
    if [ "$IS_V12_PLUS" = true ]; then
        log INFO "Enabling deployment feature in LangSmith (v12+)..."
        
        # Create/update LangSmith config with deployment enabled
        create_langsmith_config
        
        # Determine hostname for deployment (required in v12+ when deployment is enabled)
        # Priority: 1) User-specified LANGSMITH_HOSTNAME, 2) Existing ingress, 3) localhost fallback
        local ingress_hostname=""
        
        # Priority 1: User-specified hostname from .env
        if [ -n "$LANGSMITH_HOSTNAME" ]; then
            ingress_hostname="$LANGSMITH_HOSTNAME"
            log INFO "Using user-specified hostname: ${ingress_hostname}"
        # Priority 2: Try to get from existing ingress (for upgrades)
        elif ! is_minikube_cluster; then
            ingress_hostname=$(get_ingress_hostname 2>/dev/null || echo "")
            # Convert IP to nip.io if needed for nginx ingress
            if [ -n "$ingress_hostname" ] && [ "$ingress_hostname" != "<pending-ingress-hostname>" ] && [ "$INGRESS_TYPE" = "nginx" ]; then
                if [[ "$ingress_hostname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    log INFO "Converting IP address to nip.io DNS name for nginx ingress"
                    ingress_hostname="${ingress_hostname}.nip.io"
                fi
            fi
        fi
        
        # Priority 3: Fallback to localhost (works with port-forward)
        if [ -z "$ingress_hostname" ] || [ "$ingress_hostname" = "<pending-ingress-hostname>" ]; then
            ingress_hostname="localhost"
            log INFO "Using default hostname: localhost (use port-forward to access)"
        fi
        
        # Add deployment section to ls_config.yaml for LangSmith chart
        # Always include both deployment.enabled AND hostname (required in v12+)
        local temp_insert=$(mktemp)
        log INFO "Adding config.deployment.enabled and config.hostname to LangSmith config"
        cat > "$temp_insert" << EOF
  deployment:
    enabled: true
  hostname: "${ingress_hostname}"
EOF
        $SED_CMD -i.bak "/^config:/r $temp_insert" "$LS_CONFIG_YAML"
        rm -f "$temp_insert" "${LS_CONFIG_YAML}.bak"
        
        # Scope operator to this namespace in the values file to ensure the chart
        # renders namespaced Role/RoleBinding instead of cluster-scoped ClusterRole.
        # Prevents "invalid ownership metadata" errors on shared clusters.
        log INFO "Setting operator.watchNamespaces=${NAMESPACE} in values file"
        $SED_CMD -i.bak "s/watchNamespaces:.*/watchNamespaces: \"${NAMESPACE}\"/" "$LS_CONFIG_YAML"
        rm -f "${LS_CONFIG_YAML}.bak"
        
        # Always upgrade LangSmith to ensure deployment is enabled
        log INFO "Upgrading LangSmith with deployment feature enabled..."
        local helm_cmd="helm upgrade --install langsmith langchain/langsmith"
        helm_cmd+=" --namespace \"${NAMESPACE}\""
        helm_cmd+=" --values \"${LS_CONFIG_YAML}\""
        helm_cmd+=" --wait --timeout 30m"
        helm_cmd+=" --hide-notes"
        
        # Add version if specified (important: preserve version when upgrading for deployment)
        if [ -n "$VERSION" ]; then
            helm_cmd+=" --version ${VERSION}"
            log INFO "Using LangSmith version: ${VERSION}"
        fi
        
        # Only skip CRD creation if CRD already exists (shared cluster scenario)
        # This prevents "invalid ownership metadata" errors in shared clusters
        if kubectl get crd lgps.apps.langchain.ai &> /dev/null; then
            log INFO "CRD lgps.apps.langchain.ai already exists, skipping CRD creation"
            helm_cmd+=" --set operator.createCRDs=false"
        fi
        
        # Scope operator to this namespace to avoid ClusterRole ownership conflicts
        helm_cmd+=" --set operator.watchNamespaces=${NAMESPACE}"
        log INFO "Scoping operator to namespace: ${NAMESPACE} (avoids ClusterRole conflicts)"
        
        # Check if KEDA is installed - disable if not available (typical for Minikube/local clusters)
        if ! is_keda_installed; then
            log INFO "KEDA not installed, disabling KEDA integration for operator"
            helm_cmd+=" --set operator.kedaEnabled=false"
        fi
        
        if [ "$INGRESS_TYPE" = "nginx" ] || [ "$INGRESS_TYPE" = "alb" ]; then
            helm_cmd+=" --set frontend.service.type=ClusterIP"
        fi
        
        if [ "$DEBUG" = true ]; then
            helm_cmd+=" --debug"
        fi
        
        log INFO "Executing: ${helm_cmd}"
        eval "$helm_cmd"
        log SUCCESS "LangSmith upgraded with deployment feature enabled"
    else
        # Pre-v12: Enable langgraphPlatform feature
        log INFO "Enabling langgraphPlatform feature in LangSmith (pre-v12)..."
        
        # Create/update LangSmith config
        create_langsmith_config
        
        # Scope operator to this namespace in the values file
        log INFO "Setting operator.watchNamespaces=${NAMESPACE} in values file"
        $SED_CMD -i.bak "s/watchNamespaces:.*/watchNamespaces: \"${NAMESPACE}\"/" "$LS_CONFIG_YAML"
        rm -f "${LS_CONFIG_YAML}.bak"
        
        # Add langgraphPlatform.enabled to ls_config.yaml for pre-v12
        local temp_insert=$(mktemp)
        log INFO "Adding config.langgraphPlatform.enabled to LangSmith config"
        cat > "$temp_insert" << EOF
  langgraphPlatform:
    enabled: true
EOF
        $SED_CMD -i.bak "/^config:/r $temp_insert" "$LS_CONFIG_YAML"
        rm -f "$temp_insert" "${LS_CONFIG_YAML}.bak"
        
        # Run helm upgrade with the config
        log INFO "Upgrading LangSmith with langgraphPlatform feature enabled..."
        local helm_cmd="helm upgrade --install langsmith langchain/langsmith"
        helm_cmd+=" --namespace \"${NAMESPACE}\""
        helm_cmd+=" --values \"${LS_CONFIG_YAML}\""
        helm_cmd+=" --wait --timeout 30m"
        helm_cmd+=" --hide-notes"
        
        # Add version if specified
        if [ -n "$VERSION" ]; then
            helm_cmd+=" --version ${VERSION}"
            log INFO "Using LangSmith version: ${VERSION}"
        fi
        
        # Only skip CRD creation if CRD already exists (shared cluster scenario)
        if kubectl get crd lgps.apps.langchain.ai &> /dev/null; then
            log INFO "CRD lgps.apps.langchain.ai already exists, skipping CRD creation"
            helm_cmd+=" --set operator.createCRDs=false"
        fi
        
        # Scope operator to this namespace to avoid ClusterRole ownership conflicts
        helm_cmd+=" --set operator.watchNamespaces=${NAMESPACE}"
        log INFO "Scoping operator to namespace: ${NAMESPACE} (avoids ClusterRole conflicts)"
        
        # Check if KEDA is installed - disable if not available
        if ! is_keda_installed; then
            log INFO "KEDA not installed, disabling KEDA integration for operator"
            helm_cmd+=" --set operator.kedaEnabled=false"
        fi
        
        if [ "$INGRESS_TYPE" = "nginx" ] || [ "$INGRESS_TYPE" = "alb" ]; then
            helm_cmd+=" --set frontend.service.type=ClusterIP"
        fi
        
        if [ "$DEBUG" = true ]; then
            helm_cmd+=" --debug"
        fi
        
        log INFO "Executing: ${helm_cmd}"
        eval "$helm_cmd"
        log SUCCESS "LangSmith upgraded with langgraphPlatform feature enabled"
    fi
    
    log SUCCESS "LangSmith Deployment feature enabled successfully"
}

##############################################################################
# Function: display_langsmith_info
# Description: Displays LangSmith connection information
##############################################################################
display_langsmith_info() {
    log INFO "Waiting for ingress to be ready..."
    sleep 10
    
    # Get ingress endpoint (supports both hostname and IP for cross-platform compatibility)
    local endpoint=""
    local max_attempts=30
    local attempt=0
    local endpoint_pending=false
    local is_minikube=false
    local minikube_port="8080"
    
    # Check if running on Minikube
    if is_minikube_cluster; then
        is_minikube=true
        log INFO "Minikube cluster detected - will use port-forward for access"
    fi
    
    while [ $attempt -lt $max_attempts ]; do
        # Try Ingress resource first (v12+ and ALB/nginx ingress configurations)
        # Try hostname first (AWS ELB), then IP (GKE, AKS, on-prem)
        endpoint=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        
        if [ -z "$endpoint" ]; then
            endpoint=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        fi
        
        # Fallback: Try LoadBalancer service (pre-v12 compatibility)
        if [ -z "$endpoint" ]; then
            endpoint=$(kubectl get svc langsmith-frontend -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        fi
        
        if [ -z "$endpoint" ]; then
            endpoint=$(kubectl get svc langsmith-frontend -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        fi
        
        if [ -n "$endpoint" ]; then
            break
        fi
        
        attempt=$((attempt + 1))
        log INFO "Waiting for ingress endpoint... (attempt ${attempt}/${max_attempts})"
        sleep 10
    done
    
    # For Minikube, start port-forward and use localhost endpoint
    if [ "$is_minikube" = true ]; then
        log INFO "Setting up port-forward for Minikube access..."
        if start_minikube_port_forward "$minikube_port"; then
            endpoint="localhost:${minikube_port}"
        else
            # Fallback: show the Minikube IP but warn user
            if [ -z "$endpoint" ]; then
                endpoint=$(minikube ip 2>/dev/null || echo "")
            fi
            if [ -z "$endpoint" ]; then
                endpoint_pending=true
                endpoint="YOUR_LANGSMITH_ENDPOINT"
            fi
        fi
    elif [ -z "$endpoint" ]; then
        endpoint_pending=true
        endpoint="YOUR_LANGSMITH_ENDPOINT"
    fi
    
    echo ""
    echo "=========================================================================="
    echo -e "${GREEN}LangSmith Installation Complete!${NC}"
    echo "=========================================================================="
    echo ""
    echo -e "${BLUE}Connection Details:${NC}"
    echo "-------------------"
    echo -e "Namespace: ${GREEN}${NAMESPACE}${NC}"
    if [ "$endpoint_pending" = true ]; then
        echo -e "Endpoint:  ${YELLOW}PENDING${NC}"
        echo ""
        echo -e "${YELLOW}⚠️  Endpoint is not ready yet. To retrieve it, run:${NC}"
        echo -e "    ${GREEN}kubectl get ingress -n ${NAMESPACE}${NC}"
        echo -e "    ${GREEN}kubectl get svc langsmith-frontend -n ${NAMESPACE}${NC}"
    else
        echo -e "Endpoint:  ${GREEN}http://${endpoint}${NC}"
    fi
    echo -e "Email:     ${GREEN}${initialOrgAdminEmail}${NC}"
    echo -e "Password:  ${GREEN}${initialOrgAdminPassword}${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Important: Save these credentials securely!${NC}"
    if [ "$is_minikube" = true ]; then
        echo ""
        echo -e "${YELLOW}⚠️  Minikube Note: Port-forward is running in the background.${NC}"
        echo -e "${YELLOW}    If you restart your terminal, run:${NC}"
        echo -e "    ${GREEN}kubectl port-forward svc/ingress-nginx-controller -n ingress-nginx ${minikube_port}:80${NC}"
    fi
    echo ""
    echo -e "${RED}⚠️  WARNING: Resource Usage Alert${NC}"
    echo -e "${RED}    Delete right after reproduction if billable, as amount of using resources per installation is high!${NC}"
    echo ""
    echo "=========================================================================="
    echo -e "${BLUE}Example Python Usage:${NC}"
    echo ""
    cat << EOF
import os

os.environ["LANGSMITH_TRACING"] = "true"
os.environ["LANGSMITH_ENDPOINT"] = "http://${endpoint}/api/v1"
os.environ["LANGSMITH_API_KEY"] = "YOUR_KEY"
os.environ["OPENAI_API_KEY"] = "YOUR_KEY"
os.environ["LANGSMITH_PROJECT"] = "YOUR_PROJECT"
EOF
    if [ "$endpoint_pending" = true ]; then
        echo ""
        echo -e "${YELLOW}Note: Replace YOUR_LANGSMITH_ENDPOINT with the actual endpoint once available.${NC}"
    fi
    echo ""
    echo " More details: https://docs.langchain.com/langsmith/self-host-usage"
    echo ""
    echo "=========================================================================="
    echo ""
}

##############################################################################
# Function: uninstall_from_namespace
# Description: Uninstalls LangSmith and LangSmith Deployment from a single namespace
# Arguments:  $1 - namespace to uninstall from
##############################################################################
uninstall_from_namespace() {
    local targetNs="$1"

    log INFO "Uninstalling LangSmith from namespace: ${targetNs}..."

    # Check if namespace exists
    if ! kubectl get namespace "$targetNs" &> /dev/null; then
        log WARNING "Namespace ${targetNs} does not exist. Skipping."
        return 0
    fi

    # Uninstall LangSmith Helm release
    log INFO "Uninstalling Helm release 'langsmith' in ${targetNs}..."
    helm uninstall langsmith -n "$targetNs" 2>/dev/null || log WARNING "LangSmith not found or already uninstalled in ${targetNs}"

    # List PVCs
    log INFO "Listing Persistent Volume Claims in ${targetNs}..."
    kubectl get pvc -n "$targetNs" 2>/dev/null || log INFO "No PVCs found in ${targetNs}"

    # Delete PVCs
    log INFO "Deleting Persistent Volume Claims in ${targetNs}..."
    kubectl delete pvc \
        data-langsmith-clickhouse-0 \
        data-langsmith-postgres-0 \
        data-langsmith-redis-0 \
        -n "$targetNs" --ignore-not-found 2>/dev/null || true

    # Delete namespace
    log INFO "Deleting namespace: ${targetNs}"
    kubectl delete namespace "$targetNs" --ignore-not-found

    log SUCCESS "Uninstallation completed for namespace: ${targetNs}"
}

##############################################################################
# Function: discover_langsmith_namespaces
# Description: Finds all namespaces that have a 'langsmith' Helm release or
#              langsmith pods. Results are deduplicated by the caller.
# Output:     Prints matching namespace names (one per line) to stdout
##############################################################################
discover_langsmith_namespaces() {
    # Method 1: Find namespaces with a Helm release named 'langsmith'
    # Table output column 2 is NAMESPACE (skip header with NR>1)
    helm list --all-namespaces --filter '^langsmith$' 2>/dev/null \
        | awk 'NR>1 {print $2}' || true

    # Method 2: Find namespaces that have langsmith pods
    # Covers edge cases where Helm release was partially removed
    kubectl get pods --all-namespaces -l 'app.kubernetes.io/name=langsmith' \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null || true
}

##############################################################################
# Function: uninstall_all
# Description: Uninstalls LangSmith and LangSmith Deployment from one or all
#              namespaces. When NAMESPACE is set (via -n), removes from that
#              namespace only. Otherwise, discovers and removes from all
#              namespaces that have a langsmith deployment.
##############################################################################
uninstall_all() {
    log INFO "Starting uninstallation process for both LangSmith and LangSmith Deployment..."

    # Stop port-forward if running on Minikube
    if is_minikube_cluster; then
        log INFO "Minikube cluster detected - stopping port-forward..."
        stop_minikube_port_forward
    fi

    # Determine target namespaces
    local namespaces=()

    if [ -n "$NAMESPACE" ]; then
        # User specified a namespace via -n
        namespaces=("$NAMESPACE")
    else
        # Discover all namespaces with langsmith deployments
        log INFO "No namespace specified — discovering all LangSmith deployments across the cluster..."
        local discovered
        discovered=$(discover_langsmith_namespaces | sort -u)

        if [ -z "$discovered" ]; then
            log WARNING "No LangSmith deployments found in any namespace. Nothing to uninstall."
            return 0
        fi

        while IFS= read -r ns; do
            [ -n "$ns" ] && namespaces+=("$ns")
        done <<< "$discovered"

        log INFO "Found LangSmith deployments in ${#namespaces[@]} namespace(s): ${namespaces[*]}"
    fi

    # Uninstall from each namespace
    local failCount=0
    for ns in "${namespaces[@]}"; do
        if ! uninstall_from_namespace "$ns"; then
            log WARNING "Failed to fully uninstall from namespace: ${ns}"
            ((failCount++))
        fi
    done

    # Remove local configuration files
    log INFO "Removing local configuration files..."
    [ -f "$LS_CONFIG_YAML" ] && rm -f "$LS_CONFIG_YAML" && log INFO "Removed ${LS_CONFIG_YAML}"

    if [ "$failCount" -gt 0 ]; then
        log WARNING "Uninstallation completed with ${failCount} warning(s)"
    else
        log SUCCESS "Uninstallation completed successfully for all namespaces"
    fi
}

##############################################################################
# Main execution
##############################################################################
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # For status action, only set namespace and show status (minimal output)
    if [ "$ACTION" = "status" ]; then
        # Use custom namespace if provided via -n, otherwise generate from hostname
        if [ -z "$NAMESPACE" ]; then
            NAMESPACE=$(hostname | tr '[:upper:]' '[:lower:]' | tr '.' '-')
            # Strip leading digits/hyphens from auto-generated namespace
            NAMESPACE=$(echo "$NAMESPACE" | sed 's/^[^a-z]*//')
        fi
        if ! validate_namespace "$NAMESPACE"; then
            exit 1
        fi
        show_status
        return 0
    fi
    
    log INFO "Starting LangSmith/LangSmith Deployment Installation Script"
    
    # Check prerequisites
    check_prerequisites
    
    # For 'down' action, skip setup steps that are only needed for installation.
    # uninstall_all handles namespace discovery internally.
    if [ "$ACTION" = "down" ]; then
        # If user specified -n, validate it before proceeding
        if [ -n "$NAMESPACE" ]; then
            if ! validate_namespace "$NAMESPACE"; then
                exit 1
            fi
            log INFO "Will uninstall from namespace: ${NAMESPACE}"
        else
            log INFO "No namespace specified — will discover and remove all LangSmith deployments"
        fi
        uninstall_all
    else
        # Setup namespace (required for 'up')
        setup_namespace
        
        # Auto-detect ingress type based on cluster (EKS -> ALB, others -> nginx)
        set_ingress_type
        
        # Load configuration
        load_configuration
        
        # Setup Helm repository
        setup_helm_repo
        
        # Execute action
        case "$ACTION" in
            up)
                if [ "$INSTALL_LS" = true ]; then
                    install_langsmith
                fi
                
                if [ "$INSTALL_LD" = true ]; then
                    install_langsmith_deployment
                fi
                
                # Display connection information after any installation
                if [ "$INSTALL_LS" = true ] || [ "$INSTALL_LD" = true ]; then
                    display_langsmith_info
                fi
                ;;
            *)
                log ERROR "Unknown action: ${ACTION}"
                exit 1
                ;;
        esac
    fi
    
    log SUCCESS "Script completed successfully"
}

# Execute main function with all arguments
main "$@"

