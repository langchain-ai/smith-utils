#!/bin/bash

##############################################################################
# LangSmith and LangSmith Deployment Installation Script for Kubernetes Clusters
# 
# Description: Automates the installation and management of LangSmith,
#              LangSmith Deployment, and Fleet on any Kubernetes cluster (cross-platform)
# 
# Usage: ./smith-fly.sh <up|down|status> [-l|-ls|-ld|-lds|-lda|-ldas] [-v VERSION] [-n NAMESPACE]
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
INSTALL_AB=false  # Fleet (requires Deployment)
INSTALL_INSIGHTS=false  # Insights (requires Deployment + Fleet)
INSTALL_POLLY=false     # Polly (requires Deployment + Fleet)
OPERATOR_SCALED_DOWN=false  # Safety flag: true while operator is at 0 replicas during bootstrap
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
POPULATE=false  # Whether to run populate.sh after install
RESOLVED_ENDPOINT=""  # Set by display_langsmith_info for use by populate
LANGSMITH_HOSTNAME=""  # Optional: custom hostname for LangSmith (can be set via .env)
fleetEncryptionKey=""  # Fernet key for Fleet (auto-generated or preserved)
insightsEncryptionKey=""      # Fernet key for Insights (auto-generated or preserved)
pollyEncryptionKey=""         # Fernet key for Polly (auto-generated or preserved)

# Authentication / provisioning (Keycloak OAuth/OIDC). Default path is unchanged
# basic auth; --auth keycloak swaps in the OAuth block and --provisioning selects
# how org/workspace roles flow into LangSmith. See docs/keycloak-oauth-scim.md.
AUTH_MODE="basic"            # basic | keycloak
PROVISIONING_MODE="none"     # none | groups-sync | scim
# Keycloak coordinates (sourced from config/.env when --auth keycloak)
KEYCLOAK_ISSUER_URL=""       # e.g. https://keycloak.<host>/realms/langsmith
OAUTH_CLIENT_ID=""
OAUTH_CLIENT_SECRET=""
OAUTH_SCOPES=""              # optional override; defaults to "email,profile,openid"
ISSUER_SUB_CLAIM_OVERRIDES="" # optional; e.g. "oid" when sub != SCIM externalId

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
    if [ "$OPERATOR_SCALED_DOWN" = true ] && [ -n "$NAMESPACE" ]; then
        log WARNING "Restoring operator to 1 replica after interruption..."
        kubectl scale deployment langsmith-operator -n "$NAMESPACE" --replicas=1 2>/dev/null || true
        OPERATOR_SCALED_DOWN=false
    fi
}

# Set trap for error handling (ERR for failures, INT/TERM for Ctrl+C and kill)
trap cleanup_on_error ERR INT TERM

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
# Function: is_version_v13_plus
# Description: Checks if specified version is >= 0.13.0
# Returns: 0 if version >= 0.13.0 or empty (latest), 1 otherwise
##############################################################################
is_version_v13_plus() {
    local version="$1"
    local major minor

    if [ -z "$version" ]; then
        return 0
    fi

    IFS='.' read -r major minor _ <<< "$version"

    if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    if [ "$major" -gt 0 ] || [ "$minor" -ge 13 ]; then
        return 0
    fi

    return 1
}

##############################################################################
# Function: is_version_v15_plus
# Description: Checks if specified version is >= 0.15.0
# Returns: 0 if version >= 0.15.0 or empty (latest), 1 otherwise
##############################################################################
is_version_v15_plus() {
    local version="$1"
    local major minor

    if [ -z "$version" ]; then
        return 0
    fi

    IFS='.' read -r major minor _ <<< "$version"

    if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    if [ "$major" -gt 0 ] || [ "$minor" -ge 15 ]; then
        return 0
    fi

    return 1
}

