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
# Function: show_usage
# Description: Displays script usage information
##############################################################################
show_usage() {
    cat << EOF
Usage: $0 <up|down> [-l|-ld] [-v VERSION] [--debug]

Actions:
    up      Spin up/install LangSmith or LangSmith Deployment
    down    Delete both LangSmith and LangSmith Deployment from your installation

Options (for 'up' action):
    -l      Install LangSmith
    -ld     Install LangSmith Deployment
    -v      Specify version (optional)
    --debug Enable Helm debug output (optional)

Examples:
    $0 up -l                     # Install LangSmith only
    $0 up -l -v 1.2.3            # Install LangSmith with specific version
    $0 up -l --debug             # Install LangSmith with debug output
    $0 up -ld                    # Install LangSmith Deployment (automatically installs LangSmith if not present)
    $0 down                      # Remove both LangSmith and LangSmith Deployment

Notes:
    - At least one of -l or -ld must be specified with "up"
    - When installing LangSmith Deployment (-ld), LangSmith is automatically installed if not already present
    - The "down" action removes both LangSmith and LangSmith Deployment
    - Configuration is read from ${ENV_FILE}
    - Namespace is auto-generated from your local machine hostname

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
    
    # First argument should be action (up or down)
    case "$1" in
        up|down)
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
    
    log INFO "Action: ${ACTION}"
    log INFO "Install LangSmith: ${INSTALL_LS}"
    log INFO "Install LangSmith Deployment: ${INSTALL_LD}"
    
    if [ -n "$VERSION" ]; then
        log INFO "Version: ${VERSION}"
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
    sed -i.bak \
        -e "s/langsmithLicenseKey:.*/langsmithLicenseKey: \"${escaped_license}\"/" \
        -e "s/apiKeySalt:.*/apiKeySalt: \"${escaped_salt}\"/" \
        -e "s/initialOrgAdminEmail:.*/initialOrgAdminEmail: \"${escaped_email}\"/" \
        -e "s/initialOrgAdminPassword:.*/initialOrgAdminPassword: \"${escaped_password}\"/" \
        -e "s/jwtSecret:.*/jwtSecret: \"${escaped_jwt}\"/" \
        "$LS_CONFIG_YAML"
    
    # Add langgraphPlatformLicenseKey only if LangSmith Deployment is being installed
    if [ "$INSTALL_LD" = true ]; then
        if ! grep -q "langgraphPlatformLicenseKey" "$LS_CONFIG_YAML"; then
            sed -i.bak "/langsmithLicenseKey:/a\\
  langgraphPlatformLicenseKey: \"${escaped_license}\"" "$LS_CONFIG_YAML"
        else
            sed -i.bak "s/langgraphPlatformLicenseKey:.*/langgraphPlatformLicenseKey: \"${escaped_license}\"/" "$LS_CONFIG_YAML"
        fi
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
    
    # Build helm command
    local helm_cmd="helm upgrade --install langsmith langchain/langsmith"
    helm_cmd+=" --namespace ${NAMESPACE}"
    helm_cmd+=" --values ${LS_CONFIG_YAML}"
    helm_cmd+=" --wait --timeout 30m"
    helm_cmd+=" --hide-notes"
    
    # Add version if specified
    if [ -n "$VERSION" ]; then
        helm_cmd+=" --version ${VERSION}"
        log INFO "Installing LangSmith version: ${VERSION}"
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
    
    # Add LangSmith Deployment configuration under config section
    # Check if config section exists
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
            # Add langgraphPlatform under config section
            sed -i.bak "/^config:/a\\
  langgraphPlatform:\\
    enabled: true\\
    langgraphPlatformLicenseKey: \"${LicenseKey}\"" "$LD_CONFIG_YAML"
            rm -f "${LD_CONFIG_YAML}.bak"
        else
            # Update existing langgraphPlatform section
            sed -i.bak \
                -e "/langgraphPlatform:/,/enabled:/ s/enabled:.*/enabled: true/" \
                -e "/langgraphPlatform:/,/langgraphPlatformLicenseKey:/ s/langgraphPlatformLicenseKey:.*/langgraphPlatformLicenseKey: \"${escaped_license}\"/" \
                "$LD_CONFIG_YAML"
            rm -f "${LD_CONFIG_YAML}.bak"
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
    
    # Build helm command
    local helm_cmd="helm upgrade --install langsmith-deployment langchain/langgraph-cloud"
    helm_cmd+=" --namespace ${NAMESPACE}"
    helm_cmd+=" --values ${LD_CONFIG_YAML}"
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
    log INFO "Starting LangSmith/LangSmith Deployment Installation Script"
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Check prerequisites
    check_prerequisites
    
    # Load configuration
    load_configuration
    
    # Setup namespace
    setup_namespace
    
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

