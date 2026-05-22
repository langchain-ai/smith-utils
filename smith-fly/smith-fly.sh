#!/bin/bash

##############################################################################
# LangSmith and LangSmith Deployment Installation Script for Kubernetes Clusters
#
# Description: Automates the installation and management of LangSmith,
#              LangSmith Deployment, and Agent Builder on any Kubernetes cluster (cross-platform)
#
# Usage: ./smith-fly.sh <up|down|delete|status> [-l|-ls|-ld|-lds|-lda|-ldas] [-v VERSION] [-n NAMESPACE]
#
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

# Optional extra values file layered on top of LS_CONFIG_YAML.
# Set EXTRA_VALUES=/path/to/values.yaml in the environment before running.
EXTRA_VALUES="${EXTRA_VALUES:-}"

# Emits a ' --values "<path>"' fragment when EXTRA_VALUES points at a real file,
# so callers can append it to a helm command being built up as a string.
_extra_values_arg() {
  if [ -n "$EXTRA_VALUES" ] && [ -f "$EXTRA_VALUES" ]; then
    printf ' --values "%s"' "$EXTRA_VALUES"
  fi
}

ACTION=""
INSTALL_LS=false
INSTALL_LD=false
INSTALL_AB=false           # Agent Builder (requires Deployment)
INSTALL_INSIGHTS=false     # Insights (requires Deployment + Agent Builder)
INSTALL_POLLY=false        # Polly (requires Deployment + Agent Builder)
OPERATOR_SCALED_DOWN=false # Safety flag: true while operator is at 0 replicas during bootstrap
VERSION=""
DEBUG=false
NAMESPACE=""
INGRESS_TYPE=""  # Empty means auto-detect; 'alb' or 'nginx' if explicitly set
IS_V12_PLUS=true # Default to true (latest version assumes v12+)
initialOrgAdminEmail=""
LicenseKey=""
apiKeySalt=""
jwtSecret=""
initialOrgAdminPassword=""
POPULATE=false               # Whether to run populate.sh after install
RESOLVED_ENDPOINT=""         # Set by display_langsmith_info for use by populate
LANGSMITH_HOSTNAME=""        # Optional: custom hostname for LangSmith (can be set via .env)
agentBuilderEncryptionKey="" # Fernet key for Agent Builder (auto-generated or preserved)
insightsEncryptionKey=""     # Fernet key for Insights (auto-generated or preserved)
pollyEncryptionKey=""        # Fernet key for Polly (auto-generated or preserved)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect sed command (use gsed on macOS for GNU sed compatibility)
if [[ "$OSTYPE" == "darwin"* ]]; then
  if command -v gsed &>/dev/null; then
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
  IFS='.' read -r major minor _ <<<"$version"

  # Handle non-numeric values gracefully
  if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
    log WARNING "Unable to parse version '$version', assuming v12+"
    return 0
  fi

  # Check if version >= 0.12.0
  if [ "$major" -gt 0 ] || [ "$minor" -ge 12 ]; then
    return 0 # v12+
  fi

  return 1 # pre-v12
}

##############################################################################
# Function: is_hibernated
# Description: Checks if a given namespace is hibernated
# Returns: 0 if version >= 0.13.0 or empty (latest), 1 otherwise
##############################################################################
is_hibernated() {
  local ns="$1"
  local state
  state=$(kubectl get namespace "$ns" \
    -o jsonpath='{.metadata.annotations.smith-fly\.langchain\.dev/state}' \
    2>/dev/null || echo "")
  [ "$state" = "down" ]
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

  IFS='.' read -r major minor _ <<<"$version"

  if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  if [ "$major" -gt 0 ] || [ "$minor" -ge 13 ]; then
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

  IFS='.' read -r major minor patch <<<"$version"

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
    return 0 # EKS detected
  fi

  # Check node provider ID for AWS (format: aws://region/instance-id)
  if kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -q "^aws://"; then
    return 0 # AWS detected
  fi

  return 1 # Not EKS
}

##############################################################################
# Function: is_minikube_cluster
# Description: Detects if the current Kubernetes cluster is Minikube
# Returns: 0 if Minikube detected, 1 otherwise
##############################################################################
is_minikube_cluster() {
  # Check if minikube command exists and is the current context
  if command -v minikube &>/dev/null; then
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || echo "")
    if [ "$current_context" = "minikube" ]; then
      return 0 # Minikube detected
    fi
  fi

  # Check node labels for minikube-specific labels
  if kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "minikube.k8s.io"; then
    return 0 # Minikube detected
  fi

  # Check node name contains "minikube"
  if kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -qi "minikube"; then
    return 0 # Minikube detected
  fi

  return 1 # Not Minikube
}