##############################################################################
# Function: is_version_in_range
# Description: Checks if version is within a specific minor version range (inclusive)
# Args: version, min_minor, max_minor (assumes major=0)
# Returns: 0 if in range, 1 otherwise. Empty version (latest) returns 1.
##############################################################################
is_version_in_range() {
    local version="$1"
    local min_minor="$2"
    local max_minor="$3"
    local major minor patch

    if [ -z "$version" ]; then
        return 1
    fi

    IFS='.' read -r major minor patch <<< "$version"

    if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Only check within 0.13.x range
    if [ "$major" -eq 0 ] && [ "$minor" -eq 13 ]; then
        patch=${patch:-0}
        if [ "$patch" -ge "$min_minor" ] && [ "$patch" -le "$max_minor" ]; then
            return 0
        fi
    fi

    return 1
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
Usage: $0 <up|down|status> [-l|-ls|-ld|-lds|-lda|-ldas] [-v VERSION] [-n NAMESPACE] [-i alb|nginx] [--debug]

Actions:
    up      Spin up/install LangSmith, LangSmith Deployment, or Fleet
    down    Remove LangSmith from all namespaces (or a specific one with -n)
    status  Check installation status of LangSmith and LangSmith Deployment

Options (for 'up' action):
    -l      Install LangSmith (tracing, eval, playground)
    -ls     Install LangSmith + populate with synthetic test data (traces, feedback, datasets, prompts)
    -ld     Install LangSmith Deployment (adds LangGraph deployment to -l)
    -lds    Install LangSmith Deployment + populate with synthetic test data
    -lda    Install LangSmith Deployment + Fleet (adds no-code agent creation to -ld, v0.15+)
    -ldas   Install LangSmith Deployment + Fleet + populate with synthetic test data
    -ld[a][i][p]  Install LangSmith Deployment with optional add-ons (v0.15+ required for add-ons):
                    a = Fleet (no-code agent creation)
                    i = Insights
                    p = Polly
                  Letters can be combined in any order, e.g. -lda -ldi -ldp -ldai -ldip -ldap -ldaip
    -v      Specify version (optional)
    -n      Custom namespace (must start with a letter, lowercase alphanumeric/hyphens, max 63 chars)
    -i      Ingress type: alb or nginx (auto-detected if not specified)
    --auth          basic|keycloak (default basic). keycloak delegates login to Keycloak
                    via OAuth/OIDC (requires HTTPS + Keycloak coords in ${ENV_FILE}).
    --provisioning  none|groups-sync|scim (default none). Requires --auth keycloak.
                    groups-sync: LangSmith reads group claims at login (chart >= 0.15.0-rc.3).
                    scim: Keycloak pushes users/groups outbound (needs SCIM extension + token).


Examples:
    $0 up -l                     # Install LangSmith (ingress auto-detected based on cluster)
    $0 up -l -n my-namespace     # Install LangSmith in custom namespace
    $0 up -l -i alb              # Install LangSmith with ALB ingress (override auto-detect)
    $0 up -l -i nginx            # Install LangSmith with nginx ingress (override auto-detect)
    $0 up -l -v 0.12.3           # Install LangSmith v12+ with specific version
    $0 up -l -v 0.11.5           # Install LangSmith pre-v12 with legacy config format
    $0 up -ld                    # Install LangSmith Deployment (automatically installs LangSmith if not present)
    $0 up -ld -i nginx           # Install LangSmith Deployment with nginx ingress
    $0 up -ld -v 0.11.0          # Install LangSmith Deployment with pre-v12 config format
    $0 up -ls                    # Install LangSmith and populate with synthetic test data
    $0 up -ldas                  # Install everything + populate with synthetic test data
    $0 up -lda                   # Install LangSmith Deployment + Fleet (requires more resources)
    $0 up -ldi                   # Install LangSmith Deployment + Insights
    $0 up -ldp                   # Install LangSmith Deployment + Polly
    $0 up -ldai                  # Install LangSmith Deployment + Fleet + Insights
    $0 up -ldip                  # Install LangSmith Deployment + Insights + Polly
    $0 up -ldaip                 # Install LangSmith Deployment + Fleet + Insights + Polly
    $0 up -ld --auth keycloak                          # OAuth login via Keycloak (HTTPS), no provisioning
    $0 up -ld --auth keycloak --provisioning groups-sync  # OAuth + SSO Groups Sync (chart >= 0.15.0-rc.3)
    $0 up -ld --auth keycloak --provisioning scim      # OAuth + SCIM (outbound from Keycloak)
    $0 down                      # Remove LangSmith from ALL namespaces (auto-discovers deployments)
    $0 down -n my-namespace      # Remove LangSmith from a specific namespace only
    $0 status                    # Check installation status of LangSmith and LangSmith Deployment
    $0 status -n my-namespace    # Check status in a custom namespace

Notes:
    - At least one of -l, -ls, -ld, -lds, -lda, or -ldas must be specified with "up"
    - When installing LangSmith Deployment (-ld), LangSmith is automatically installed if not already present
    - Fleet (-lda) deploys additional standalone pods (its own Postgres, Redis, queue, API server, tool & trigger servers)
    - On Minikube, -lda auto-patches LGP resources to dev-friendly sizes and disables autoscaling
    - Recommended Minikube resources for -lda: 10 CPUs / 24Gi RAM (Docker Desktop)
    - The "down" action removes LangSmith from all namespaces (or a specific one with -n)
    - Configuration is read from ${ENV_FILE}
    - Namespace is auto-generated from hostname unless overridden with -n
    - Version >= 0.12.0 uses new config format (config.deployment, config.hostname)
    - Version < 0.12.0 uses legacy config format (config.langgraphPlatform, langgraphPlatformLicenseKey)
    - Ingress type is auto-detected: AWS EKS -> ALB, other clusters -> nginx
    - Use -i flag to override auto-detection (e.g., -i alb or -i nginx)
    - --auth keycloak requires Keycloak running first (scripts/keycloak.sh up) and
      KEYCLOAK_ISSUER_URL / OAUTH_CLIENT_ID / OAUTH_CLIENT_SECRET set in ${ENV_FILE}
    - OAuth + SSO/SCIM are LangSmith Enterprise features; the license key must enable them
    - Switching --auth is one-directional in self-hosted: revert with "down" + reinstall

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
            -ls)
                INSTALL_LS=true
                POPULATE=true
                shift
                ;;
            -ld)
                INSTALL_LD=true
                shift
                ;;
            -lds)
                INSTALL_LD=true
                POPULATE=true
                shift
                ;;
            # Must precede -ld*: -ldas matches -ld* first and suffix "as" fails [^aip] validation.
            -ldas)
                INSTALL_LD=true
                INSTALL_AB=true
                POPULATE=true
                shift
                ;;
            -ld*)
                local suffix="${1#-ld}"
                # Validate suffix contains only valid feature letters: a, i, p
                if [[ -n "$suffix" ]] && [[ "$suffix" =~ [^aip] ]]; then
                    log ERROR "Unknown option: $1"
                    show_usage
                fi
                INSTALL_LD=true
                [[ "$suffix" == *"a"* ]] && INSTALL_AB=true
                [[ "$suffix" == *"i"* ]] && INSTALL_INSIGHTS=true
                [[ "$suffix" == *"p"* ]] && INSTALL_POLLY=true
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
            --auth)
                if [ $# -lt 2 ]; then
                    log ERROR "--auth option requires an argument (basic or keycloak)"
                    show_usage
                fi
                case "$2" in
                    basic|keycloak)
                        AUTH_MODE="$2"
                        ;;
                    *)
                        log ERROR "Invalid auth mode: $2. Must be 'basic' or 'keycloak'"
                        show_usage
                        ;;
                esac
                shift 2
                ;;
            --provisioning)
                if [ $# -lt 2 ]; then
                    log ERROR "--provisioning option requires an argument (none, groups-sync, or scim)"
                    show_usage
                fi
                case "$2" in
                    none|groups-sync|scim)
                        PROVISIONING_MODE="$2"
                        ;;
                    *)
                        log ERROR "Invalid provisioning mode: $2. Must be 'none', 'groups-sync', or 'scim'"
                        show_usage
                        ;;
                esac
                shift 2
                ;;
            --config-dir)
                if [ $# -lt 2 ]; then
                    log ERROR "--config-dir option requires a directory argument"
                    show_usage
                fi
                CONFIG_DIR="$2"
                ENV_FILE="${CONFIG_DIR}/.env"
                CONFIG_YAML="${CONFIG_DIR}/config.yaml"
                LS_CONFIG_YAML="${CONFIG_DIR}/ls_config.yaml"
                shift 2
                ;;
            *)
                log ERROR "Unknown option: $1"
                show_usage
                ;;
        esac
    done

    # Validate that at least one of -l, -ld, or -lda is specified for 'up' action
    if [ "$ACTION" = "up" ]; then
        if [ "$INSTALL_LS" = false ] && [ "$INSTALL_LD" = false ]; then
            log ERROR "At least one of -l, -ld, or -lda must be specified with 'up' action"
            show_usage
        fi
    fi
    
    # Validate version requirements for Fleet / Insights / Polly.
    # The top-level fleet/insights/polly Deployment model first shipped in chart 0.15.0.
    if [ "$ACTION" = "up" ] && { [ "$INSTALL_AB" = true ] || [ "$INSTALL_INSIGHTS" = true ] || [ "$INSTALL_POLLY" = true ]; }; then
        if ! is_version_v15_plus "$VERSION"; then
            log ERROR "Fleet / Insights / Polly require chart version >= 0.15.0. Specified: ${VERSION}"
            exit 1
        fi
    fi

    # Validate authentication / provisioning flag relationships (for 'up').
    # The .env value checks happen later in validate_auth_config (after .env is sourced).
    if [ "$ACTION" = "up" ]; then
        # OAuth is orthogonal to the install flavor (works with -l, -ld, and add-ons).
        # Provisioning automation only makes sense with OAuth — it layers on top of it.
        if [ "$PROVISIONING_MODE" != "none" ] && [ "$AUTH_MODE" != "keycloak" ]; then
            log ERROR "--provisioning ${PROVISIONING_MODE} requires --auth keycloak"
            show_usage
        fi
        # SSO Groups Sync first shipped in chart 0.15.0-rc.3; reuse the v15+ guard.
        if [ "$PROVISIONING_MODE" = "groups-sync" ] && ! is_version_v15_plus "$VERSION"; then
            log ERROR "--provisioning groups-sync requires chart version >= 0.15.0-rc.3. Specified: ${VERSION:-latest}"
            exit 1
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
        log INFO "Install Fleet: ${INSTALL_AB}"
        log INFO "Install Insights: ${INSTALL_INSIGHTS}"
        log INFO "Install Polly: ${INSTALL_POLLY}"
        log INFO "Auth Mode: ${AUTH_MODE}"
        log INFO "Provisioning Mode: ${PROVISIONING_MODE}"
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
# Function: validate_auth_config
# Description: Validates Keycloak OAuth prerequisites. Runs AFTER load_configuration
#              so the .env-sourced OAuth coordinates are available.
##############################################################################
validate_auth_config() {
    if [ "$AUTH_MODE" != "keycloak" ]; then
        return 0
    fi

    log INFO "Validating Keycloak OAuth configuration..."

    local missing=()
    [ -z "${KEYCLOAK_ISSUER_URL:-}" ] && missing+=("KEYCLOAK_ISSUER_URL")
    [ -z "${OAUTH_CLIENT_ID:-}" ]     && missing+=("OAUTH_CLIENT_ID")
    [ -z "${OAUTH_CLIENT_SECRET:-}" ] && missing+=("OAUTH_CLIENT_SECRET")

    if [ ${#missing[@]} -gt 0 ]; then
        log ERROR "--auth keycloak requires these values in ${ENV_FILE}: ${missing[*]}"
        log ERROR "Add them to ${ENV_FILE} (see config/.env.example). Bring up Keycloak first with:"
        log ERROR "    ${SCRIPT_DIR}/scripts/keycloak.sh up"
        exit 1
    fi

    log SUCCESS "Keycloak OAuth configuration is valid"
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
# Function: helm_with_progress
# Description: Runs a helm command in the background and prints a live pod
#   status summary every 15 seconds while waiting for it to complete.
#   This prevents the terminal from appearing frozen during long --wait calls.
# Arguments: $@ - the full helm command string passed to eval
##############################################################################
helm_with_progress() {
    local helm_cmd="$1"
    local helm_log
    helm_log=$(mktemp)

    # If a previous run was interrupted mid-upgrade the release may be stuck in a
    # "pending-*" state, which causes "another operation is in progress" errors.
    # Roll back to the last good revision to clear the lock before proceeding.
    local release_status
    release_status=$(helm status langsmith -n "$NAMESPACE" -o json 2>/dev/null \
        | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('info',{}).get('status',''))" \
        2>/dev/null) || release_status=""
    if [[ "$release_status" == pending-* ]]; then
        if [[ "$release_status" == "pending-install" ]]; then
            # No prior revision exists — uninstall to clear the lock
            log WARNING "Helm release is stuck in '${release_status}' — uninstalling to clear lock..."
            helm uninstall langsmith -n "$NAMESPACE" 2>/dev/null || true
        else
            # pending-upgrade/pending-rollback — roll back to last good revision
            log WARNING "Helm release is stuck in '${release_status}' — rolling back to recover..."
            helm rollback langsmith -n "$NAMESPACE" 2>/dev/null || true
        fi
    fi

    # The operator ("manager") takes ownership of spec.rules on the ingress,
    # which conflicts with Helm's apply. Instead of deleting the ingress (which
    # forces the ALB controller to provision a new ALB with a new DNS hostname),
    # use server-side apply to let Helm reclaim field ownership non-destructively.
    if kubectl get ingress langsmith-ingress -n "$NAMESPACE" &>/dev/null; then
        local ingress_managers
        ingress_managers=$(kubectl get ingress langsmith-ingress -n "$NAMESPACE" \
            -o jsonpath='{.metadata.managedFields[*].manager}' 2>/dev/null || echo "")
        if echo "$ingress_managers" | grep -qw "manager"; then
            log INFO "Operator owns langsmith-ingress — clearing field ownership to avoid conflict..."
            kubectl get ingress langsmith-ingress -n "$NAMESPACE" -o json \
                | python3 -c "
import sys, json
obj = json.load(sys.stdin)
obj['metadata']['managedFields'] = [
    m for m in obj['metadata'].get('managedFields', [])
    if m.get('manager') != 'manager'
]
json.dump(obj, sys.stdout)" \
                | kubectl apply -f - 2>/dev/null || true
        fi
    fi

    # fix_fleet_browser_access patches the frontend's public Fleet URLs via
    # `kubectl set env` (field manager "kubectl-set"). On a re-run, Helm's apply
    # conflicts with that ownership. Clear it non-destructively so Helm reclaims
    # the env fields; fix_fleet_browser_access re-applies the localhost:port URLs
    # afterward.
    if kubectl get deployment langsmith-frontend -n "$NAMESPACE" &>/dev/null; then
        local frontend_managers
        frontend_managers=$(kubectl get deployment langsmith-frontend -n "$NAMESPACE" \
            -o jsonpath='{.metadata.managedFields[*].manager}' 2>/dev/null || echo "")
        if echo "$frontend_managers" | grep -qw "kubectl-set"; then
            log INFO "Clearing kubectl-set field ownership on langsmith-frontend to avoid conflict..."
            kubectl get deployment langsmith-frontend -n "$NAMESPACE" -o json \
                | python3 -c "
import sys, json
obj = json.load(sys.stdin)
obj['metadata']['managedFields'] = [
    m for m in obj['metadata'].get('managedFields', [])
    if m.get('manager') != 'kubectl-set'
]
json.dump(obj, sys.stdout)" \
                | kubectl apply -f - 2>/dev/null || true
        fi
    fi

    log INFO "Executing: ${helm_cmd}"

    # Run helm in the background; redirect output to temp log
    eval "$helm_cmd" > "$helm_log" 2>&1 &
    local helm_pid=$!

    log INFO "Helm running (PID ${helm_pid}) — pod status updates every 15s..."

    # Kill helm and abort if unhealthy pods (CrashLoopBackOff/Error/OOMKilled) don't
    # decrease for this many consecutive checks (~180s at 15s interval).
    # Needs headroom for cold starts where images haven't been pulled yet
    # (e.g. Postgres alone can take >3min to pull + bind PVC).
    local stuck_threshold=12
    local stuck_count=0
    local last_bad=0
    # Consider deployment done once all pods are Running for this many consecutive checks.
    local stable_threshold=2
    local stable_count=0
    local last_summary=""

    while kill -0 "$helm_pid" 2>/dev/null; do
        sleep 15
        kill -0 "$helm_pid" 2>/dev/null || break  # may have exited during sleep

        local pod_output
        pod_output=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null) || pod_output=""

        # Change-detection key: sorted status counts
        local summary
        summary=$(printf '%s' "$pod_output" | awk '{print $3}' | sort | uniq -c | tr '\n' '|') || summary=""

        # Count pods by status. Operator-managed pods (smith-*, lg-*) are excluded
        # from the "bad" count because the operator continuously reconciles them and
        # old ReplicaSet pods can linger in Error during rollouts while new pods are
        # already Running.
        local total=0 running=0 completed=0 pending=0 bad=0 other=0
        while IFS= read -r pod_line; do
            [ -z "$pod_line" ] && continue
            (( total++ )) || true
            local pname pstatus
            pname=$(printf '%s' "$pod_line" | awk '{print $1}')
            pstatus=$(printf '%s' "$pod_line" | awk '{print $3}')
            case "$pstatus" in
                Running)                    (( running++   )) || true ;;
                Completed)                  (( completed++ )) || true ;;
                Pending|Init:*)             (( pending++   )) || true ;;
                CrashLoopBackOff|Error|\
                OOMKilled|ImagePullBackOff|\
                ErrImagePull)
                    if [[ "$pname" =~ ^(smith-|lg-|clio-) ]]; then
                        (( other++ )) || true
                    else
                        (( bad++ )) || true
                    fi
                    ;;
                *)                          (( other++     )) || true ;;
            esac
        done <<< "$pod_output"

        # Stuck detection: kill helm if bad-pod count hasn't improved
        if (( bad > 0 )); then
            if (( bad >= last_bad )); then
                (( stuck_count++ )) || true
            else
                stuck_count=0
            fi
            last_bad=$bad

            if (( stuck_count >= stuck_threshold )); then
                log ERROR "Deployment stuck: ${bad} pod(s) have been in a failed state for $((stuck_threshold * 15))s with no improvement."
                log ERROR "Killing helm (PID ${helm_pid}) and aborting."
                kill "$helm_pid" 2>/dev/null || true
                cat "$helm_log"
                rm -f "$helm_log"
                return 1
            fi
        else
            stuck_count=0
            last_bad=0
        fi

        # Only reprint when something changed
        [ "$summary" = "$last_summary" ] && continue
        last_summary="$summary"

        # Stability check: all pods Running with none in bad/pending/other states
        if (( total > 0 && running == total && bad == 0 && pending == 0 && other == 0 )); then
            (( stable_count++ )) || true
            if (( stable_count >= stable_threshold )); then
                log SUCCESS "All ${total} pods Running — deployment is stable. Proceeding."
                kill "$helm_pid" 2>/dev/null || true
                cat "$helm_log"
                rm -f "$helm_log"
                return 0
            fi
        else
            stable_count=0
        fi

        local status_line="${running}/${total} Running"
        (( completed > 0 )) && status_line+=", ${completed} Completed" || true
        (( pending   > 0 )) && status_line+=", ${pending} Pending/Init" || true
        (( bad       > 0 )) && status_line+=", ${bad} Failed [${stuck_count}/${stuck_threshold} checks]" || true
        (( other     > 0 )) && status_line+=", ${other} Other" || true
        log INFO "Pods: ${status_line}"

        # Surface non-Running/non-Completed pods with truncated names
        if (( bad > 0 || pending > 0 || other > 0 )); then
            while IFS= read -r pod_line; do
                [ -z "$pod_line" ] && continue
                local pname pstatus
                pname=$(printf '%s' "$pod_line" | awk '{print $1}')
                pstatus=$(printf '%s' "$pod_line" | awk '{print $3}')
                case "$pstatus" in Running|Completed) continue ;; esac
                [ ${#pname} -gt 45 ] && pname="${pname:0:42}..."
                log WARNING "  $(printf '%-45s %s' "$pname" "$pstatus")"
            done <<< "$pod_output"
        fi
    done

    # Capture helm exit code without letting set -e fire before we show output
    local exit_code=0
    wait "$helm_pid" || exit_code=$?
    cat "$helm_log"
    rm -f "$helm_log"

    return "$exit_code"
}

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

    # Generate Fernet-compatible encryption key for Fleet
    # Fernet key = URL-safe base64 encoding of 32 random bytes
    if [ -z "$fleetEncryptionKey" ]; then
        fleetEncryptionKey=$(openssl rand -base64 32 | tr '+/' '-_')
    fi

    # Generate Fernet-compatible encryption key for Insights
    if [ -z "$insightsEncryptionKey" ]; then
        insightsEncryptionKey=$(openssl rand -base64 32 | tr '+/' '-_')
    fi

    # Generate Fernet-compatible encryption key for Polly
    if [ -z "$pollyEncryptionKey" ]; then
        pollyEncryptionKey=$(openssl rand -base64 32 | tr '+/' '-_')
    fi

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

    # Also try to preserve Fleet / Insights / Polly encryption keys if they exist.
    # encryptionKey appears under the top-level fleet/insights/polly blocks; grab each.
    local existing_ab_key existing_insights_key existing_polly_key
    existing_ab_key=$(grep --color=never -A5 'fleet:' "$LS_CONFIG_YAML" 2>/dev/null | grep --color=never 'encryptionKey:' | $SED_CMD 's/.*encryptionKey:\s*"\?\([^"]*\)"\?.*/\1/' | head -1)
    existing_insights_key=$(grep --color=never -A5 'insights:' "$LS_CONFIG_YAML" 2>/dev/null | grep --color=never 'encryptionKey:' | $SED_CMD 's/.*encryptionKey:\s*"\?\([^"]*\)"\?.*/\1/' | head -1)
    existing_polly_key=$(grep --color=never -A5 'polly:' "$LS_CONFIG_YAML" 2>/dev/null | grep --color=never 'encryptionKey:' | $SED_CMD 's/.*encryptionKey:\s*"\?\([^"]*\)"\?.*/\1/' | head -1)

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

        # Preserve Fleet encryption key if found
        if [ -n "$existing_ab_key" ]; then
            fleetEncryptionKey="$existing_ab_key"
            log INFO "Preserved existing Fleet encryption key"
        fi

        # Preserve Insights encryption key if found
        if [ -n "$existing_insights_key" ]; then
            insightsEncryptionKey="$existing_insights_key"
            log INFO "Preserved existing Insights encryption key"
        fi

        # Preserve Polly encryption key if found
        if [ -n "$existing_polly_key" ]; then
            pollyEncryptionKey="$existing_polly_key"
            log INFO "Preserved existing Polly encryption key"
        fi

        log SUCCESS "Loaded existing secrets from ${LS_CONFIG_YAML}"
        return 0
    fi
    
    log WARNING "Existing config missing some secrets, will generate new ones"
    return 1
}

