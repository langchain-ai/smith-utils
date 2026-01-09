#!/bin/bash

##############################################################################
# LangSmith and LangSmith Deployment Installation Script for Kubernetes Clusters
# 
# Description: Automates the installation and management of LangSmith and 
#              LangSmith Deployment on any Kubernetes cluster (cross-platform)
# 
# Usage: ./smith-fly.sh <up|down> <-l|-ld> [-v VERSION]
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
LD_CONFIG_YAML="${CONFIG_DIR}/ld_config.yaml"

ACTION=""
INSTALL_LS=false
INSTALL_LD=false
VERSION=""
DEBUG=false
NAMESPACE=""
INGRESS_TYPE="alb"  # Default to ALB, can be 'alb' or 'nginx'
IS_V12_PLUS=true  # Default to true (latest version assumes v12+)
initialOrgAdminEmail=""
LicenseKey=""
apiKeySalt=""
jwtSecret=""
initialOrgAdminPassword=""

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
# Function: show_usage
# Description: Displays script usage information
##############################################################################
show_usage() {
    cat << EOF
Usage: $0 <up|down> [-l|-ld] [-v VERSION] [--debug]

Actions:
    up      Spin up/install LangSmith or LangSmith Deployment
    down    Delete both LangSmith and LangSmith Deployment from your installation
    status  Check installation status of LangSmith and LangSmith Deployment

Options (for 'up' action):
    -l      Install LangSmith
    -ld     Install LangSmith Deployment
    -v      Specify version (optional)
    -i      Ingress type: alb (default) or nginx
    --debug Enable Helm debug output (optional)

Examples:
    $0 up -l                     # Install LangSmith only (latest v12+ version, ALB ingress)
    $0 up -l -i nginx            # Install LangSmith with nginx ingress
    $0 up -l -v 0.12.3           # Install LangSmith v12+ with specific version
    $0 up -l -v 0.11.5           # Install LangSmith pre-v12 with legacy config format
    $0 up -l --debug             # Install LangSmith with debug output
    $0 up -ld                    # Install LangSmith Deployment (automatically installs LangSmith if not present)
    $0 up -ld -i nginx           # Install LangSmith Deployment with nginx ingress
    $0 up -ld -v 0.11.0          # Install LangSmith Deployment with pre-v12 config format
    $0 down                      # Remove both LangSmith and LangSmith Deployment
    $0 status                    # Check installation status of LangSmith and LangSmith Deployment

Notes:
    - At least one of -l or -ld must be specified with "up"
    - When installing LangSmith Deployment (-ld), LangSmith is automatically installed if not already present
    - The "down" action removes both LangSmith and LangSmith Deployment
    - Configuration is read from ${ENV_FILE}
    - Namespace is auto-generated from your local machine hostname
    - Version >= 0.12.0 uses new config format (config.deployment, config.hostname)
    - Version < 0.12.0 uses legacy config format (config.langgraphPlatform, langgraphPlatformLicenseKey)
    - Ingress type defaults to ALB (AWS). Use -i nginx for non-AWS Kubernetes clusters

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
    
    log SUCCESS "Configuration loaded successfully"
}