##############################################################################
# Function: is_keda_installed
# Description: Checks if KEDA (Kubernetes Event-Driven Autoscaling) is installed
# Returns: 0 if KEDA CRDs exist, 1 otherwise
##############################################################################
is_keda_installed() {
  kubectl get crd scaledobjects.keda.sh &>/dev/null
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
  if ! kubectl get svc ingress-nginx-controller -n ingress-nginx &>/dev/null; then
    log WARNING "ingress-nginx-controller service not found in ingress-nginx namespace"
    return 1
  fi

  # Kill any existing port-forward on the same port
  pkill -f "kubectl port-forward.*ingress-nginx-controller.*${port}:80" 2>/dev/null || true

  # Start port-forward in background
  nohup kubectl port-forward svc/ingress-nginx-controller -n ingress-nginx "${port}:80" >/dev/null 2>&1 &
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
  cat <<EOF
Usage: $0 <up|down|delete|status> [-l|-ls|-ld|-lds|-lda|-ldas] [-v VERSION] [-n NAMESPACE] [-i alb|nginx] [--debug]

Actions:
    up      Spin up/install LangSmith, LangSmith Deployment, or Agent Builder
    down    Scale down the deployment (but preserve persistent data)
    delete  Remove LangSmith from all namespaces (or a specific one with -n)
    status  Check installation status of LangSmith and LangSmith Deployment

Options (for 'up' action):
    -l      Install LangSmith (tracing, eval, playground)
    -ls     Install LangSmith + populate with synthetic test data (traces, feedback, datasets, prompts)
    -ld     Install LangSmith Deployment (adds LangGraph deployment to -l)
    -lds    Install LangSmith Deployment + populate with synthetic test data
    -lda    Install LangSmith Deployment + Agent Builder (adds no-code agent creation to -ld, v0.13+)
    -ldas   Install LangSmith Deployment + Agent Builder + populate with synthetic test data
    -ld[a][i][p]  Install LangSmith Deployment with optional add-ons (v0.13+ required for add-ons):
                    a = Agent Builder (no-code agent creation)
                    i = Insights
                    p = Polly
                  Letters can be combined in any order, e.g. -lda -ldi -ldp -ldai -ldip -ldap -ldaip
    -v      Specify version (optional)
    -n      Custom namespace (must start with a letter, lowercase alphanumeric/hyphens, max 63 chars)
    -i      Ingress type: alb or nginx (auto-detected if not specified)


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
    $0 up -lda                   # Install LangSmith Deployment + Agent Builder (requires more resources)
    $0 up -ldi                   # Install LangSmith Deployment + Insights
    $0 up -ldp                   # Install LangSmith Deployment + Polly
    $0 up -ldai                  # Install LangSmith Deployment + Agent Builder + Insights
    $0 up -ldip                  # Install LangSmith Deployment + Insights + Polly
    $0 up -ldaip                 # Install LangSmith Deployment + Agent Builder + Insights + Polly
    $0 delete                    # Remove LangSmith from ALL namespaces (auto-discovers deployments)
    $0 delete -n my-namespace    # Remove LangSmith from a specific namespace only
    $0 down -n my-namespace      # Stop the langsmith deployment based on namespace
    $0 status                    # Check installation status of LangSmith and LangSmith Deployment
    $0 status -n my-namespace    # Check status in a custom namespace

Notes:
    - At least one of -l, -ls, -ld, -lds, -lda, or -ldas must be specified with "up"
    - When installing LangSmith Deployment (-ld), LangSmith is automatically installed if not already present
    - Agent Builder (-lda) spawns additional operator-managed pods (its own Postgres, Redis, queue, API server)
    - On Minikube, -lda auto-patches LGP resources to dev-friendly sizes and disables autoscaling
    - Recommended Minikube resources for -lda: 10 CPUs / 24Gi RAM (Docker Desktop)
    - The "delete" action removes LangSmith from all namespaces (or a specific one with -n)
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
  if ! command -v kubectl &>/dev/null; then
    missing_tools+=("kubectl")
  fi

  # Check helm
  if ! command -v helm &>/dev/null; then
    missing_tools+=("helm")
  fi

  # Check openssl
  if ! command -v openssl &>/dev/null; then
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
  up | down | delete | status)
    ACTION="$1"
    shift
    ;;
  -h | --help)
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
      alb | nginx)
        INGRESS_TYPE="$2"
        ;;
      *)
        log ERROR "Invalid ingress type: $2. Must be 'alb' or 'nginx'"
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

  # NOTE: validation that at least one of -l, -ld, -lda is set for 'up' was
  # moved to main() — it must run AFTER the hibernation check, because
  # `up -n <hibernated-ns>` (no install flags) is a valid resume invocation.

  # Validate version requirements for Agent Builder / Insights / Polly (all require v0.13+)
  if [ "$ACTION" = "up" ] && { [ "$INSTALL_AB" = true ] || [ "$INSTALL_INSIGHTS" = true ] || [ "$INSTALL_POLLY" = true ]; }; then
    if ! is_version_v13_plus "$VERSION"; then
      log ERROR "Agent Builder / Insights / Polly require chart version >= 0.13.0. Specified: ${VERSION}"
      exit 1
    fi
    # Warn about known-bad version range (0.13.17 through 0.13.22)
    # See: docs/bug-report-agent-builder-bootstrap-regression.md
    if is_version_in_range "$VERSION" 17 22; then
      log WARNING "Chart version ${VERSION} has a known agent-builder bootstrap regression."
      log WARNING "The bootstrap job fails with: 'source_config.listener_id' must be set."
      log WARNING "Recommended: use -v 0.13.16 or >= 0.13.23 instead."
      exit 1
    fi
  fi

  # For 'down' action, remove both regardless of flags
  if [ "$ACTION" = "down" ]; then
    INSTALL_LS=true
    INSTALL_LD=true
    log INFO "Down action will remove both LangSmith and LangSmith Deployment"
  fi

  # Verbose logging + version detection deferred to main() so the early
  # hibernation check can short-circuit before printing anything.
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
    log INFO "Hint: prefix with a string, e.g. 'ls-${ns}'"
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
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
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
  release_status=$(helm status langsmith -n "$NAMESPACE" -o json 2>/dev/null |
    python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('info',{}).get('status',''))" \
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
      kubectl get ingress langsmith-ingress -n "$NAMESPACE" -o json |
        python3 -c "