##############################################################################
# Function: setup_local_tls
# Description: Generates a self-signed cert for the LangSmith host and stores it as
#              a k8s TLS secret (langsmith-tls). LangSmith SSO requires HTTPS (§5.1).
#              On EKS this is replaced by real DNS + ACM — no logic change to callers.
# Arguments:  $1 - bare hostname (no scheme), e.g. langsmith.192-168-49-2.nip.io
##############################################################################
setup_local_tls() {
    local host="$1"

    if [ -z "$host" ]; then
        log WARNING "setup_local_tls called with empty host — skipping TLS secret"
        return 1
    fi

    log INFO "Generating self-signed TLS cert for ${host}..."
    local certdir
    certdir=$(mktemp -d)

    # SAN covers the ingress host plus localhost (port-forward access).
    if ! openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${certdir}/tls.key" -out "${certdir}/tls.crt" \
        -days 365 -subj "/CN=${host}" \
        -addext "subjectAltName=DNS:${host},DNS:localhost" 2>/dev/null; then
        log ERROR "Failed to generate self-signed certificate"
        rm -rf "$certdir"
        return 1
    fi

    log INFO "Creating/updating TLS secret langsmith-tls in namespace ${NAMESPACE}..."
    kubectl create secret tls langsmith-tls \
        --cert="${certdir}/tls.crt" --key="${certdir}/tls.key" \
        -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    rm -rf "$certdir"
    log SUCCESS "TLS secret langsmith-tls ready"
}