##############################################################################
# Function: setup_namespace
# Description: Creates namespace based on hostname
##############################################################################
setup_namespace() {
    log INFO "Setting up namespace..."
    
    # Generate namespace from hostname
    NAMESPACE=$(hostname | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    
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
# Function: create_langsmith_config
# Description: Creates LangSmith configuration file with substituted values
##############################################################################
create_langsmith_config() {
    log INFO "Creating LangSmith configuration file..."
    
    if [ ! -f "$CONFIG_YAML" ]; then
        log ERROR "Base configuration file not found: ${CONFIG_YAML}"
        exit 1
    fi
    
    # Copy base config to LangSmith config
    cp "$CONFIG_YAML" "$LS_CONFIG_YAML"
    
    # Generate secrets if not already generated
    if [ -z "$apiKeySalt" ] || [ -z "$jwtSecret" ] || [ -z "$initialOrgAdminPassword" ]; then
        generate_secrets
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
    
    # Set frontend service type to ClusterIP for nginx ingress
    # (nginx uses Ingress resources, not LoadBalancer services)
    if [ "$INGRESS_TYPE" = "nginx" ]; then
        helm_cmd+=" --set frontend.service.type=ClusterIP"
        log INFO "Set frontend.service.type=ClusterIP for nginx ingress"
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
    
    # Display connection information
    display_langsmith_info
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
        # Try hostname first (AWS ELB), then IP (GKE, AKS, on-prem)
        endpoint=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        
        if [ -z "$endpoint" ]; then
            endpoint=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
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
# Function: create_langsmith_deployment_config
# Description: Creates LangSmith Deployment configuration file
##############################################################################
create_langsmith_deployment_config() {
    log INFO "Creating LangSmith Deployment configuration file..."
    
    # Copy LangSmith config to reuse same secrets
    if [ ! -f "$LS_CONFIG_YAML" ]; then
        log ERROR "LangSmith configuration not found: ${LS_CONFIG_YAML}"
        exit 1
    fi
    
    cp "$LS_CONFIG_YAML" "$LD_CONFIG_YAML"
    
    # Escape special characters for sed
    escaped_license=$(printf '%s\n' "$LicenseKey" | sed 's/[\/&]/\\&/g')
    escaped_namespace=$(printf '%s\n' "$NAMESPACE" | sed 's/[\/&]/\\&/g')
    
    if [ "$IS_V12_PLUS" = true ]; then
        # v12+ configuration: use config.deployment instead of config.langgraphPlatform
        log INFO "Generating v12+ LangSmith Deployment configuration"
        
        # Get ingress hostname for config.hostname
        local ingress_hostname
        ingress_hostname=$(get_ingress_hostname)
        
        # Add deployment.enabled under config section
        if grep -q "^config:" "$LD_CONFIG_YAML"; then
            # Add deployment section under config using temp file (robust approach)
            local temp_insert=$(mktemp)
            cat > "$temp_insert" << EOF
  deployment:
    enabled: true
  hostname: "${ingress_hostname}"
EOF
            $SED_CMD -i.bak "/^config:/r $temp_insert" "$LD_CONFIG_YAML"
            rm -f "$temp_insert" "${LD_CONFIG_YAML}.bak"
        else
            # Add config section with deployment
            cat >> "$LD_CONFIG_YAML" << EOF

config:
  deployment:
    enabled: true
  hostname: "${ingress_hostname}"
EOF
        fi
        
        # Add operator section for v12+
        if ! grep -q "^operator:" "$LD_CONFIG_YAML"; then
            cat >> "$LD_CONFIG_YAML" << EOF

operator:
  createCRDs: false
  watchNamespaces: "${NAMESPACE}"
EOF
        fi
    else
        # Pre-v12 configuration: use config.langgraphPlatform
        log INFO "Generating pre-v12 LangSmith Deployment configuration"
        
        # Add LangSmith Deployment configuration under config section
        if ! grep -q "^config:" "$LD_CONFIG_YAML"; then
            # Add config section with langgraphPlatform
            cat >> "$LD_CONFIG_YAML" << EOF

config:
  langgraphPlatform:
    enabled: true
    langgraphPlatformLicenseKey: "${LicenseKey}"
EOF
        else
            # Config section exists, check if langgraphPlatform exists
            if ! grep -q "langgraphPlatform:" "$LD_CONFIG_YAML"; then
                # Add langgraphPlatform under config section using temp file
                local temp_insert=$(mktemp)
                cat > "$temp_insert" << EOF
  langgraphPlatform:
    enabled: true
    langgraphPlatformLicenseKey: "${LicenseKey}"
EOF
                $SED_CMD -i.bak "/^config:/r $temp_insert" "$LD_CONFIG_YAML"
                rm -f "$temp_insert" "${LD_CONFIG_YAML}.bak"
            else
                # Update existing langgraphPlatform section
                $SED_CMD -i.bak \
                    -e "/langgraphPlatform:/,/enabled:/ s/enabled:.*/enabled: true/" \
                    -e "/langgraphPlatform:/,/langgraphPlatformLicenseKey:/ s/langgraphPlatformLicenseKey:.*/langgraphPlatformLicenseKey: \"${escaped_license}\"/" \
                    "$LD_CONFIG_YAML"
                rm -f "${LD_CONFIG_YAML}.bak"
            fi
        fi
    fi
    
    log SUCCESS "LangSmith Deployment configuration file created: ${LD_CONFIG_YAML}"
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
# Arguments: $1 - release name (e.g., langsmith, langsmith-deployment)
# Returns: version and status via global variables
##############################################################################
get_helm_release_info() {
    local release_name="$1"
    local helm_output
    
    helm_output=$(helm list -n "$NAMESPACE" --filter "^${release_name}$" -o json 2>/dev/null)
    
    if [ -z "$helm_output" ] || [ "$helm_output" = "[]" ]; then
        echo "not_installed"
        return 1
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
# Description: Displays installation status of LangSmith and LangSmith Deployment
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
    
    if [ "$ls_info" = "not_installed" ]; then
        echo -e "  Status:   ${YELLOW}Not Installed${NC}"
    else
        local ls_status ls_chart ls_app
        ls_status=$(echo "$ls_info" | cut -d'|' -f1)
        ls_chart=$(echo "$ls_info" | cut -d'|' -f2)
        ls_app=$(echo "$ls_info" | cut -d'|' -f3)
        
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
    
    # Check LangSmith Deployment status
    echo -e "${BLUE}LangSmith Deployment:${NC}"
    local ld_info
    ld_info=$(get_helm_release_info "langsmith-deployment")
    
    if [ "$ld_info" = "not_installed" ]; then
        echo -e "  Status:   ${YELLOW}Not Installed${NC}"
    else
        local ld_status ld_chart ld_app
        ld_status=$(echo "$ld_info" | cut -d'|' -f1)
        ld_chart=$(echo "$ld_info" | cut -d'|' -f2)
        ld_app=$(echo "$ld_info" | cut -d'|' -f3)
        
        if [ "$ld_status" = "deployed" ]; then
            echo -e "  Status:   ${GREEN}Installed${NC}"
        else
            echo -e "  Status:   ${YELLOW}${ld_status}${NC}"
        fi
        echo -e "  Chart:    ${ld_chart}"
        [ -n "$ld_app" ] && echo -e "  Version:  ${ld_app}"
        
        # Get pod status
        local pod_status
        pod_status=$(get_pod_status_summary "app.kubernetes.io/instance=langsmith-deployment")
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
    
    # Check if LangSmith is installed
    if ! check_langsmith_installed; then
        log WARNING "LangSmith is not installed. Installing LangSmith first..."
        install_langsmith
    else
        log INFO "LangSmith is already installed"
    fi
    
    # Create LangSmith Deployment configuration
    create_langsmith_deployment_config
    
    # Build helm command (quote paths to handle spaces in directory names)
    local helm_cmd="helm upgrade --install langsmith-deployment langchain/langgraph-cloud"
    helm_cmd+=" --namespace \"${NAMESPACE}\""
    helm_cmd+=" --values \"${LD_CONFIG_YAML}\""
    helm_cmd+=" --wait --timeout 30m"
    
    # Add version if specified
    if [ -n "$VERSION" ]; then
        helm_cmd+=" --version ${VERSION}"
        log INFO "Installing LangSmith Deployment version: ${VERSION}"
    fi
    
    # Add debug flag if enabled
    if [ "$DEBUG" = true ]; then
        helm_cmd+=" --debug"
        log INFO "Debug mode enabled"
    fi
    
    log INFO "Executing: ${helm_cmd}"
    
    # Execute helm install
    eval "$helm_cmd"
    
    log SUCCESS "LangSmith Deployment installed successfully"
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
    
    while [ $attempt -lt $max_attempts ]; do
        # Try hostname first (AWS ELB), then IP (GKE, AKS, on-prem)
        endpoint=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        
        if [ -z "$endpoint" ]; then
            endpoint=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        fi
        
        if [ -n "$endpoint" ]; then
            break
        fi
        
        attempt=$((attempt + 1))
        log INFO "Waiting for ingress endpoint... (attempt ${attempt}/${max_attempts})"
        sleep 10
    done
    
    if [ -z "$endpoint" ]; then
        endpoint="<pending - run: kubectl get ingress -n ${NAMESPACE}>"
    fi
    
    echo ""
    echo "=========================================================================="
    echo -e "${GREEN}LangSmith Installation Complete!${NC}"
    echo "=========================================================================="
    echo ""
    echo -e "${BLUE}Connection Details:${NC}"
    echo "-------------------"
    echo -e "Namespace: ${GREEN}${NAMESPACE}${NC}"
    echo -e "Endpoint:  ${GREEN}http://${endpoint}${NC}"
    echo -e "Email:     ${GREEN}${initialOrgAdminEmail}${NC}"
    echo -e "Password:  ${GREEN}${initialOrgAdminPassword}${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Important: Save these credentials securely!${NC}"
    echo ""
    echo -e "${RED}⚠️  WARNING: Resource Usage Alert${NC}"
    echo -e "${RED}    Delete right after reproduction as amount of using resources per installation is high!${NC}"
    echo -e "${RED}    CPU: ~20 cores, Memory: ~50Gi${NC}"
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
    echo ""
    echo "" More details: https://docs.langchain.com/langsmith/self-host-usage
    echo ""
    echo "=========================================================================="
    echo ""
}

##############################################################################
# Function: uninstall_all
# Description: Uninstalls LangSmith and LangSmith Deployment
##############################################################################
uninstall_all() {
    log INFO "Starting uninstallation process for both LangSmith and LangSmith Deployment..."
    
    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log WARNING "Namespace ${NAMESPACE} does not exist. Nothing to uninstall."
        return 0
    fi
    
    # Uninstall LangSmith Deployment
    log INFO "Uninstalling LangSmith Deployment..."
    helm uninstall langsmith-deployment -n "$NAMESPACE" 2>/dev/null || log WARNING "LangSmith Deployment not found or already uninstalled"
    
    # Uninstall LangSmith
    log INFO "Uninstalling LangSmith..."
    helm uninstall langsmith -n "$NAMESPACE" 2>/dev/null || log WARNING "LangSmith not found or already uninstalled"
    
    # List PVCs
    log INFO "Listing Persistent Volume Claims..."
    kubectl get pvc -n "$NAMESPACE" 2>/dev/null || log INFO "No PVCs found"
    
    # Delete PVCs
    log INFO "Deleting Persistent Volume Claims..."
    kubectl delete pvc \
        data-langsmith-clickhouse-0 \
        data-langsmith-postgres-0 \
        data-langsmith-redis-0 \
        data-langsmith-deployment-postgres-0 \
        -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    
    # Delete namespace
    log INFO "Deleting namespace: ${NAMESPACE}"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    
    # Remove configuration files
    log INFO "Removing configuration files..."
    [ -f "$LS_CONFIG_YAML" ] && rm -f "$LS_CONFIG_YAML" && log INFO "Removed ${LS_CONFIG_YAML}"
    [ -f "$LD_CONFIG_YAML" ] && rm -f "$LD_CONFIG_YAML" && log INFO "Removed ${LD_CONFIG_YAML}"
    
    log SUCCESS "Uninstallation completed successfully"
}

##############################################################################
# Main execution
##############################################################################
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # For status action, only set namespace and show status (minimal output)
    if [ "$ACTION" = "status" ]; then
        # Generate namespace from hostname (silent)
        NAMESPACE=$(hostname | tr '[:upper:]' '[:lower:]' | tr '.' '-')
        show_status
        return 0
    fi
    
    log INFO "Starting LangSmith/LangSmith Deployment Installation Script"
    
    # Check prerequisites
    check_prerequisites
    
    # Setup namespace
    setup_namespace
    
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
            ;;
        down)
            uninstall_all
            ;;
        *)
            log ERROR "Unknown action: ${ACTION}"
            exit 1
            ;;
    esac
    
    log SUCCESS "Script completed successfully"
}

# Execute main function with all arguments
main "$@"