import sys, json
obj = json.load(sys.stdin)
obj['metadata']['managedFields'] = [
    m for m in obj['metadata'].get('managedFields', [])
    if m.get('manager') != 'manager'
]
json.dump(obj, sys.stdout)" |
        kubectl apply -f - 2>/dev/null || true
    fi
  fi

  log INFO "Executing: ${helm_cmd}"

  # Run helm in the background; redirect output to temp log
  eval "$helm_cmd" >"$helm_log" 2>&1 &
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
    kill -0 "$helm_pid" 2>/dev/null || break # may have exited during sleep

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
      ((total++)) || true
      local pname pstatus
      pname=$(printf '%s' "$pod_line" | awk '{print $1}')
      pstatus=$(printf '%s' "$pod_line" | awk '{print $3}')
      case "$pstatus" in
      Running) ((running++)) || true ;;
      Completed) ((completed++)) || true ;;
      Pending | Init:*) ((pending++)) || true ;;
      CrashLoopBackOff | Error | \
        OOMKilled | ImagePullBackOff | \
        ErrImagePull)
        if [[ "$pname" =~ ^(smith-|lg-|clio-|agent-builder-) ]]; then
          ((other++)) || true
        else
          ((bad++)) || true
        fi
        ;;
      *) ((other++)) || true ;;
      esac
    done <<<"$pod_output"

    # Stuck detection: kill helm if bad-pod count hasn't improved
    if ((bad > 0)); then
      if ((bad >= last_bad)); then
        ((stuck_count++)) || true
      else
        stuck_count=0
      fi
      last_bad=$bad

      if ((stuck_count >= stuck_threshold)); then
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
    if ((total > 0 && running == total && bad == 0 && pending == 0 && other == 0)); then
      ((stable_count++)) || true
      if ((stable_count >= stable_threshold)); then
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
    ((completed > 0)) && status_line+=", ${completed} Completed" || true
    ((pending > 0)) && status_line+=", ${pending} Pending/Init" || true
    ((bad > 0)) && status_line+=", ${bad} Failed [${stuck_count}/${stuck_threshold} checks]" || true
    ((other > 0)) && status_line+=", ${other} Other" || true
    log INFO "Pods: ${status_line}"

    # Surface non-Running/non-Completed pods with truncated names
    if ((bad > 0 || pending > 0 || other > 0)); then
      while IFS= read -r pod_line; do
        [ -z "$pod_line" ] && continue
        local pname pstatus
        pname=$(printf '%s' "$pod_line" | awk '{print $1}')
        pstatus=$(printf '%s' "$pod_line" | awk '{print $3}')
        case "$pstatus" in Running | Completed) continue ;; esac
        [ ${#pname} -gt 45 ] && pname="${pname:0:42}..."
        log WARNING "  $(printf '%-45s %s' "$pname" "$pstatus")"
      done <<<"$pod_output"
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

  # Generate Fernet-compatible encryption key for Agent Builder
  # Fernet key = URL-safe base64 encoding of 32 random bytes
  if [ -z "$agentBuilderEncryptionKey" ]; then
    agentBuilderEncryptionKey=$(openssl rand -base64 32 | tr '+/' '-_')
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

  # Also try to preserve Agent Builder and Insights encryption keys if they exist
  # encryptionKey appears under both agentBuilder and insights sections; grab both
  local existing_ab_key existing_insights_key existing_polly_key
  existing_ab_key=$(grep --color=never -A5 'agentBuilder:' "$LS_CONFIG_YAML" 2>/dev/null | grep --color=never 'encryptionKey:' | $SED_CMD 's/.*encryptionKey:\s*"\?\([^"]*\)"\?.*/\1/' | head -1)
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

    # Preserve Agent Builder encryption key if found
    if [ -n "$existing_ab_key" ]; then
      agentBuilderEncryptionKey="$existing_ab_key"
      log INFO "Preserved existing Agent Builder encryption key"
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

  # Ensure Agent Builder encryption key exists (may not be in older configs)
  if [ -z "$agentBuilderEncryptionKey" ]; then
    agentBuilderEncryptionKey=$(openssl rand -base64 32 | tr '+/' '-_')
    log INFO "Generated new Agent Builder encryption key"
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
      echo "  langgraphPlatformLicenseKey: \"${LicenseKey}\"" >"$temp_insert"
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
  helm_cmd+="$(_extra_values_arg)"
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
  if kubectl get crd lgps.apps.langchain.ai &>/dev/null; then
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
# Function: wait_and_patch_lgp_resources
# Description: Waits for the agent-bootstrap job to create the LGP CRD, then
#   patches operator-managed pod resources down to dev-friendly sizes and
#   disables autoscaling. This prevents rolling update deadlocks on Minikube
#   where production-sized pods can't coexist during updates.
##############################################################################
wait_and_patch_lgp_resources() {
  log INFO "Waiting for Agent Builder bootstrap to create LGP resource..."
  local max_wait=300 # 5 minutes
  local elapsed=0
  local lgp_name=""

  while [ $elapsed -lt $max_wait ]; do
    lgp_name=$(kubectl get lgp -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$lgp_name" ]; then
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [ -z "$lgp_name" ]; then
    log WARNING "LGP resource not found after ${max_wait}s - skipping resource patch. Agent Builder may need manual resource tuning."
    return 0
  fi

  log INFO "Found LGP: ${lgp_name}. Patching resources to dev-friendly sizes..."

  # Define the patch payload (used repeatedly since bootstrap overwrites it)
  local lgp_patch='{
      "spec": {
        "autoscaling": {
          "enabled": false,
          "maxReplicas": 1,
          "minReplicas": 1,
          "queueMaxReplicas": 1,
          "queueMinReplicas": 1
        },
        "serverSpec": {
          "resources": {
            "requests": {"cpu": "250m", "memory": "512Mi"},
            "limits": {"cpu": "1", "memory": "1Gi"}
          },
          "queueResources": {
            "requests": {"cpu": "250m", "memory": "512Mi"},
            "limits": {"cpu": "1", "memory": "1Gi"}
          }
        },
        "database": {
          "resources": {
            "requests": {"cpu": "250m", "memory": "512Mi"},
            "limits": {"cpu": "1", "memory": "1Gi"}
          }
        },
        "redis": {
          "resources": {
            "requests": {"cpu": "100m", "memory": "256Mi"},
            "limits": {"cpu": "500m", "memory": "512Mi"}
          }
        }
      }
    }'

  # Apply initial patch
  kubectl patch lgp "$lgp_name" -n "$NAMESPACE" --type=merge -p "$lgp_patch" 2>/dev/null &&
    log SUCCESS "LGP resources patched for local development" ||
    log WARNING "Failed to patch LGP resources"

  # Wait for the bootstrap job to complete, re-patching LGP every cycle
  # since bootstrap overwrites our dev-sized resources with production values.
  log INFO "Waiting for Agent Builder bootstrap to complete (this may take a few minutes)..."
  local bootstrap_wait=0
  local bootstrap_max=600 # 10 minutes
  while [ $bootstrap_wait -lt $bootstrap_max ]; do
    # Check if bootstrap job is done (pod shows Completed or no active bootstrap pod)
    # NOTE: "|| true" is critical — without it, set -euo pipefail kills the script
    # when grep returns non-zero (no match for an active bootstrap pod).
    local bootstrap_active
    bootstrap_active=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null |
      grep "agent-bootstrap" | grep -v "Completed" | head -1 || true)
    if [ -z "$bootstrap_active" ]; then
      log SUCCESS "Agent Builder bootstrap completed"
      # Final patch to ensure dev sizes stick
      kubectl patch lgp "$lgp_name" -n "$NAMESPACE" --type=merge -p "$lgp_patch" 2>/dev/null || true
      log INFO "Scaling operator back to 1 replica..."
      kubectl scale deployment langsmith-operator -n "$NAMESPACE" --replicas=1 2>/dev/null || true
      OPERATOR_SCALED_DOWN=false
      return 0
    fi

    # Re-apply patch every cycle to counteract bootstrap overwrites
    kubectl patch lgp "$lgp_name" -n "$NAMESPACE" --type=merge -p "$lgp_patch" 2>/dev/null || true

    # Unstick any Pending pods by deleting old ReplicaSets
    local pending_pods
    pending_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null |
      grep "agent-builder-" | grep "Pending" | wc -l | tr -d ' ' || echo "0")
    if [ "$pending_pods" -gt 0 ] 2>/dev/null; then
      log INFO "Found ${pending_pods} Pending agent-builder pod(s) — patching resources to free space..."
    fi

    sleep 10
    bootstrap_wait=$((bootstrap_wait + 10))
    # Log progress every 30s
    if [ $((bootstrap_wait % 30)) -eq 0 ]; then
      local status
      status=$(kubectl logs -n "$NAMESPACE" -l job-name=langsmith-agent-bootstrap --tail=1 2>/dev/null |
        grep -o 'Status: [A-Z_]*' | tail -1 || true)
      log INFO "Bootstrap still running... ${status:-checking}"
    fi
  done

  log WARNING "Bootstrap did not complete within ${bootstrap_max}s - it may still be running in the background"
  log INFO "Scaling operator back to 1 replica..."
  kubectl scale deployment langsmith-operator -n "$NAMESPACE" --replicas=1 2>/dev/null || true
  OPERATOR_SCALED_DOWN=false
}