##############################################################################
# Function: setup_oauth_ca_trust
# Description: Builds a CA bundle (public CAs + the Keycloak server cert) and stores
#              it in a secret the platform-backend trusts via config.customCa (§5.1).
#              Without this, the OIDC client rejects Keycloak's self-signed cert
#              ("x509: certificate signed by unknown authority") and panics.
#              Public CAs are kept in the bundle so beacon/playground TLS still works.
#              No-op unless the issuer is https. Returns 0 on success.
##############################################################################
setup_oauth_ca_trust() {
    case "${KEYCLOAK_ISSUER_URL:-}" in
        https://*) ;;
        *) log INFO "OIDC issuer is not https — skipping custom CA trust"; return 0 ;;
    esac

    # Parse host:port from the issuer URL.
    local hostport host port
    hostport="${KEYCLOAK_ISSUER_URL#https://}"
    hostport="${hostport%%/*}"
    host="${hostport%%:*}"
    if [ "$hostport" = "$host" ]; then port=443; else port="${hostport##*:}"; fi

    local workdir
    workdir=$(mktemp -d)

    # Fetch the cert Keycloak actually serves. Connect to localhost (Docker publishes
    # the port there) but send the real SNI so we get the right leaf cert.
    log INFO "Fetching Keycloak server cert (${host}:${port}) for OIDC CA trust..."
    if ! openssl s_client -connect "127.0.0.1:${port}" -servername "$host" </dev/null 2>/dev/null \
        | openssl x509 -out "${workdir}/kc.crt" 2>/dev/null; then
        log WARNING "Could not fetch Keycloak cert from 127.0.0.1:${port}; OIDC TLS verification may fail"
        rm -rf "$workdir"
        return 1
    fi

    # Append the Keycloak cert to a public CA bundle so outbound TLS (beacon, etc.)
    # keeps working alongside trusting Keycloak.
    local pubca=""
    local c
    for c in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
        [ -f "$c" ] && { pubca="$c"; break; }
    done
    if [ -n "$pubca" ]; then
        cat "$pubca" "${workdir}/kc.crt" > "${workdir}/ca-bundle.crt"
    else
        log WARNING "No public CA bundle found on host; trusting Keycloak cert only (beacon TLS may fail)"
        cp "${workdir}/kc.crt" "${workdir}/ca-bundle.crt"
    fi

    log INFO "Creating/updating OIDC CA trust secret langsmith-oauth-ca in namespace ${NAMESPACE}..."
    # Use delete+create (not apply): the full CA bundle exceeds kubectl apply's
    # 256KB last-applied-configuration annotation limit, though it's well under the
    # 1MB secret data limit.
    kubectl delete secret langsmith-oauth-ca -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
    kubectl create secret generic langsmith-oauth-ca \
        --from-file=ca.crt="${workdir}/ca-bundle.crt" \
        -n "$NAMESPACE"

    rm -rf "$workdir"
    log SUCCESS "OIDC CA trust secret langsmith-oauth-ca ready"
}