##############################################################################
# Function: fix_agent_builder_browser_access
# Description: After bootstrap completes, the ingress host and agent-builder
#   config use the internal ingress DNS (needed for operator health checks).
#   This function patches them to use localhost so the browser can reach them.
##############################################################################
fix_agent_builder_browser_access() {
  local port="${1:-8080}" # Default port-forward port
  log INFO "Switching Agent Builder URLs from internal DNS to localhost:${port} for browser access..."

  # 1. Create a separate ingress for ALL routes under host "localhost".
  #    The operator continuously reconciles langsmith-ingress, re-adding /lgp/
  #    paths under the internal DNS host and undoing any host-merge patches.
  #    A separate ingress avoids this conflict entirely.
  #    Must include BOTH the frontend "/" route AND the "/lgp/..." route, otherwise
  #    the browser can't reach the frontend when port-forwarding to localhost.
  local lgp_path
  lgp_path=$(kubectl get ingress -n "$NAMESPACE" -o json 2>/dev/null | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
for ing in data.get('items', []):
    for rule in ing['spec'].get('rules', []):
        for p in rule.get('http', {}).get('paths', []):
            if '/lgp/' in p.get('path', ''):
                import json as j
                print(j.dumps({'path': p['path'], 'svc': p['backend']['service']['name'], 'port': p['backend']['service']['port']['number']}))
                break
" 2>/dev/null | head -1)

  if [ -n "$lgp_path" ]; then
    local lgp_route lgp_svc lgp_port
    lgp_route=$(echo "$lgp_path" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['path'])")
    lgp_svc=$(echo "$lgp_path" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['svc'])")
    lgp_port=$(echo "$lgp_path" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['port'])")

    kubectl apply -n "$NAMESPACE" -f - <<INGEOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: langsmith-lgp-localhost
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
spec:
  ingressClassName: nginx
  rules:
  - host: localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: langsmith-frontend
            port:
              number: 80
      - path: ${lgp_route}
        pathType: Prefix
        backend:
          service:
            name: ${lgp_svc}
            port:
              number: ${lgp_port}
INGEOF
    log SUCCESS "Created localhost ingress with frontend and LGP routes"
  else
    log WARNING "Could not find LGP path in existing ingress rules"
  fi

  # 2. Patch agent-builder-config URLs for browser access
  local ab_configmap="langsmith-agent-builder-config"
  if kubectl get configmap "$ab_configmap" -n "$NAMESPACE" &>/dev/null; then
    local lgp_path
    lgp_path=$(kubectl get configmap "$ab_configmap" -n "$NAMESPACE" \
      -o jsonpath='{.data.LANGGRAPH_API_URL_PUBLIC}' 2>/dev/null | grep -oE '/lgp/[^"]+')

    if [ -n "$lgp_path" ]; then
      kubectl patch configmap "$ab_configmap" -n "$NAMESPACE" --type=merge -p "{
              \"data\": {
                \"LANGGRAPH_API_URL_PUBLIC\": \"http://localhost:${port}${lgp_path}\",
                \"VITE_AGENT_BUILDER_DEPLOYMENT_URL_PUBLIC\": \"http://localhost:${port}${lgp_path}\",
                \"VITE_AGENT_BUILDER_GENERATOR_DEPLOYMENT_URL_PUBLIC\": \"http://localhost:${port}${lgp_path}\",
                \"VITE_AGENT_BUILDER_MCP_SERVER_URL\": \"http://localhost:${port}/mcp\",
                \"VITE_AGENT_BUILDER_TRIGGERS_API_URL\": \"http://localhost:${port}\"
              }
            }" 2>/dev/null &&
        log SUCCESS "Agent Builder config patched for browser access" ||
        log WARNING "Failed to patch Agent Builder config"
    else
      log WARNING "Could not determine LGP path from agent-builder-config"
    fi

    # 3. Restart frontend pod to pick up new config
    kubectl delete pod -n "$NAMESPACE" -l app.kubernetes.io/component=langsmith-frontend --wait=false 2>/dev/null
    log INFO "Frontend pod restarted to pick up new config"
  else
    log WARNING "Agent Builder config map not found - it may not have been created yet"
  fi

  # 4. Fix agent-builder pod's backend URLs: the bootstrap creates a secret
  #    with https:// URLs through the ingress, which fails on self-signed certs.
  #    Patch to use http:// internal service DNS, bypassing the ingress entirely.
  local ab_secret
  ab_secret=$(kubectl get secrets -n "$NAMESPACE" --no-headers 2>/dev/null | grep "agent-builder.*secrets" | awk '{print $1}' | head -1)
  if [ -n "$ab_secret" ]; then
    local go_ep_b64 host_ep_b64 smith_ep_b64 mcp_ep_b64
    go_ep_b64=$(echo -n "http://langsmith-platform-backend.${NAMESPACE}.svc.cluster.local:1986" | base64)
    host_ep_b64=$(echo -n "http://langsmith-host-backend.${NAMESPACE}.svc.cluster.local:1985" | base64)
    smith_ep_b64=$(echo -n "http://langsmith-backend.${NAMESPACE}.svc.cluster.local:1984" | base64)
    mcp_ep_b64=$(echo -n "http://langsmith-agent-builder-tool-server.${NAMESPACE}.svc.cluster.local:1989/mcp" | base64)

    kubectl patch secret "$ab_secret" -n "$NAMESPACE" --type=merge -p "{
          \"data\": {
            \"GO_ENDPOINT\": \"${go_ep_b64}\",
            \"HOST_BACKEND_ENDPOINT\": \"${host_ep_b64}\",
            \"SMITH_BACKEND_ENDPOINT\": \"${smith_ep_b64}\",
            \"MCP_SERVER_URL\": \"${mcp_ep_b64}\"
          }
        }" 2>/dev/null &&
      log SUCCESS "Agent Builder secret patched to use internal HTTP endpoints" ||
      log WARNING "Failed to patch Agent Builder secret"

    # Restart agent-builder API and queue pods to pick up new secret
    kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null |
      grep "^agent-builder-" | grep -v "redis\|tool\|trigger\|bootstrap" |
      awk '{print $1}' | while read -r pod; do
      kubectl delete pod "$pod" -n "$NAMESPACE" --wait=false 2>/dev/null
    done
    log INFO "Agent Builder API and queue pods restarted to pick up new endpoints"
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
      if [ "$INSTALL_AB" = true ] && is_minikube_cluster; then
        # Minikube: use internal ingress DNS so the listener can health-check LGP pods
        ingress_hostname="ingress-nginx-controller.ingress-nginx.svc.cluster.local"
        log INFO "Using internal ingress hostname for Agent Builder on Minikube: ${ingress_hostname}"
      elif [ "$INGRESS_TYPE" = "alb" ]; then
        # ALB rejects 'localhost' (no dots) as an invalid listener rule condition.
        # Phase 1: install basic LangSmith (no deployment features) to provision the ALB.
        # Phase 2: upgrade with the real ALB hostname and all features.
        log INFO "ALB cluster with no existing hostname — running two-phase deploy to provision ALB first..."
        local phase1_cmd="helm upgrade --install langsmith langchain/langsmith"
        phase1_cmd+=" --namespace \"${NAMESPACE}\""
        phase1_cmd+=" --values \"${LS_CONFIG_YAML}\""
        phase1_cmd+="$(_extra_values_arg)"
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
    [ "$INSTALL_AB" = true ] && features_enabled+=("agentBuilder")
    [ "$INSTALL_INSIGHTS" = true ] && features_enabled+=("insights")
    [ "$INSTALL_POLLY" = true ] && features_enabled+=("polly")
    log INFO "Enabling config.deployment, setting config.hostname${features_enabled:+, $(
      IFS=', '
      echo "${features_enabled[*]}"
    )} in LangSmith config"

    # Flip deployment.enabled false -> true (scoped to the line after 'deployment:')
    $SED_CMD -i.bak '/^  deployment:$/{n; s/enabled: false/enabled: true/}' "$LS_CONFIG_YAML"
    rm -f "${LS_CONFIG_YAML}.bak"

    # Inject hostname and optional feature configs after 'config:' line
    local temp_insert
    temp_insert=$(mktemp)
    {
      echo "  hostname: \"${ingress_hostname}\""
      if [ "$INSTALL_AB" = true ]; then
        echo "  agentBuilder:"
        echo "    enabled: true"
        echo "    encryptionKey: \"${agentBuilderEncryptionKey}\""
      fi
      if [ "$INSTALL_INSIGHTS" = true ]; then
        echo "  insights:"
        echo "    enabled: true"
        echo "    encryptionKey: \"${insightsEncryptionKey}\""
      fi
      if [ "$INSTALL_POLLY" = true ]; then
        echo "  polly:"
        echo "    enabled: true"
        echo "    encryptionKey: \"${pollyEncryptionKey}\""
      fi
    } >"$temp_insert"
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
    helm_cmd+="$(_extra_values_arg)"
    helm_cmd+=" --wait --timeout 30m"
    helm_cmd+=" --hide-notes"

    # Add version if specified (important: preserve version when upgrading for deployment)
    if [ -n "$VERSION" ]; then
      helm_cmd+=" --version ${VERSION}"
      log INFO "Using LangSmith version: ${VERSION}"
    fi

    # Only skip CRD creation if CRD already exists (shared cluster scenario)
    # This prevents "invalid ownership metadata" errors in shared clusters
    if kubectl get crd lgps.apps.langchain.ai &>/dev/null; then
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

    # Enable Agent Builder and Insights components if requested (v0.13+)
    if [ "$INSTALL_AB" = true ]; then
      helm_cmd+=" --set agentBuilderToolServer.enabled=true"
      helm_cmd+=" --set agentBuilderTriggerServer.enabled=true"
      if [ "$INSTALL_INSIGHTS" = true ]; then
        helm_cmd+=" --set config.insights.enabled=true"
      fi
      if [ "$INSTALL_POLLY" = true ]; then
        helm_cmd+=" --set config.polly.enabled=true"
      fi
      if is_minikube_cluster; then
        helm_cmd+=" --set config.tlsEnabled=false"
        # Disable ingress health check: the listener health-checks LGP pods
        # via the nginx ingress, which serves HTTPS with a self-signed cert.
        # This causes SSL_CERTIFICATE_VERIFY_FAILED inside the listener pod.
        helm_cmd+=" --set config.deployment.ingressHealthCheckEnabled=false"
        # Phase 1: Install WITHOUT bootstrap hook. The bootstrap job has
        # backoffLimit=0 and runs before host-backend is fully initialized,
        # causing guaranteed failure. Install core components first, then
        # run bootstrap in Phase 2 when everything is stable.
        log INFO "Minikube detected: installing in two phases (core first, bootstrap second)"
        helm_cmd+=" --set backend.agentBootstrap.enabled=false"
      else
        helm_cmd+=" --set backend.agentBootstrap.enabled=true"
      fi
    fi

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
      if is_minikube_cluster; then
        log SUCCESS "Phase 1 complete: core components installed"

        # Wait for all key deployments to be fully ready before bootstrap
        log INFO "Waiting for all deployments to stabilize before running bootstrap..."
        for dep in langsmith-host-backend langsmith-listener langsmith-backend langsmith-operator; do
          kubectl rollout status "deployment/${dep}" -n "$NAMESPACE" --timeout=300s 2>/dev/null || true
        done
        log SUCCESS "All core deployments ready"

        # Scale operator to 0 before bootstrap to eliminate the race condition
        # where the operator reconciles production-sized LGP defaults before
        # wait_and_patch_lgp_resources can patch them down to dev sizes.
        log INFO "Scaling operator to 0 replicas to prevent premature LGP reconciliation..."
        OPERATOR_SCALED_DOWN=true
        kubectl scale deployment langsmith-operator -n "$NAMESPACE" --replicas=0
        kubectl rollout status deployment/langsmith-operator -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

        # Phase 2: Re-run helm with bootstrap enabled and --wait=false.
        # The bootstrap job is a Helm post-upgrade hook with backoffLimit=0,
        # which means --wait will fail if the hook fails even once.
        # We use --wait=false here and let wait_and_patch_lgp_resources
        # handle monitoring the bootstrap progress.
        log INFO "Phase 2: running agent bootstrap..."
        local helm_cmd2="helm upgrade langsmith langchain/langsmith"
        helm_cmd2+=" --namespace \"${NAMESPACE}\""
        helm_cmd2+=" --values \"${LS_CONFIG_YAML}\""
        helm_cmd2+="$(_extra_values_arg)"
        helm_cmd2+=" --wait=false"
        helm_cmd2+=" --timeout 30m"
        helm_cmd2+=" --hide-notes"
        helm_cmd2+=" --set backend.agentBootstrap.enabled=true"
        helm_cmd2+=" --set agentBuilderToolServer.enabled=true"
        helm_cmd2+=" --set agentBuilderTriggerServer.enabled=true"
        if [ "$INSTALL_INSIGHTS" = true ]; then
          helm_cmd2+=" --set config.insights.enabled=true"
        fi
        if [ "$INSTALL_POLLY" = true ]; then
          helm_cmd2+=" --set config.polly.enabled=true"
        fi
        helm_cmd2+=" --set config.tlsEnabled=false"
        helm_cmd2+=" --set config.deployment.ingressHealthCheckEnabled=false"
        helm_cmd2+=" --set operator.kedaEnabled=false"
        if kubectl get crd lgps.apps.langchain.ai &>/dev/null; then
          helm_cmd2+=" --set operator.createCRDs=false"
        fi
        if [ "$INGRESS_TYPE" = "nginx" ] || [ "$INGRESS_TYPE" = "alb" ]; then
          helm_cmd2+=" --set frontend.service.type=ClusterIP"
        fi
        if [ -n "$VERSION" ]; then
          helm_cmd2+=" --version ${VERSION}"
        fi
        if [ "$DEBUG" = true ]; then
          helm_cmd2+=" --debug"
        fi

        log INFO "Executing: ${helm_cmd2}"
        eval "$helm_cmd2"
        log SUCCESS "Phase 2 complete: bootstrap hook triggered"

        # On Minikube: wait for bootstrap to create the LGP, then patch resources
        wait_and_patch_lgp_resources
        # Switch from internal DNS to localhost for browser access
        fix_agent_builder_browser_access
      else
        log SUCCESS "LangSmith upgraded with deployment and Agent Builder enabled"
      fi
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
    cat >"$temp_insert" <<EOF
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
    helm_cmd+="$(_extra_values_arg)"
    helm_cmd+=" --wait --timeout 30m"
    helm_cmd+=" --hide-notes"

    # Add version if specified
    if [ -n "$VERSION" ]; then
      helm_cmd+=" --version ${VERSION}"
      log INFO "Using LangSmith version: ${VERSION}"
    fi

    # Only skip CRD creation if CRD already exists (shared cluster scenario)
    if kubectl get crd lgps.apps.langchain.ai &>/dev/null; then
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
  cat <<EOF
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

  # Export resolved endpoint for use by populate and other post-install steps
  if [ "$endpoint_pending" != true ] && [ -n "$endpoint" ]; then
    RESOLVED_ENDPOINT="http://${endpoint}"
  fi
}