##############################################################################
# Function: resolve_oauth_host
# Description: Resolves the bare LangSmith host (no scheme) used for OAuth redirect
#              URIs + the TLS cert. Used by install paths that don't otherwise
#              resolve an ingress hostname (e.g. plain -l). Honors LANGSMITH_HOSTNAME.
# Returns: bare host via stdout
##############################################################################
resolve_oauth_host() {
    if [ -n "${LANGSMITH_HOSTNAME:-}" ]; then
        echo "$LANGSMITH_HOSTNAME"
        return
    fi
    if is_minikube_cluster; then
        local ip
        ip=$(minikube ip 2>/dev/null || echo "")
        if [ -n "$ip" ]; then
            echo "${ip}.nip.io"
            return
        fi
        echo "localhost"
        return
    fi
    local h
    h=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    [ -z "$h" ] && h=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$h" ]; then
        echo "$h"
        return
    fi
    echo "localhost"
}

##############################################################################
# Function: apply_oauth_hostname_tls
# Description: Applies the OAuth-required hostname + TLS to ls_config.yaml, so it
#              works for ANY install flavor (-l, -ld, fleet/insights/polly) — OAuth
#              is orthogonal to the feature flags. Injects config.hostname with the
#              https scheme, flips config.deployment.tlsEnabled, adds ingress.tls,
#              and provisions the self-signed cert + secret. Idempotent within a run
#              (ls_config is rebuilt fresh from config.yaml each install).
# Arguments:  $1 - bare hostname (no scheme)
##############################################################################
apply_oauth_hostname_tls() {
    local host="$1"
    log INFO "Applying OAuth hostname + TLS (host: ${host})..."

    # config.hostname with https scheme (§5.1). Replace if present, else insert.
    if grep -qE '^  hostname:' "$LS_CONFIG_YAML"; then
        $SED_CMD -i.bak "s|^  hostname:.*|  hostname: \"https://${host}\"|" "$LS_CONFIG_YAML"
        rm -f "${LS_CONFIG_YAML}.bak"
    else
        local hi
        hi=$(mktemp)
        echo "  hostname: \"https://${host}\"" > "$hi"
        $SED_CMD -i.bak "/^config:/r $hi" "$LS_CONFIG_YAML"
        rm -f "$hi" "${LS_CONFIG_YAML}.bak"
    fi

    # Flip config.deployment.tlsEnabled false -> true (scoped to the deployment block).
    $SED_CMD -i.bak '/^  deployment:$/,/^[^ ]/{ s/tlsEnabled: false/tlsEnabled: true/ }' "$LS_CONFIG_YAML"
    rm -f "${LS_CONFIG_YAML}.bak"

    # Add ingress.tls referencing the secret created below.
    local ti
    ti=$(mktemp)
    cat > "$ti" << EOF
  tls:
    - secretName: langsmith-tls
      hosts:
        - "${host}"
EOF
    $SED_CMD -i.bak "/^ingress:/r $ti" "$LS_CONFIG_YAML"
    rm -f "$ti" "${LS_CONFIG_YAML}.bak"

    setup_local_tls "$host"

    # Trust the Keycloak (self-signed) cert so the OIDC client can fetch the
    # discovery doc / JWKS without an x509 verification panic (§5.1).
    setup_oauth_ca_trust
}

##############################################################################
# Function: inject_oauth_config
# Description: Swaps the basicAuth block in ls_config.yaml for a Keycloak oauth
#              block. OAuth and basic auth cannot coexist in LangSmith, so the
#              basicAuth block is removed entirely. Only called when AUTH_MODE=keycloak.
##############################################################################
inject_oauth_config() {
    log INFO "Configuring Keycloak OAuth (replacing basic auth)..."

    # Remove the basicAuth block (config: > basicAuth: ... jwtSecret:). The secret
    # sed replacements in create_langsmith_config become harmless no-ops once it's gone.
    $SED_CMD -i.bak '/^  basicAuth:/,/^    jwtSecret:/d' "$LS_CONFIG_YAML"
    rm -f "${LS_CONFIG_YAML}.bak"

    # Determine OAuth scopes. groups-sync needs the group claim in the token.
    local scopes="email,profile,openid"
    [ -n "${OAUTH_SCOPES:-}" ] && scopes="$OAUTH_SCOPES"
    if [ "$PROVISIONING_MODE" = "groups-sync" ] && [[ "$scopes" != *groups* ]]; then
        scopes="${scopes},groups"
    fi

    # Insert the oauth block after the authType line (same temp-file 'r' idiom used
    # elsewhere for hostname / langgraphPlatform injection). Also re-add
    # initialOrgAdminEmail at config level: the base config.yaml nests it under the
    # basicAuth block we just deleted, but OAuth bootstrap reads config.initialOrgAdminEmail
    # (INITIAL_ORG_ADMIN_EMAIL) — without it the auth-bootstrap job fails.
    local temp_insert
    temp_insert=$(mktemp)
    cat > "$temp_insert" << EOF
  initialOrgAdminEmail: "${initialOrgAdminEmail}"
  oauth:
    enabled: true
    oauthClientId: "${OAUTH_CLIENT_ID}"
    oauthClientSecret: "${OAUTH_CLIENT_SECRET}"
    oauthIssuerUrl: "${KEYCLOAK_ISSUER_URL}"
    oauthScopes: "${scopes}"
EOF
    $SED_CMD -i.bak "/authType:/r $temp_insert" "$LS_CONFIG_YAML"
    rm -f "$temp_insert" "${LS_CONFIG_YAML}.bak"

    log SUCCESS "OAuth block injected (issuer: ${KEYCLOAK_ISSUER_URL}, scopes: ${scopes})"
}

##############################################################################
# Function: oauth_helm_set_flags
# Description: Echoes the helm --set flags for OAuth session/JIT env vars, to be
#              appended to the helm upgrade command. Empty unless AUTH_MODE=keycloak.
#              These go via --set (not YAML injection) to avoid fragile anchor edits
#              into platformBackend.deployment / commonEnv.
##############################################################################
oauth_helm_set_flags() {
    [ "$AUTH_MODE" != "keycloak" ] && return 0

    local flags=""
    # Session controls + IdP-initiated logout (Phase 1).
    flags+=" --set platformBackend.deployment.extraEnv[0].name=OAUTH_SESSION_MAX_SEC"
    flags+=" --set-string platformBackend.deployment.extraEnv[0].value=86400"
    flags+=" --set platformBackend.deployment.extraEnv[1].name=OAUTH_IDP_LOGOUT_ENABLED"
    flags+=" --set-string platformBackend.deployment.extraEnv[1].value=true"

    local idx=2
    # Override which OIDC claim maps to LangSmith's sub when it differs from the
    # SCIM externalId (§5.2). Only set when provided in .env.
    if [ -n "${ISSUER_SUB_CLAIM_OVERRIDES:-}" ]; then
        flags+=" --set platformBackend.deployment.extraEnv[${idx}].name=ISSUER_SUB_CLAIM_OVERRIDES"
        flags+=" --set-string platformBackend.deployment.extraEnv[${idx}].value=${ISSUER_SUB_CLAIM_OVERRIDES}"
        idx=$((idx + 1))
    fi

    # JIT provisioning conflicts with both groups-sync and SCIM — disable it (§6/§8).
    # commonEnv is a list of {name,value} in the chart (defaults to []), so set by index.
    if [ "$PROVISIONING_MODE" != "none" ]; then
        flags+=" --set commonEnv[0].name=SELF_HOSTED_JIT_PROVISIONING_ENABLED"
        flags+=" --set-string commonEnv[0].value=false"
    fi

    # Trust the Keycloak self-signed cert (bundle created by setup_oauth_ca_trust) so
    # the OIDC discovery/JWKS fetch passes TLS verification (§5.1). https issuer only.
    case "${KEYCLOAK_ISSUER_URL:-}" in
        https://*)
            flags+=" --set config.customCa.secretName=langsmith-oauth-ca"
            flags+=" --set config.customCa.secretKey=ca.crt"
            ;;
    esac

    echo "$flags"
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

    # Ensure Fleet encryption key exists (may not be in older configs)
    if [ -z "$fleetEncryptionKey" ]; then
        fleetEncryptionKey=$(openssl rand -base64 32 | tr '+/' '-_')
        log INFO "Generated new Fleet encryption key"
    fi

    # Ensure Insights encryption key exists (may not be in older configs)
    if [ -z "$insightsEncryptionKey" ]; then
        insightsEncryptionKey=$(openssl rand -base64 32 | tr '+/' '-_')
        log INFO "Generated new Insights encryption key"
    fi

    # Ensure Polly encryption key exists (may not be in older configs)
    if [ -z "$pollyEncryptionKey" ]; then
        pollyEncryptionKey=$(openssl rand -base64 32 | tr '+/' '-_')
        log INFO "Generated new Polly encryption key"
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

    # Swap basic auth for Keycloak OAuth when requested.
    if [ "$AUTH_MODE" = "keycloak" ]; then
        inject_oauth_config
    fi

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

    # OAuth is orthogonal to the install flavor: apply hostname + TLS here too so
    # plain -l (no deployment) gets a working HTTPS OAuth setup.
    if [ "$AUTH_MODE" = "keycloak" ]; then
        local oauth_host
        oauth_host=$(resolve_oauth_host)
        apply_oauth_hostname_tls "$oauth_host"
    fi

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
    
    # On chart 0.15.x the agent-feature products (fleet/insights/polly) default to
    # enabled=true and then require an encryptionKey each. A plain LangSmith (-l)
    # install requests none of them, so disable them to satisfy chart validation.
    # (The -ld path does the same in install_langsmith_deployment.)
    [ "$INSTALL_AB" = true ]       || helm_cmd+=" --set fleet.enabled=false"
    [ "$INSTALL_INSIGHTS" = true ] || helm_cmd+=" --set insights.enabled=false"
    [ "$INSTALL_POLLY" = true ]    || helm_cmd+=" --set polly.enabled=false"

    # Add OAuth session/JIT env flags (no-op unless --auth keycloak)
    helm_cmd+="$(oauth_helm_set_flags)"

    # Add debug flag if enabled
    if [ "$DEBUG" = true ]; then
        helm_cmd+=" --debug"
        log INFO "Debug mode enabled"
    fi

    # Execute helm install with live pod progress
    helm_with_progress "$helm_cmd"

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
# Function: fix_fleet_browser_access
# Description: On Minikube the UI is reached via `kubectl port-forward` on a
#   non-80 port (default 8080), but the chart derives the frontend's public Fleet
#   URLs from config.hostname (= "localhost", no port) -> http://localhost/...
#   The browser then can't reach them (nothing on :80) and Fleet shows
#   "Unable to connect to LangGraph server. Failed to fetch". The chart rejects
#   duplicate env keys, so these can't be overridden via values/extraEnv; patch
#   the frontend deployment env in place, then restart. (VITE_AGENT_BUILDER_* are
#   the chart's own env keys, read by the frontend SPA.) helm_with_progress clears
#   the "kubectl-set" field ownership before any later helm upgrade so re-runs
#   don't hit server-side-apply conflicts.
##############################################################################
fix_fleet_browser_access() {
    local port="${1:-8080}"
    log INFO "Pointing Fleet frontend URLs at localhost:${port} for browser access..."
    if kubectl set env deployment/langsmith-frontend -n "$NAMESPACE" \
            VITE_AGENT_BUILDER_DEPLOYMENT_URL_PUBLIC="http://localhost:${port}/agents/fleet" \
            LANGGRAPH_API_URL_PUBLIC="http://localhost:${port}/agents/fleet" \
            VITE_AGENT_BUILDER_MCP_SERVER_URL="http://localhost:${port}/mcp" \
            VITE_AGENT_BUILDER_TRIGGERS_API_URL="http://localhost:${port}" 2>/dev/null; then
        log SUCCESS "Fleet frontend URLs patched for browser access"
        kubectl rollout status deployment/langsmith-frontend -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
    else
        log WARNING "Could not patch Fleet frontend URLs (frontend may not expose them on this chart version)"
    fi
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
        
        # Determine hostname for deployment (required by chart validation in v12+)
        # Priority: 1) User-specified LANGSMITH_HOSTNAME, 2) Existing ingress
        # Fallback: ALB -> placeholder + post-patch to remove host rule, nginx/minikube -> localhost
        local ingress_hostname=""
        
        # Priority 1: User-specified hostname from .env
        if [ -n "$LANGSMITH_HOSTNAME" ]; then
            ingress_hostname="$LANGSMITH_HOSTNAME"
            log INFO "Using user-specified hostname: ${ingress_hostname}"
        # Priority 2: Check existing ingress with short poll (gives ALB controller
        # time to settle after a previous Helm upgrade before we read the hostname).
        elif ! is_minikube_cluster; then
            log INFO "Checking for existing ingress hostname..."
            local alb_attempts=0
            local alb_max=6
            while [ $alb_attempts -lt $alb_max ]; do
                ingress_hostname=$(kubectl get ingress -n "$NAMESPACE" \
                    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
                if [ -z "$ingress_hostname" ]; then
                    ingress_hostname=$(kubectl get ingress -n "$NAMESPACE" \
                        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
                fi
                if [ -n "$ingress_hostname" ] && [ "$ingress_hostname" != "<pending>" ]; then
                    break
                fi
                alb_attempts=$((alb_attempts + 1))
                log INFO "Waiting for ingress hostname... (attempt ${alb_attempts}/${alb_max})"
                sleep 5
            done
            [ -n "$ingress_hostname" ] && log INFO "Found existing ingress hostname: ${ingress_hostname}"
            # Convert IP to nip.io if needed for nginx ingress
            if [ -n "$ingress_hostname" ] && [ "$ingress_hostname" != "<pending-ingress-hostname>" ] && [ "$INGRESS_TYPE" = "nginx" ]; then
                if [[ "$ingress_hostname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    log INFO "Converting IP address to nip.io DNS name for nginx ingress"
                    ingress_hostname="${ingress_hostname}.nip.io"
                fi
            fi
        fi
        
        # Priority 3: Fallback when no hostname is available
        local alb_patch_host=false
        if [ -z "$ingress_hostname" ] || [ "$ingress_hostname" = "<pending-ingress-hostname>" ]; then
            if [ "$INGRESS_TYPE" = "alb" ]; then
                # ALB rejects 'localhost' (no dots) as an invalid listener rule condition.
                # Phase 1: install basic LangSmith (no deployment features) to provision the ALB.
                # Phase 2: upgrade with the real ALB hostname and all features.
                log INFO "ALB cluster with no existing hostname — running two-phase deploy to provision ALB first..."
                local phase1_cmd="helm upgrade --install langsmith langchain/langsmith"
                phase1_cmd+=" --namespace \"${NAMESPACE}\""
                phase1_cmd+=" --values \"${LS_CONFIG_YAML}\""
                phase1_cmd+=" --wait=false --timeout 10m --hide-notes"
                phase1_cmd+=" --set operator.createCRDs=false"
                phase1_cmd+=" --set operator.watchNamespaces=${NAMESPACE}"
                phase1_cmd+=" --set frontend.service.type=ClusterIP"
                [ "$DEBUG" = true ] && phase1_cmd+=" --debug"
                if [ -n "$VERSION" ]; then phase1_cmd+=" --version ${VERSION}"; fi
                log INFO "Phase 1: installing base LangSmith to provision ALB..."
                helm_with_progress "$phase1_cmd"
                log INFO "Waiting for ALB hostname to be assigned (this may take 2-5 minutes)..."
                ingress_hostname=$(get_ingress_hostname)
                if [ -z "$ingress_hostname" ] || [ "$ingress_hostname" = "<pending-ingress-hostname>" ]; then
                    log ERROR "ALB hostname was not assigned after waiting. Set LANGSMITH_HOSTNAME in .env and re-run."
                    exit 1
                fi
                log SUCCESS "ALB hostname provisioned: ${ingress_hostname}"
                log INFO "Phase 2: upgrading with deployment features and real hostname..."
            else
                ingress_hostname="localhost"
                log INFO "Using default hostname: localhost (use port-forward to access)"
            fi
        fi
        
        # Enable deployment in the config (deployment block already exists in config.yaml
        # with enabled: false — flip it to true to avoid duplicate YAML keys).
        local features_enabled=()
        [ "$INSTALL_AB" = true ]       && features_enabled+=("fleet")
        [ "$INSTALL_INSIGHTS" = true ] && features_enabled+=("insights")
        [ "$INSTALL_POLLY" = true ]    && features_enabled+=("polly")
        log INFO "Enabling config.deployment, setting config.hostname${features_enabled:+, $(IFS=', '; echo "${features_enabled[*]}")} in LangSmith config"

        # Flip deployment.enabled false -> true (scoped to the line after 'deployment:')
        $SED_CMD -i.bak '/^  deployment:$/{n; s/enabled: false/enabled: true/}' "$LS_CONFIG_YAML"
        rm -f "${LS_CONFIG_YAML}.bak"

        # Inject hostname under the 'config:' block. For OAuth, the hostname must
        # carry the https:// scheme + TLS (§5.1) — shared helper, flavor-agnostic.
        # Basic auth keeps the scheme-less hostname.
        if [ "$AUTH_MODE" = "keycloak" ]; then
            apply_oauth_hostname_tls "$ingress_hostname"
        else
            local temp_insert
            temp_insert=$(mktemp)
            echo "  hostname: \"${ingress_hostname}\"" > "$temp_insert"
            $SED_CMD -i.bak "/^config:/r $temp_insert" "$LS_CONFIG_YAML"
            rm -f "$temp_insert" "${LS_CONFIG_YAML}.bak"
        fi

        # Append top-level fleet / insights / polly blocks (chart >= 0.15 model).
        # These are standalone Helm-managed Deployments — NOT the deprecated
        # config.agentBuilder bundled-bootstrap path. namePrefix is pinned so the
        # rendered resources are predictably named langsmith-<feature>-*.
        {
            if [ "$INSTALL_AB" = true ]; then
                echo ""
                echo "fleet:"
                echo "  enabled: true"
                echo "  namePrefix: \"fleet\""
                echo "  encryptionKey: \"${fleetEncryptionKey}\""
            fi
            if [ "$INSTALL_INSIGHTS" = true ]; then
                echo ""
                echo "insights:"
                echo "  enabled: true"
                echo "  namePrefix: \"insights\""
                echo "  encryptionKey: \"${insightsEncryptionKey}\""
            fi
            if [ "$INSTALL_POLLY" = true ]; then
                echo ""
                echo "polly:"
                echo "  enabled: true"
                echo "  namePrefix: \"polly\""
                echo "  encryptionKey: \"${pollyEncryptionKey}\""
            fi
        } >> "$LS_CONFIG_YAML"
        
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

        # Enable Fleet / Insights / Polly components if requested (chart v0.15+).
        # fleet.enabled / insights.enabled / polly.enabled + encryptionKey come from
        # the top-level blocks appended to the values file above. The tool/trigger
        # servers are separate top-level toggles, enabled here. These run as standard
        # Helm-managed Deployments — no backend.agentBootstrap, no LGP.
        if [ "$INSTALL_AB" = true ]; then
            helm_cmd+=" --set fleetToolServer.enabled=true"
            helm_cmd+=" --set fleetTriggerServer.enabled=true"
            # Self-signed TLS doesn't verify inside the cluster; disable for local dev.
            # The keycloak path REQUIRES TLS (OAuth over HTTPS, §5.1), so keep it on there.
            if is_minikube_cluster && [ "$AUTH_MODE" != "keycloak" ]; then
                helm_cmd+=" --set config.tlsEnabled=false"
                helm_cmd+=" --set config.deployment.ingressHealthCheckEnabled=false"
            fi
        fi

        # The chart defaults the agent-feature products (fleet/insights/polly) to
        # enabled=true and then requires an encryptionKey for each. Explicitly disable
        # any product that wasn't requested so validation doesn't demand a key for it.
        [ "$INSTALL_AB" = true ]       || helm_cmd+=" --set fleet.enabled=false"
        [ "$INSTALL_INSIGHTS" = true ] || helm_cmd+=" --set insights.enabled=false"
        [ "$INSTALL_POLLY" = true ]    || helm_cmd+=" --set polly.enabled=false"

        # Add OAuth session/JIT env flags (no-op unless --auth keycloak)
        helm_cmd+="$(oauth_helm_set_flags)"

        if [ "$DEBUG" = true ]; then
            helm_cmd+=" --debug"
        fi

        # Execute helm upgrade with live pod progress
        helm_with_progress "$helm_cmd"

        # Safety net: verify the ingress host rule matches the actual ALB DNS.
        # With the ingress preserved across upgrades (no deletion), the ALB DNS
        # should be stable. This check catches edge cases where a mismatch
        # persists from a previous deployment.
        if [ "$INGRESS_TYPE" = "alb" ]; then
            local actual_alb_host spec_host
            actual_alb_host=$(kubectl get ingress langsmith-ingress -n "$NAMESPACE" \
                -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            spec_host=$(kubectl get ingress langsmith-ingress -n "$NAMESPACE" \
                -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
            if [ -n "$actual_alb_host" ] && [ -n "$spec_host" ] && [ "$actual_alb_host" != "$spec_host" ]; then
                log WARNING "ALB hostname mismatch: spec.rules.host=${spec_host} but actual ALB=${actual_alb_host}"
                log INFO "Updating config hostname and re-running Helm upgrade to fix ROOT_DOMAIN..."
                $SED_CMD -i.bak "s|${spec_host}|${actual_alb_host}|g" "$LS_CONFIG_YAML"
                rm -f "${LS_CONFIG_YAML}.bak"
                helm_with_progress "$helm_cmd"
                log SUCCESS "Ingress host rule now matches actual ALB hostname"
            fi
        fi

        if [ "$INSTALL_AB" = true ]; then
            log SUCCESS "LangSmith upgraded with deployment and Fleet enabled"
            # Fleet/Insights/Polly are standard Helm-managed Deployments; the
            # `helm upgrade --wait` above already blocked until they were Ready.
            # Verify the key Fleet deployments rolled out (names are stable because
            # fleet.namePrefix is pinned and the tool/trigger servers use fixed names).
            log INFO "Verifying Fleet deployments are ready..."
            local fleet_deps=(langsmith-fleet-tool-server langsmith-fleet-trigger-server langsmith-fleet-api-server)
            [ "$INSTALL_INSIGHTS" = true ] && fleet_deps+=(langsmith-insights-api-server)
            [ "$INSTALL_POLLY" = true ]    && fleet_deps+=(langsmith-polly-api-server)
            for dep in "${fleet_deps[@]}"; do
                if kubectl rollout status "deployment/${dep}" -n "$NAMESPACE" --timeout=180s 2>/dev/null; then
                    log SUCCESS "${dep} ready"
                else
                    log WARNING "${dep} not ready yet — check 'kubectl get pods -n ${NAMESPACE}'"
                fi
            done
            # The chart bakes http://localhost (no port) into the frontend's public
            # Fleet URLs; on Minikube the UI is served via port-forward on :8080, so
            # rewrite them to the port-forward port or Fleet can't reach its servers.
            if is_minikube_cluster; then
                fix_fleet_browser_access 8080
            fi
            log INFO "Access the UI with: kubectl port-forward -n ${NAMESPACE} svc/langsmith-frontend 8080:80"
        else
            log SUCCESS "LangSmith upgraded with deployment feature enabled"
        fi
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
##############################################################################
# Function: run_populate
# Description: Runs scripts/populate.sh to seed LangSmith with synthetic data
#              (traces, feedback, datasets, annotation queues, prompts)
# Requires:    endpoint (resolved), initialOrgAdminEmail, initialOrgAdminPassword
##############################################################################
run_populate() {
    local endpoint_url="$1"
    local populate_script="${SCRIPT_DIR}/scripts/populate.sh"

    if [ ! -f "$populate_script" ]; then
        log ERROR "Populate script not found at ${populate_script}"
        return 1
    fi
    if [ ! -x "$populate_script" ]; then
        chmod +x "$populate_script"
    fi

    log INFO "Running populate script against ${endpoint_url} ..."
    if "$populate_script" "$endpoint_url" "$initialOrgAdminEmail" "$initialOrgAdminPassword"; then
        log SUCCESS "Populate script completed successfully"
        return 0
    else
        log WARNING "Populate script exited with errors (non-fatal)"
        return 1
    fi
}

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
    
    # OAuth/Keycloak serves over HTTPS; basic auth over HTTP.
    local scheme="http"
    [ "$AUTH_MODE" = "keycloak" ] && scheme="https"

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
        echo -e "Endpoint:  ${GREEN}${scheme}://${endpoint}${NC}"
    fi
    if [ "$AUTH_MODE" = "keycloak" ]; then
        echo -e "Login:     ${GREEN}Sign in via Keycloak (OAuth/OIDC)${NC}"
        echo -e "Keycloak:  ${GREEN}${KEYCLOAK_ISSUER_URL}${NC}"
        echo -e "Provision: ${GREEN}${PROVISIONING_MODE}${NC}"
        echo ""
        echo -e "${YELLOW}⚠️  Self-signed TLS: your browser will warn on first visit (expected for local).${NC}"
        case "$PROVISIONING_MODE" in
            groups-sync)
                echo -e "${YELLOW}    Next: enable SSO Groups Sync (groups claim = 'groups'):${NC}"
                echo -e "    ${GREEN}${SCRIPT_DIR}/scripts/configure-groups-sync.sh ${scheme}://${endpoint} <org-admin-PAT>${NC}"
                ;;
            scim)
                echo -e "${YELLOW}    Next: generate a SCIM token and load the outbound-SCIM extension in Keycloak:${NC}"
                echo -e "    ${GREEN}${SCRIPT_DIR}/scripts/scim-token.sh ${scheme}://${endpoint} <org-admin-PAT>${NC}"
                ;;
        esac
    else
        echo -e "Email:     ${GREEN}${initialOrgAdminEmail}${NC}"
        echo -e "Password:  ${GREEN}${initialOrgAdminPassword}${NC}"
        echo ""
        echo -e "${YELLOW}⚠️  Important: Save these credentials securely!${NC}"
    fi
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
os.environ["LANGSMITH_ENDPOINT"] = "${scheme}://${endpoint}/api/v1"
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

    # Export resolved endpoint for use by populate and other post-install steps
    if [ "$endpoint_pending" != true ] && [ -n "$endpoint" ]; then
        RESOLVED_ENDPOINT="${scheme}://${endpoint}"
    fi
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

    # Delete LGP custom resources first — the operator creates pods (api, queue,
    # redis, postgres) that hold PVCs open. Must remove these before PVC deletion.
    if kubectl get crd lgps.apps.langchain.ai &>/dev/null; then
        log INFO "Deleting LGP resources in ${targetNs}..."
        kubectl delete lgp --all -n "$targetNs" --timeout=60s 2>/dev/null || true
    fi

    # Force-delete any remaining pods (LGP pods may linger after CRD deletion)
    local remaining_pods
    remaining_pods=$(kubectl get pods -n "$targetNs" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$remaining_pods" -gt 0 ] 2>/dev/null; then
        log INFO "Force-deleting ${remaining_pods} remaining pod(s) in ${targetNs}..."
        kubectl delete pods --all -n "$targetNs" --force --grace-period=0 2>/dev/null || true
    fi

    # List PVCs
    log INFO "Listing Persistent Volume Claims in ${targetNs}..."
    kubectl get pvc -n "$targetNs" 2>/dev/null || log INFO "No PVCs found in ${targetNs}"

    # Delete ALL PVCs in the namespace (not just the known names — LGP creates its own)
    log INFO "Deleting all Persistent Volume Claims in ${targetNs}..."
    kubectl delete pvc --all -n "$targetNs" --ignore-not-found 2>/dev/null || true

    # Clean up Released PVs that were bound to this namespace.
    # On Minikube, hostPath PVs retain data on disk after PVC deletion. If a new
    # install creates PVCs with the same name, Minikube may reuse the old hostPath
    # directory, causing data from a previous install to leak into the new one
    # (e.g., Fernet-encrypted secrets with a different key → InvalidToken errors).
    log INFO "Cleaning up Released PersistentVolumes from ${targetNs}..."
    local released_pvs
    released_pvs=$(kubectl get pv -o json 2>/dev/null | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
for pv in data.get('items', []):
    ref = pv.get('spec', {}).get('claimRef', {})
    status = pv.get('status', {}).get('phase', '')
    if ref.get('namespace') == '${targetNs}' and status in ('Released', 'Failed'):
        print(pv['metadata']['name'])
" 2>/dev/null || true)
    if [ -n "$released_pvs" ]; then
        echo "$released_pvs" | while IFS= read -r pv_name; do
            [ -n "$pv_name" ] && kubectl delete pv "$pv_name" --ignore-not-found 2>/dev/null || true
        done
        log SUCCESS "Cleaned up Released PVs for ${targetNs}"
    fi

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

        # Validate Keycloak OAuth prerequisites (no-op unless --auth keycloak)
        validate_auth_config

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

                # Populate with synthetic test data if -s was specified
                if [ "$POPULATE" = true ]; then
                    if [ -n "$RESOLVED_ENDPOINT" ]; then
                        run_populate "$RESOLVED_ENDPOINT" || true
                    else
                        log WARNING "Cannot populate: endpoint not yet resolved. Run manually:"
                        log WARNING "  ${SCRIPT_DIR}/scripts/populate.sh <endpoint> '${initialOrgAdminEmail}' '<password>'"
                    fi
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