##############################################################################
# Function: resume_from_hibernate
# Description: Restores a hibernated namespace by scaling pods back up and
#              removing the hibernation annotations. Inverse of `down`.
# Arguments:  $1 - namespace to resume
##############################################################################
resume_from_hibernate() {
  local ns="$1"

  log INFO "Resuming hibernated namespace: ${ns}"

  # Scale statefulsets back up first so databases are ready before app pods start
  kubectl scale statefulset --all -n "$ns" --replicas=1
  # Scale non-operator deployments next
  kubectl get deployment -n "$ns" -o name 2>/dev/null |
    grep -v 'deployment.apps/langsmith-operator$' |
    while read -r d; do
      kubectl scale "$d" -n "$ns" --replicas=1
    done
  # Bring the operator back last so it can reconcile any operator-owned pods
  kubectl scale deployment langsmith-operator -n "$ns" --replicas=1 2>/dev/null ||
    log WARNING "langsmith-operator deployment not found in ${ns}"

  # Strip hibernation annotations (trailing '-' = remove)
  kubectl annotate namespace "$ns" \
    smith-fly.langchain.dev/state- \
    smith-fly.langchain.dev/down-at- \
    smith-fly.langchain.dev/version- \
    2>/dev/null || true

  log SUCCESS "Namespace ${ns} resumed"
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
  if ! kubectl get namespace "$targetNs" &>/dev/null; then
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
  helm list --all-namespaces --filter '^langsmith$' 2>/dev/null |
    awk 'NR>1 {print $2}' || true

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
    done <<<"$discovered"

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

  # Early hibernation check: for `up`, decide refuse-or-resume BEFORE any
  # noisy logging, prerequisites, or helm setup. This requires only kubectl
  # and a resolvable NAMESPACE.
  if [ "$ACTION" = "up" ]; then
    # Derive namespace if not given via -n (mirrors setup_namespace logic)
    if [ -z "$NAMESPACE" ]; then
      NAMESPACE=$(hostname | tr '[:upper:]' '[:lower:]' | tr '.' '-')
      NAMESPACE=$(echo "$NAMESPACE" | sed 's/^[^a-z]*//')
    fi
    if ! validate_namespace "$NAMESPACE"; then
      exit 1
    fi

    if command -v kubectl &>/dev/null && is_hibernated "$NAMESPACE"; then
      if [ -n "$VERSION" ] || [ "$INSTALL_LS" = true ] || [ "$INSTALL_LD" = true ]; then
        log ERROR "Namespace '${NAMESPACE}' has a hibernated LangSmith install."
        log ERROR "  Chart: $(kubectl get ns "$NAMESPACE" -o jsonpath='{.metadata.annotations.smith-fly\.langchain\.dev/version}' 2>/dev/null)"
        log ERROR "  Down at: $(kubectl get ns "$NAMESPACE" -o jsonpath='{.metadata.annotations.smith-fly\.langchain\.dev/down-at}' 2>/dev/null)"
        log ERROR ""
        log ERROR "  To resume the existing install (preserves data):"
        log ERROR "      $0 up -n ${NAMESPACE}"
        log ERROR "  To wipe and reinstall (DESTROYS data):"
        log ERROR "      $0 delete -n ${NAMESPACE} && $0 up -n ${NAMESPACE} -l ..."
        exit 1
      fi
      resume_from_hibernate "$NAMESPACE"
      return 0
    fi

    # Not hibernated — now require install flags
    if [ "$INSTALL_LS" = false ] && [ "$INSTALL_LD" = false ]; then
      log ERROR "At least one of -l, -ld, or -lda must be specified with 'up' action"
      show_usage
    fi
  fi

  # Verbose summary (deferred from parse_arguments so hibernation can short-circuit)
  log INFO "Action: ${ACTION}"
  log INFO "Install LangSmith: ${INSTALL_LS}"
  log INFO "Install LangSmith Deployment: ${INSTALL_LD}"
  log INFO "Install Agent Builder: ${INSTALL_AB}"
  log INFO "Install Insights: ${INSTALL_INSIGHTS}"
  log INFO "Install Polly: ${INSTALL_POLLY}"
  log INFO "Ingress Type: ${INGRESS_TYPE}"
  if [ -n "$VERSION" ]; then
    log INFO "Version: ${VERSION}"
  fi
  detect_version

  log INFO "Starting LangSmith/LangSmith Deployment Installation Script"

  # Check prerequisites
  check_prerequisites

  # For 'delete' action, skip setup steps that are only needed for installation.
  # uninstall_all handles namespace discovery internally.
  if [ "$ACTION" = "delete" ]; then
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
  fi
  if [ "$ACTION" = "up" ]; then
    # Setup namespace (creates if missing — early check above already validated)
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

  if [ "$ACTION" = "down" ]; then
    # Bring down the operator first, or it'll bring pods back up
    kubectl scale deployment langsmith-operator -n $NAMESPACE --replicas=0
    # Scale deployments to 0
    kubectl scale deployment --all -n $NAMESPACE --replicas=0
    # Scale down statefulsets
    kubectl scale statefulset --all -n $NAMESPACE --replicas=0
    # annotate the namespace so we know it's "taken"
    kubectl annotate namespace "$NAMESPACE" \
      smith-fly.langchain.dev/state=down \
      smith-fly.langchain.dev/down-at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      smith-fly.langchain.dev/version="$(helm list -n "$NAMESPACE" -o json | jq -r '.[0].chart')" \
      --overwrite
  fi

  log SUCCESS "Script completed successfully"
}

# Execute main function with all arguments
main "$@"
