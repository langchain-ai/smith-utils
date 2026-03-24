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
SKIP_CHECKS=false
CREATE_CLUSTER=false
CLOUDWATCH=false
EKS_NODEGROUP_NAME=""  # Auto-discovered if not set
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
# Function: is_keda_installed
# Description: Checks if KEDA (Kubernetes Event-Driven Autoscaling) is installed
# Returns: 0 if KEDA CRDs exist, 1 otherwise
##############################################################################
is_keda_installed() {
    kubectl get crd scaledobjects.keda.sh &> /dev/null
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
        INGRESS_TYPE="alb"
        log INFO "EKS detection inconclusive — defaulting to ALB ingress"
    fi
}

##############################################################################
# Function: show_usage
# Description: Displays script usage information
##############################################################################
show_usage() {
    echo "Usage: $0 <setup|addons|upgrade|up|down|status|pause|resume> [options]"
    echo "Run '$0 --help' for full documentation."
    exit 1
}

##############################################################################
# Function: show_help
# Description: Full reference documentation (--help). Exits 0.
##############################################################################
show_help() {
    cat << EOF

smith-fly — LangSmith on AWS EKS
$(printf '%.0s─' {1..70})

USAGE
    $0 <action> [options]

QUICKSTART — new cluster from scratch
    export AWS_CLUSTER_NAME=my-cluster AWS_REGION=us-east-1 ENGINEER=yourname
    export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...

    $0 setup my-cluster        # 1. Create EKS cluster + all addons (~20 min)
    \$EDITOR config/.env        # 2. Add LicenseKey + initialOrgAdminEmail
    $0 up -l                   # 3. Deploy LangSmith

ACTIONS — cluster
    setup [cluster-name]   Create EKS cluster + all addons. Steps:
                             1/7  Create EKS cluster (eksctl)
                             2/7  Configure kubectl
                             3/7  EBS CSI driver (PVC storage)
                             4/7  AWS Load Balancer Controller
                             5/7  Cluster Autoscaler (scale-to-zero)
                             6/7  CloudWatch Insights (--cloudwatch only)
                             7/7  Scheduled scaling 08:00-18:00 Mon-Fri

    addons                 Install/update all addons on an existing cluster.
                           Idempotent — safe to re-run.

    upgrade                Upgrade EKS control plane + node groups + addons
                           to the next Kubernetes minor version.
                           Prompts for confirmation. Irreversible.
    teardown               Permanently delete the EKS cluster and all AWS
                           resources. Prompts for cluster name confirmation.

ACTIONS — LangSmith
    up -l                  Deploy LangSmith
    up -ld                 Deploy LangSmith Deployment (installs LS if absent)
    down                   Remove LangSmith from all namespaces
    down -n <ns>           Remove from a specific namespace only
    status                 Show deployment status

ACTIONS — cost management
    pause                  Scale node group to 0 (EC2 billing stops, pods Pending)
    resume                 Scale node group back up to EKS_NODE_COUNT

OPTIONS
    -l                     Install LangSmith (required for 'up')
    -ld                    Install LangSmith Deployment (required for 'up')
    -v VERSION             Helm chart version (default: latest)
    -n NAMESPACE           Namespace (auto-generated from hostname if omitted)
    -i alb|nginx           Ingress type (auto-detected if omitted)
    --cloudwatch           Enable CloudWatch Container Insights (~\$15/mo)
    --tz TIMEZONE          Timezone for scheduled scale-up/down. Accepts IANA names
                           or aliases: london, amsterdam, newyork, california
                           (default: Europe/London or \$SCHEDULE_TIMEZONE)
    --debug                Verbose Helm output
    --skip-checks          Skip prerequisite tool checks
    -h, --help             Show this help

ENVIRONMENT VARIABLES — required
    AWS_CLUSTER_NAME       EKS cluster name
    AWS_REGION             AWS region (default: us-east-1)

ENVIRONMENT VARIABLES — authentication (one of)
    AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY   key-based auth
    AWS_SESSION_TOKEN                           assumed-role / SSO credentials
    AWS_PROFILE                                 named profile fallback

ENVIRONMENT VARIABLES — cluster config (all optional)
    ENGINEER               Your name for resource tagging. Set explicitly —
                           auto-detected from AWS identity if unset (warns).
    EKS_NODE_TYPE          EC2 instance type        (default: m5.xlarge)
    EKS_NODE_COUNT         Initial / resume count   (default: 2)
    EKS_NODE_MAX           Autoscaler maximum       (default: 10)
    EKS_KUBERNETES_VERSION Kubernetes version       (default: latest)
    EKS_NODEGROUP_NAME     Node group name          (auto-discovered)
    EKS_TAGS               Extra AWS tags: key=val,key2=val2

ENVIRONMENT VARIABLES — scheduled scaling (all optional)
    SCHEDULE_TIMEZONE      IANA timezone            (default: Europe/London)
    SCHEDULE_SCALE_UP      Cron warm-up             (default: "0 8 * * MON-FRI")
    SCHEDULE_SCALE_DOWN    Cron shutdown            (default: "0 18 * * MON-FRI")

ENVIRONMENT VARIABLES — Cluster Autoscaler (all optional)
    CA_SCALE_DOWN_UNNEEDED_TIME   Idle time before scale-down  (default: 10m)
    CA_SCALE_DOWN_DELAY_AFTER_ADD Grace period after scale-up  (default: 10m)

LANGSMITH CONFIG — config/.env  (see config/.env.example)
    LicenseKey                  (required) LangSmith license key
    initialOrgAdminEmail        (required) Admin login email
    initialOrgAdminPassword     (optional) Auto-generated if blank
    LANGSMITH_HOSTNAME          (optional) Custom domain

EXAMPLES
    ENGINEER=alice $0 setup my-cluster
    $0 up -l
    $0 up -l -v 0.12.3 -n my-namespace
    ENGINEER=alice $0 addons --cloudwatch
    $0 upgrade
    $0 pause
    $0 resume
    $0 down

$(printf '%.0s─' {1..70})

EOF
    exit 0
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
    
    # Check aws CLI if AWS_CLUSTER_NAME is set or action is setup
    if [ -n "${AWS_CLUSTER_NAME:-}" ] || [ "$ACTION" = "setup" ]; then
        if ! command -v aws &> /dev/null; then
            missing_tools+=("aws")
        fi
    fi

    # Check eksctl for setup action or --create-cluster flag
    if [ "$ACTION" = "setup" ] || [ "$CREATE_CLUSTER" = true ]; then
        if ! command -v eksctl &> /dev/null; then
            missing_tools+=("eksctl")
        fi
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log ERROR "Missing required tools: ${missing_tools[*]}"
        log ERROR "Please install the missing tools and try again."
        exit 1
    fi

    log SUCCESS "All prerequisites are installed"
}

##############################################################################
# Function: setup_aws_account
# Description: Configures kubectl for an EKS cluster using AWS env vars so
#              that subsequent kubectl/Helm calls (including setup_namespace)
#              target the correct cluster. Skipped when AWS_CLUSTER_NAME is unset.
#
# Env vars:
#   AWS_CLUSTER_NAME        (required to activate) EKS cluster name
#   AWS_ACCESS_KEY_ID       key-based auth
#   AWS_SECRET_ACCESS_KEY   key-based auth
#   AWS_SESSION_TOKEN       optional, for temporary/assumed-role credentials
#   AWS_REGION              cluster region (falls back to AWS_DEFAULT_REGION, then us-east-1)
#   AWS_PROFILE             named profile (ignored when key-based auth vars are set)
##############################################################################
setup_aws_account() {
    if [ -z "${AWS_CLUSTER_NAME:-}" ]; then
        return 0  # Nothing to do — kubectl already configured externally
    fi

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

    # Validate key-based auth: if one key var is set, both must be present
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ] || [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
            log ERROR "AWS_SECRET_ACCESS_KEY is set but AWS_ACCESS_KEY_ID is missing"
            exit 1
        fi
        if [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
            log ERROR "AWS_ACCESS_KEY_ID is set but AWS_SECRET_ACCESS_KEY is missing"
            exit 1
        fi
        log INFO "Using AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY for authentication"
        if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
            log INFO "AWS_SESSION_TOKEN detected — using temporary credentials"
        fi
    elif [ -n "${AWS_PROFILE:-}" ]; then
        log INFO "Using AWS profile: ${AWS_PROFILE}"
    fi

    log INFO "Configuring kubectl for EKS cluster '${AWS_CLUSTER_NAME}' in region '${region}'..."

    local update_cmd="aws eks update-kubeconfig --name \"${AWS_CLUSTER_NAME}\" --region \"${region}\""
    # Use profile only when not using explicit key-based auth
    if [ -n "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
        update_cmd+=" --profile \"${AWS_PROFILE}\""
    fi

    if ! eval "$update_cmd"; then
        log ERROR "Failed to configure kubectl for EKS cluster '${AWS_CLUSTER_NAME}'"
        log ERROR "Ensure AWS credentials are valid and the cluster exists in region '${region}'"
        exit 1
    fi

    log SUCCESS "kubectl configured for EKS cluster: ${AWS_CLUSTER_NAME}"
}

##############################################################################
# Function: create_eks_cluster
# Description: Creates an EKS cluster using eksctl if it does not already
#              exist. Only runs when --create-cluster is passed.
#              AWS_CLUSTER_NAME and AWS_REGION must be set (via setup_aws_account
#              env vars) before this is called.
#
# Env vars:
#   AWS_CLUSTER_NAME         (required) cluster name
#   AWS_REGION               cluster region (falls back to AWS_DEFAULT_REGION, us-east-1)
#   EKS_NODE_TYPE            EC2 instance type (default: m5.xlarge)
#   EKS_NODE_COUNT           number of managed nodes (default: 2)
#   EKS_KUBERNETES_VERSION   Kubernetes version (default: eksctl picks latest)
##############################################################################
create_eks_cluster() {
    if [ "$CREATE_CLUSTER" != true ]; then
        return 0
    fi

    if [ -z "${AWS_CLUSTER_NAME:-}" ]; then
        log ERROR "--create-cluster requires AWS_CLUSTER_NAME to be set"
        exit 1
    fi

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
    local node_type="${EKS_NODE_TYPE:-m5.xlarge}"
    local node_count="${EKS_NODE_COUNT:-2}"

    # Check if cluster already exists — skip creation if so
    if aws eks describe-cluster --name "$AWS_CLUSTER_NAME" --region "$region" &> /dev/null; then
        log INFO "EKS cluster '${AWS_CLUSTER_NAME}' already exists — skipping creation"
        return 0
    fi

    # Check for a leftover CloudFormation stack from a failed previous attempt.
    # eksctl names the cluster stack "eksctl-<cluster>-cluster".
    # Stacks in ROLLBACK_COMPLETE or *_FAILED states block re-creation (HTTP 400).
    local cf_stack="eksctl-${AWS_CLUSTER_NAME}-cluster"
    local stack_status
    stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$cf_stack" \
        --region "$region" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    if [ "$stack_status" != "DOES_NOT_EXIST" ] && [ "$stack_status" != "None" ]; then
        case "$stack_status" in
            ROLLBACK_COMPLETE|CREATE_FAILED|ROLLBACK_FAILED|DELETE_FAILED)
                log WARNING "Found leftover CloudFormation stack '${cf_stack}' in state '${stack_status}'"
                log INFO "Deleting stuck stack before retrying cluster creation..."
                if ! aws cloudformation delete-stack \
                    --stack-name "$cf_stack" \
                    --region "$region"; then
                    log ERROR "Failed to delete stuck CloudFormation stack '${cf_stack}'"
                    exit 1
                fi
                log INFO "Waiting for stack deletion to complete..."
                aws cloudformation wait stack-delete-complete \
                    --stack-name "$cf_stack" \
                    --region "$region" || true
                log SUCCESS "Stuck stack deleted — proceeding with cluster creation"
                ;;
            CREATE_COMPLETE|UPDATE_COMPLETE)
                # Stack exists and looks healthy but EKS describe failed — unusual state
                log WARNING "CloudFormation stack '${cf_stack}' exists (${stack_status}) but EKS cluster not found. Proceeding anyway."
                ;;
            *)
                log WARNING "CloudFormation stack '${cf_stack}' is in state '${stack_status}' — proceeding, eksctl will handle it"
                ;;
        esac
    fi

    log INFO "Creating EKS cluster '${AWS_CLUSTER_NAME}' in region '${region}'..."
    log INFO "Node type: ${node_type}, Node count: ${node_count} (min: 0, max: ${EKS_NODE_MAX:-10})"

    # Resolve engineer name for tagging (explicit ENGINEER env var or auto-detected)
    local engineer
    engineer=$(resolve_engineer)

    local created_at
    created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Base tags always applied
    local tags="CreatedBy=${engineer},CreatedAt=${created_at},Application=langsmith"

    # Cluster Autoscaler discovery tags — required for CA to find and manage this
    # node group and scale it down to 0 when idle.
    tags+=",k8s.io/cluster-autoscaler/enabled=true"
    tags+=",k8s.io/cluster-autoscaler/${AWS_CLUSTER_NAME}=owned"

    # Merge in any extra tags from EKS_TAGS (expected format: key=val,key2=val2)
    if [ -n "${EKS_TAGS:-}" ]; then
        tags="${tags},${EKS_TAGS}"
    fi

    log INFO "Resource tags: ${tags}"

    local create_cmd="eksctl create cluster"
    create_cmd+=" --name \"${AWS_CLUSTER_NAME}\""
    create_cmd+=" --region \"${region}\""
    create_cmd+=" --node-type \"${node_type}\""
    create_cmd+=" --nodes \"${node_count}\""
    create_cmd+=" --nodes-min 0"
    create_cmd+=" --nodes-max \"${EKS_NODE_MAX:-10}\""
    create_cmd+=" --with-oidc"
    create_cmd+=" --managed"
    create_cmd+=" --tags \"${tags}\""

    if [ -n "${EKS_KUBERNETES_VERSION:-}" ]; then
        create_cmd+=" --version \"${EKS_KUBERNETES_VERSION}\""
        log INFO "Kubernetes version: ${EKS_KUBERNETES_VERSION}"
    fi

    if [ -n "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
        create_cmd+=" --profile \"${AWS_PROFILE}\""
    fi

    log INFO "Executing: ${create_cmd}"
    if ! eval "$create_cmd"; then
        log ERROR "Failed to create EKS cluster '${AWS_CLUSTER_NAME}'"
        exit 1
    fi

    # Disable termination protection on all eksctl-created stacks so the cluster
    # can be torn down without manual intervention.
    log INFO "Disabling termination protection on cluster stacks..."
    local stack
    for stack in $(aws cloudformation list-stacks \
        --region "$region" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[?starts_with(StackName, 'eksctl-${AWS_CLUSTER_NAME}-')].StackName" \
        --output text 2>/dev/null); do
        aws cloudformation update-termination-protection \
            --no-enable-termination-protection \
            --stack-name "$stack" \
            --region "$region" &>/dev/null || true
        log INFO "  Termination protection disabled: ${stack}"
    done

    log SUCCESS "EKS cluster '${AWS_CLUSTER_NAME}' created successfully"
}

##############################################################################
# Function: get_nodegroup_name
# Description: Returns the node group name for the EKS cluster. Uses
#              EKS_NODEGROUP_NAME if set, otherwise auto-discovers the first
#              managed node group.
##############################################################################
get_nodegroup_name() {
    if [ -n "$EKS_NODEGROUP_NAME" ]; then
        echo "$EKS_NODEGROUP_NAME"
        return 0
    fi

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
    local ng
    ng=$(aws eks list-nodegroups \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --region "$region" \
        --query 'nodegroups[0]' \
        --output text 2>/dev/null || echo "")

    if [ -z "$ng" ] || [ "$ng" = "None" ]; then
        log ERROR "No node groups found for cluster '${AWS_CLUSTER_NAME}'"
        exit 1
    fi

    echo "$ng"
}

##############################################################################
# Function: pause_cluster
# Description: Scales the EKS node group to 0 to stop all worker nodes.
#              The cluster control plane remains running (no charge for nodes).
##############################################################################
pause_cluster() {
    if [ -z "${AWS_CLUSTER_NAME:-}" ]; then
        log ERROR "AWS_CLUSTER_NAME must be set to pause the cluster"
        exit 1
    fi

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
    local ng
    ng=$(get_nodegroup_name)

    log INFO "Pausing cluster '${AWS_CLUSTER_NAME}' — scaling node group '${ng}' to 0..."

    if ! aws eks update-nodegroup-config \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --nodegroup-name "$ng" \
        --region "$region" \
        --scaling-config "minSize=0,maxSize=${EKS_NODE_MAX:-10},desiredSize=0" \
        --output text &> /dev/null; then
        log ERROR "Failed to scale node group '${ng}' to 0"
        exit 1
    fi

    log INFO "Waiting for nodes to terminate..."
    aws eks wait nodegroup-active \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --nodegroup-name "$ng" \
        --region "$region" 2>/dev/null || true

    log SUCCESS "Cluster paused — all worker nodes scaled to 0"
    log INFO "To resume, run: $0 resume"
}

##############################################################################
# Function: resume_cluster
# Description: Scales the EKS node group back to EKS_NODE_COUNT (default 2).
##############################################################################
resume_cluster() {
    if [ -z "${AWS_CLUSTER_NAME:-}" ]; then
        log ERROR "AWS_CLUSTER_NAME must be set to resume the cluster"
        exit 1
    fi

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
    local ng
    ng=$(get_nodegroup_name)
    local node_count="${EKS_NODE_COUNT:-2}"

    log INFO "Resuming cluster '${AWS_CLUSTER_NAME}' — scaling node group '${ng}' to ${node_count}..."

    if ! aws eks update-nodegroup-config \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --nodegroup-name "$ng" \
        --region "$region" \
        --scaling-config "minSize=0,maxSize=${EKS_NODE_MAX:-10},desiredSize=${node_count}" \
        --output text &> /dev/null; then
        log ERROR "Failed to scale node group '${ng}' to ${node_count}"
        exit 1
    fi

    log INFO "Waiting for nodes to become ready (this may take a few minutes)..."
    aws eks wait nodegroup-active \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --nodegroup-name "$ng" \
        --region "$region" 2>/dev/null || true

    log SUCCESS "Cluster resumed — node group scaled to ${node_count}"
}

##############################################################################
# Function: add_scheduled_scaling
# Description: Adds ASG scheduled actions to warm the cluster at the start of
#              business hours and scale it to zero at the end. The timezone is
#              set to Europe/London so BST/GMT transitions are handled
#              automatically by AWS.
#
# Env vars:
#   AWS_CLUSTER_NAME       (required) EKS cluster name
#   AWS_REGION             cluster region
#   SCHEDULE_TIMEZONE      IANA timezone (default: Europe/London)
#   SCHEDULE_SCALE_UP      cron for scale-up  (default: "0 8 * * MON-FRI")
#   SCHEDULE_SCALE_DOWN    cron for scale-down (default: "0 18 * * MON-FRI")
#   EKS_NODE_COUNT         desired node count at scale-up (default: 2)
#   EKS_NODE_MAX           max nodes (default: 10)
##############################################################################
add_scheduled_scaling() {
    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
    local timezone="${SCHEDULE_TIMEZONE:-Europe/London}"
    local cron_up="${SCHEDULE_SCALE_UP:-0 8 * * MON-FRI}"
    local cron_down="${SCHEDULE_SCALE_DOWN:-0 18 * * MON-FRI}"
    local node_count="${EKS_NODE_COUNT:-2}"
    local node_max="${EKS_NODE_MAX:-10}"

    log INFO "Configuring scheduled scaling (timezone: ${timezone})"
    log INFO "  Scale up:   '${cron_up}' → ${node_count} nodes"
    log INFO "  Scale down: '${cron_down}' → 0 nodes"

    # Resolve ASG name from the node group
    local ng
    ng=$(get_nodegroup_name)

    local asg_name
    asg_name=$(aws eks describe-nodegroup \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --nodegroup-name "$ng" \
        --region "$region" \
        --query 'nodegroup.resources.autoScalingGroups[0].name' \
        --output text 2>/dev/null) || {
        log ERROR "Failed to resolve ASG name for node group '${ng}'"
        exit 1
    }

    if [ -z "$asg_name" ] || [ "$asg_name" = "None" ]; then
        log ERROR "Could not find ASG for node group '${ng}'"
        exit 1
    fi

    log INFO "ASG: ${asg_name}"

    # Scale-up action: set min=node_count so CA cannot scale below this during the day
    if ! aws autoscaling put-scheduled-update-group-action \
        --auto-scaling-group-name "$asg_name" \
        --scheduled-action-name "langsmith-scale-up-morning" \
        --recurrence "$cron_up" \
        --time-zone "$timezone" \
        --min-size 0 \
        --max-size "$node_max" \
        --desired-capacity "$node_count" \
        --region "$region"; then
        log ERROR "Failed to create scale-up scheduled action"
        exit 1
    fi

    # Scale-down action: set desired=0, min=0 so CA can drain fully overnight
    if ! aws autoscaling put-scheduled-update-group-action \
        --auto-scaling-group-name "$asg_name" \
        --scheduled-action-name "langsmith-scale-down-evening" \
        --recurrence "$cron_down" \
        --time-zone "$timezone" \
        --min-size 0 \
        --max-size "$node_max" \
        --desired-capacity 0 \
        --region "$region"; then
        log ERROR "Failed to create scale-down scheduled action"
        exit 1
    fi

    log SUCCESS "Scheduled scaling configured (${timezone})"
    log INFO "  Warm:  $(echo "$cron_up" | awk '{print $2}'):00 ${timezone} Mon–Fri"
    log INFO "  Sleep: $(echo "$cron_down" | awk '{print $2}'):00 ${timezone} Mon–Fri"
}

##############################################################################
# Function: install_cluster_autoscaler
# Description: Installs the Kubernetes Cluster Autoscaler into kube-system
#              via Helm with IRSA. Configured to scale node groups down to 0
#              when idle and back up when pods are pending.
#
# Env vars:
#   AWS_CLUSTER_NAME              (required) EKS cluster name
#   AWS_REGION                    cluster region
#   CA_SCALE_DOWN_UNNEEDED_TIME   idle time before scale-down (default: 10m)
#   CA_SCALE_DOWN_DELAY_AFTER_ADD delay after scale-up before scale-down
#                                 eligible (default: 10m)
##############################################################################
install_cluster_autoscaler() {
    log INFO "Installing Cluster Autoscaler..."

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
    local policy_name="ClusterAutoscalerIAMPolicy-${AWS_CLUSTER_NAME}"
    local account_id

    account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
        log ERROR "Failed to retrieve AWS account ID."
        exit 1
    }

    local policy_arn="arn:aws:iam::${account_id}:policy/${policy_name}"

    # Write IAM policy document inline (no external download required)
    local policy_file
    policy_file=$(mktemp)
    trap "rm -f '$policy_file'" RETURN

    cat > "$policy_file" << 'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": ["*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": ["*"]
    }
  ]
}
POLICY

    # Create IAM policy (skip if already exists)
    if aws iam get-policy --policy-arn "$policy_arn" &>/dev/null; then
        log INFO "IAM policy '${policy_name}' already exists — skipping creation"
    else
        log INFO "Creating IAM policy '${policy_name}'..."
        if ! aws iam create-policy \
            --policy-name "$policy_name" \
            --policy-document "file://${policy_file}" \
            --output text &>/dev/null; then
            log ERROR "Failed to create IAM policy '${policy_name}'"
            exit 1
        fi
        log SUCCESS "IAM policy created: ${policy_arn}"
    fi

    # Create IRSA service account — skip if already healthy, clean up if stuck
    local ca_stack="eksctl-${AWS_CLUSTER_NAME}-addon-iamserviceaccount-kube-system-cluster-autoscaler"
    local ca_stack_status
    ca_stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$ca_stack" --region "$region" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$ca_stack_status" = "CREATE_COMPLETE" ] || [ "$ca_stack_status" = "UPDATE_COMPLETE" ]; then
        log INFO "IRSA service account for Cluster Autoscaler already exists — skipping"
    else
        if [ "$ca_stack_status" = "ROLLBACK_COMPLETE" ] || [ "$ca_stack_status" = "CREATE_FAILED" ] \
            || [ "$ca_stack_status" = "ROLLBACK_FAILED" ] || [ "$ca_stack_status" = "DELETE_FAILED" ]; then
            log WARNING "CA IRSA stack is stuck in '${ca_stack_status}' — deleting before retry..."
            aws cloudformation delete-stack --stack-name "$ca_stack" --region "$region" || true
            aws cloudformation wait stack-delete-complete --stack-name "$ca_stack" --region "$region" || true
            log INFO "Stuck stack deleted — recreating IAM service account..."
        fi

        log INFO "Creating IAM service account for Cluster Autoscaler..."
        local sa_cmd="eksctl create iamserviceaccount"
        sa_cmd+=" --cluster \"${AWS_CLUSTER_NAME}\""
        sa_cmd+=" --region \"${region}\""
        sa_cmd+=" --namespace kube-system"
        sa_cmd+=" --name cluster-autoscaler"
        sa_cmd+=" --attach-policy-arn \"${policy_arn}\""
        sa_cmd+=" --override-existing-serviceaccounts"
        sa_cmd+=" --approve"

        if [ -n "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
            sa_cmd+=" --profile \"${AWS_PROFILE}\""
        fi

        if ! eval "$sa_cmd"; then
            log ERROR "Failed to create IAM service account for Cluster Autoscaler"
            log ERROR "Check CloudFormation console for stack: ${ca_stack}"
            exit 1
        fi
        aws cloudformation update-termination-protection \
            --no-enable-termination-protection \
            --stack-name "$ca_stack" --region "$region" &>/dev/null || true
    fi

    # Resolve the IRSA role ARN for the Helm annotation
    local irsa_role_arn
    irsa_role_arn=$(aws iam get-role \
        --role-name "eksctl-${AWS_CLUSTER_NAME}-addon-iamserviceaccount-kube-system-cluster-autoscaler" \
        --query 'Role.Arn' --output text 2>/dev/null || echo "")

    helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || true
    helm repo update autoscaler 2>/dev/null || true

    local scale_down_unneeded="${CA_SCALE_DOWN_UNNEEDED_TIME:-10m}"
    local scale_down_delay="${CA_SCALE_DOWN_DELAY_AFTER_ADD:-10m}"

    log INFO "Scale-down config: unneeded=${scale_down_unneeded}, delay-after-add=${scale_down_delay}"

    local helm_cmd="helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler"
    helm_cmd+=" -n kube-system"
    helm_cmd+=" --set autoDiscovery.clusterName=\"${AWS_CLUSTER_NAME}\""
    helm_cmd+=" --set awsRegion=\"${region}\""
    helm_cmd+=" --set rbac.serviceAccount.create=false"
    helm_cmd+=" --set rbac.serviceAccount.name=cluster-autoscaler"
    helm_cmd+=" --set extraArgs.scale-down-enabled=true"
    helm_cmd+=" --set extraArgs.scale-down-unneeded-time=${scale_down_unneeded}"
    helm_cmd+=" --set extraArgs.scale-down-delay-after-add=${scale_down_delay}"
    helm_cmd+=" --set extraArgs.skip-nodes-with-system-pods=false"
    helm_cmd+=" --set extraArgs.balance-similar-node-groups=true"
    helm_cmd+=" --set extraArgs.expander=least-waste"
    helm_cmd+=" --wait --timeout 5m"

    if [ -n "$irsa_role_arn" ]; then
        helm_cmd+=" --set rbac.serviceAccount.annotations.\"eks\\.amazonaws\\.com/role-arn\"=\"${irsa_role_arn}\""
    fi

    if ! eval "$helm_cmd"; then
        log ERROR "Failed to install Cluster Autoscaler"
        exit 1
    fi

    log SUCCESS "Cluster Autoscaler installed — nodes will scale to 0 after ${scale_down_unneeded} idle"
}

##############################################################################
# Function: install_ebs_csi_driver
# Description: Installs the AWS EBS CSI driver as an EKS managed addon.
#              Required for PersistentVolumeClaims (used by ClickHouse).
#              Without this, ClickHouse StatefulSets stay Pending indefinitely.
##############################################################################
install_ebs_csi_driver() {
    log INFO "Installing AWS EBS CSI driver addon..."

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

    # Check if addon is already active
    local addon_status
    addon_status=$(aws eks describe-addon \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --addon-name aws-ebs-csi-driver \
        --region "$region" \
        --query 'addon.status' \
        --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$addon_status" = "ACTIVE" ]; then
        log INFO "EBS CSI driver already active — skipping"
        return 0
    fi

    if ! eksctl create addon \
        --name aws-ebs-csi-driver \
        --cluster "$AWS_CLUSTER_NAME" \
        --region "$region" \
        --force; then
        log ERROR "Failed to install EBS CSI driver addon"
        exit 1
    fi

    # Wait for addon to become active
    log INFO "Waiting for EBS CSI driver to become active..."
    aws eks wait addon-active \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --addon-name aws-ebs-csi-driver \
        --region "$region" || true

    log SUCCESS "EBS CSI driver installed — PersistentVolumeClaims can now be provisioned"

    # Create gp3 StorageClass using the CSI driver and mark it as the cluster default.
    # Without a default StorageClass, StatefulSet PVCs (ClickHouse, Postgres, Redis)
    # remain Pending indefinitely.
    log INFO "Creating gp3 StorageClass (default)..."
    kubectl apply -f - <<'STORAGECLASS'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
STORAGECLASS

    log SUCCESS "gp3 StorageClass created and set as cluster default"
}

##############################################################################
# Function: install_alb_controller
# Description: Installs the AWS Load Balancer Controller into kube-system via
#              Helm. Creates the required IAM policy and IRSA service account
#              using eksctl. Idempotent — skips steps that already exist.
#
# Env vars:
#   AWS_CLUSTER_NAME   (required) EKS cluster name
#   AWS_REGION         cluster region (falls back to us-east-1)
##############################################################################
install_alb_controller() {
    log INFO "Installing AWS Load Balancer Controller..."

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
    local policy_name="AWSLoadBalancerControllerIAMPolicy"
    local account_id

    account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
        log ERROR "Failed to retrieve AWS account ID. Ensure AWS credentials are valid."
        exit 1
    }

    local policy_arn="arn:aws:iam::${account_id}:policy/${policy_name}"

    # Download IAM policy document
    local policy_file
    policy_file=$(mktemp)
    trap "rm -f '$policy_file'" RETURN

    log INFO "Downloading IAM policy document for ALB controller..."
    if ! curl -sSf \
        "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json" \
        -o "$policy_file"; then
        log ERROR "Failed to download ALB controller IAM policy. Check internet connectivity."
        exit 1
    fi

    # Create IAM policy (skip if already exists)
    if aws iam get-policy --policy-arn "$policy_arn" &>/dev/null; then
        log INFO "IAM policy '${policy_name}' already exists — skipping creation"
    else
        log INFO "Creating IAM policy '${policy_name}'..."
        if ! aws iam create-policy \
            --policy-name "$policy_name" \
            --policy-document "file://${policy_file}" \
            --output text &>/dev/null; then
            log ERROR "Failed to create IAM policy '${policy_name}'"
            exit 1
        fi
        log SUCCESS "IAM policy created: ${policy_arn}"
    fi

    # Create IRSA service account — skip if already healthy, clean up if stuck
    local alb_stack="eksctl-${AWS_CLUSTER_NAME}-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
    local alb_stack_status
    alb_stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$alb_stack" --region "$region" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$alb_stack_status" = "CREATE_COMPLETE" ] || [ "$alb_stack_status" = "UPDATE_COMPLETE" ]; then
        log INFO "IRSA service account for ALB controller already exists — skipping"
    else
        if [ "$alb_stack_status" = "ROLLBACK_COMPLETE" ] || [ "$alb_stack_status" = "CREATE_FAILED" ] \
            || [ "$alb_stack_status" = "ROLLBACK_FAILED" ] || [ "$alb_stack_status" = "DELETE_FAILED" ]; then
            log WARNING "ALB IRSA stack is stuck in '${alb_stack_status}' — deleting before retry..."
            aws cloudformation delete-stack --stack-name "$alb_stack" --region "$region" || true
            aws cloudformation wait stack-delete-complete --stack-name "$alb_stack" --region "$region" || true
            log INFO "Stuck stack deleted — recreating IAM service account..."
        fi

        log INFO "Creating IAM service account for ALB controller (this may take a minute)..."
        local sa_cmd="eksctl create iamserviceaccount"
        sa_cmd+=" --cluster \"${AWS_CLUSTER_NAME}\""
        sa_cmd+=" --region \"${region}\""
        sa_cmd+=" --namespace kube-system"
        sa_cmd+=" --name aws-load-balancer-controller"
        sa_cmd+=" --attach-policy-arn \"${policy_arn}\""
        sa_cmd+=" --override-existing-serviceaccounts"
        sa_cmd+=" --approve"

        if [ -n "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
            sa_cmd+=" --profile \"${AWS_PROFILE}\""
        fi

        if ! eval "$sa_cmd"; then
            log ERROR "Failed to create IAM service account for ALB controller"
            log ERROR "Check CloudFormation console for stack: ${alb_stack}"
            exit 1
        fi
        aws cloudformation update-termination-protection \
            --no-enable-termination-protection \
            --stack-name "$alb_stack" --region "$region" &>/dev/null || true
    fi

    # Add EKS Helm chart repository
    helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
    helm repo update eks 2>/dev/null || true

    # Install or upgrade the controller
    log INFO "Installing AWS Load Balancer Controller via Helm..."
    if ! helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set "clusterName=${AWS_CLUSTER_NAME}" \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --wait \
        --timeout 5m; then
        log ERROR "Failed to install AWS Load Balancer Controller"
        exit 1
    fi

    log SUCCESS "AWS Load Balancer Controller installed successfully"
}

##############################################################################
# Function: setup_cluster
# Description: Orchestrates full EKS cluster setup:
#                1. Validates required env vars
#                2. Creates EKS cluster (via eksctl)
#                3. Configures kubectl (aws eks update-kubeconfig)
#                4. Installs AWS Load Balancer Controller
#                5. Prints next-step instructions
##############################################################################
setup_cluster() {
    echo ""
    echo "=========================================================================="
    echo -e "${BLUE}EKS Cluster Setup${NC}"
    echo "=========================================================================="
    echo ""

    # Validate required env vars upfront
    local errors=0

    if [ -z "${AWS_CLUSTER_NAME:-}" ]; then
        log ERROR "AWS_CLUSTER_NAME is required for 'setup'. Set it and re-run."
        errors=$((errors + 1))
    fi

    # Require at least one form of auth
    local has_keys=false
    local has_profile=false
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        has_keys=true
    fi
    if [ -n "${AWS_PROFILE:-}" ]; then
        has_profile=true
    fi
    if [ "$has_keys" = false ] && [ "$has_profile" = false ]; then
        log ERROR "AWS credentials are required. Set one of:"
        log ERROR "  - AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY"
        log ERROR "  - AWS_PROFILE"
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        exit 1
    fi

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
    local node_type="${EKS_NODE_TYPE:-m5.xlarge}"
    local node_count="${EKS_NODE_COUNT:-2}"
    local node_max="${EKS_NODE_MAX:-10}"
    local k8s_version="${EKS_KUBERNETES_VERSION:-latest}"

    local engineer
    engineer=$(resolve_engineer)

    echo -e "${BLUE}Cluster configuration:${NC}"
    echo -e "  Name:             ${GREEN}${AWS_CLUSTER_NAME}${NC}"
    echo -e "  Region:           ${GREEN}${region}${NC}"
    echo -e "  Node type:        ${GREEN}${node_type}${NC}"
    echo -e "  Initial nodes:    ${GREEN}${node_count}${NC} (min: 0, max: ${node_max})"
    echo -e "  Kubernetes:       ${GREEN}${k8s_version}${NC}"
    echo -e "  Engineer tag:     ${GREEN}${engineer}${NC}"
    echo -e "  Scale-down idle:  ${GREEN}${CA_SCALE_DOWN_UNNEEDED_TIME:-10m}${NC} (CA_SCALE_DOWN_UNNEEDED_TIME)"
    echo -e "  Scale-down delay: ${GREEN}${CA_SCALE_DOWN_DELAY_AFTER_ADD:-10m}${NC} (CA_SCALE_DOWN_DELAY_AFTER_ADD)"
    echo -e "  Schedule up:      ${GREEN}${SCHEDULE_SCALE_UP:-0 8 * * MON-FRI}${NC} ${SCHEDULE_TIMEZONE:-Europe/London}"
    echo -e "  Schedule down:    ${GREEN}${SCHEDULE_SCALE_DOWN:-0 18 * * MON-FRI}${NC} ${SCHEDULE_TIMEZONE:-Europe/London}"
    if [ -n "${EKS_TAGS:-}" ]; then
        echo -e "  Extra tags:       ${GREEN}${EKS_TAGS}${NC}"
    fi
    echo ""

    # Step 1: Activate Cost Allocation Tags (account-level, best-effort)
    echo -e "${BLUE}Step 1/8: Activating Cost Allocation Tags...${NC}"
    activate_cost_allocation_tags

    # Step 2: Create EKS cluster
    echo ""
    echo -e "${BLUE}Step 2/8: Creating EKS cluster...${NC}"
    CREATE_CLUSTER=true
    create_eks_cluster

    # Step 3: Configure kubectl
    echo ""
    echo -e "${BLUE}Step 3/8: Configuring kubectl...${NC}"
    setup_aws_account

    # Step 4: Install EBS CSI driver (required for ClickHouse PersistentVolumeClaims)
    echo ""
    echo -e "${BLUE}Step 4/8: Installing EBS CSI driver...${NC}"
    install_ebs_csi_driver

    # Step 5: Install AWS Load Balancer Controller
    echo ""
    echo -e "${BLUE}Step 5/8: Installing AWS Load Balancer Controller...${NC}"
    install_alb_controller

    # Step 6: Install Cluster Autoscaler (scale to 0 when idle)
    echo ""
    echo -e "${BLUE}Step 6/8: Installing Cluster Autoscaler (scale-to-zero)...${NC}"
    install_cluster_autoscaler

    # Step 7: Install CloudWatch Container Insights (opt-in via --cloudwatch)
    if [ "$CLOUDWATCH" = true ]; then
        echo ""
        echo -e "${BLUE}Step 7/8: Installing CloudWatch Container Insights...${NC}"
        install_cloudwatch_observability
    else
        echo ""
        log INFO "Skipping CloudWatch Container Insights (pass --cloudwatch to enable, ~\$15/mo)"
    fi

    # Step 8: Add scheduled scaling for business hours
    echo ""
    echo -e "${BLUE}Step 8/8: Configuring scheduled scaling (UK business hours)...${NC}"
    add_scheduled_scaling

    echo ""
    echo "=========================================================================="
    echo -e "${GREEN}Cluster setup complete!${NC}"
    echo "=========================================================================="
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo ""
    echo -e "  1. Fill in your LangSmith credentials:"
    echo -e "     ${GREEN}cp ${CONFIG_DIR}/.env.example ${CONFIG_DIR}/.env${NC}"
    echo -e "     ${GREEN}\$EDITOR ${CONFIG_DIR}/.env${NC}"
    echo -e "     Required: LicenseKey, initialOrgAdminEmail"
    echo ""
    echo -e "  2. Deploy LangSmith:"
    echo -e "     ${GREEN}$0 up -l${NC}"
    echo ""
    echo -e "  3. When done, pause to stop billing for worker nodes:"
    echo -e "     ${GREEN}$0 pause${NC}"
    echo ""
    echo "=========================================================================="
    echo ""
}

##############################################################################
# Function: resolve_engineer
# Description: Returns the engineer name for tagging. Uses the ENGINEER env
#              var if set; otherwise extracts the session name from the AWS
#              caller identity ARN. Warns when falling back to auto-detection
#              so it is visible in CI/CD logs.
##############################################################################
resolve_engineer() {
    # Sanitize a tag value: replace chars not allowed by CloudFormation with '-'
    # CloudFormation tag values: [a-zA-Z0-9_.:/=+\-@] only (no spaces, no &<>, etc.)
    _sanitize_tag() {
        echo "$1" | sed 's/[^a-zA-Z0-9_.:/=+@-]/-/g'
    }

    if [ -n "${ENGINEER:-}" ]; then
        _sanitize_tag "$ENGINEER"
        return 0
    fi

    local arn
    arn=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo "")
    local detected
    detected=$(echo "$arn" | sed 's|.*/||')

    if [ -z "$detected" ] || [ "$detected" = "$arn" ]; then
        log WARNING "ENGINEER env var not set and AWS identity could not be resolved — tagging as 'unknown'" >&2
        echo "unknown"
    else
        local sanitized
        sanitized=$(_sanitize_tag "$detected")
        log WARNING "ENGINEER not set — using auto-detected identity: '${sanitized}'. Set ENGINEER=<name> to be explicit." >&2
        echo "$sanitized"
    fi
}

##############################################################################
# Function: activate_cost_allocation_tags
# Description: Activates the Cost Allocation Tags used by this script so they
#              appear in AWS Cost Explorer and billing reports. This is an
#              account-level, one-time operation — safe to re-run (idempotent).
#
#              Tags activated: CreatedBy, Application, Engineer
#
#              Requires ce:UpdateCostAllocationTagsStatus. If the caller lacks
#              this permission (common with PowerUserAccess / developer roles),
#              the function logs a warning and continues — it does NOT fail the
#              setup. An admin can activate the tags manually in:
#              AWS Billing → Cost Allocation Tags
##############################################################################
activate_cost_allocation_tags() {
    log INFO "Activating Cost Allocation Tags (CreatedBy, Application, Engineer)..."

    local tags_json
    tags_json='[
        {"TagKey":"CreatedBy","Status":"Active"},
        {"TagKey":"Application","Status":"Active"},
        {"TagKey":"Engineer","Status":"Active"}
    ]'

    if aws ce update-cost-allocation-tags-status \
        --cost-allocation-tags-status "$tags_json" \
        --output text &>/dev/null 2>&1; then
        log SUCCESS "Cost Allocation Tags activated — tags will appear in Cost Explorer within 24 h"
    else
        log WARNING "Could not activate Cost Allocation Tags (requires ce:UpdateCostAllocationTagsStatus / billing-admin permissions)"
        log WARNING "Ask an AWS account admin to activate 'CreatedBy', 'Application', and 'Engineer' in:"
        log WARNING "  AWS Console → Billing → Cost Allocation Tags"
    fi
}

##############################################################################
# Function: install_cloudwatch_observability
# Description: Installs the amazon-cloudwatch-observability EKS addon, which
#              ships Container Insights metrics (CPU, memory, network per pod
#              and node) and logs to CloudWatch. Attaches
#              CloudWatchAgentServerPolicy to the managed node role so no
#              separate IRSA is required.
#
#              Metrics appear in CloudWatch under /aws/containerinsights/<cluster>.
#              Tag-based cost attribution requires activating the 'CreatedBy'
#              and 'Application' tags as Cost Allocation Tags in the AWS
#              Billing console (one-time manual step).
##############################################################################
install_cloudwatch_observability() {
    log INFO "Installing CloudWatch Container Insights (amazon-cloudwatch-observability)..."

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

    # Check if addon is already active
    local addon_status
    addon_status=$(aws eks describe-addon \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --addon-name amazon-cloudwatch-observability \
        --region "$region" \
        --query 'addon.status' \
        --output text 2>/dev/null || echo "NOT_FOUND")

    # Attach CloudWatchAgentServerPolicy to the node role so the addon can
    # write metrics and logs without a separate IRSA service account.
    local ng
    ng=$(get_nodegroup_name)
    local node_role_arn
    node_role_arn=$(aws eks describe-nodegroup \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --nodegroup-name "$ng" \
        --region "$region" \
        --query 'nodegroup.nodeRole' \
        --output text 2>/dev/null || echo "")

    if [ -n "$node_role_arn" ] && [ "$node_role_arn" != "None" ]; then
        local node_role_name
        node_role_name=$(basename "$node_role_arn")
        log INFO "Attaching CloudWatchAgentServerPolicy to node role '${node_role_name}'..."
        aws iam attach-role-policy \
            --role-name "$node_role_name" \
            --policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy" 2>/dev/null || true
    else
        log WARNING "Could not resolve node role — CloudWatch policy attachment skipped"
    fi

    if [ "$addon_status" = "ACTIVE" ]; then
        log INFO "CloudWatch observability addon already active — skipping install"
        return 0
    fi

    if ! aws eks create-addon \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --addon-name amazon-cloudwatch-observability \
        --region "$region" \
        --output text &>/dev/null; then
        log ERROR "Failed to install amazon-cloudwatch-observability addon"
        exit 1
    fi

    log INFO "Waiting for CloudWatch observability addon to become active..."
    aws eks wait addon-active \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --addon-name amazon-cloudwatch-observability \
        --region "$region" || true

    log SUCCESS "CloudWatch Container Insights installed"
    log INFO "Metrics available at: CloudWatch → Container Insights → ${AWS_CLUSTER_NAME}"
    log INFO "Log groups: /aws/containerinsights/${AWS_CLUSTER_NAME}/{application,dataplane,host}"
}

##############################################################################
# Function: install_addons
# Description: Installs/updates all cluster addons on an existing EKS cluster:
#              EBS CSI driver, AWS Load Balancer Controller, Cluster Autoscaler,
#              CloudWatch Container Insights, and scheduled scaling.
#              Safe to re-run — all steps are idempotent.
##############################################################################
install_addons() {
    if [ -z "${AWS_CLUSTER_NAME:-}" ]; then
        log ERROR "AWS_CLUSTER_NAME must be set to install addons"
        exit 1
    fi

    echo ""
    echo "=========================================================================="
    echo -e "${BLUE}Installing cluster addons on '${AWS_CLUSTER_NAME}'${NC}"
    echo -e "Engineer: ${GREEN}$(resolve_engineer)${NC}"
    echo "=========================================================================="
    echo ""

    setup_aws_account

    # Helm-based addons require schedulable nodes — scale up automatically if at zero
    ensure_nodes_ready

    echo -e "${BLUE}[1/5] EBS CSI driver...${NC}"
    install_ebs_csi_driver

    echo ""
    echo -e "${BLUE}[2/5] AWS Load Balancer Controller...${NC}"
    install_alb_controller

    echo ""
    echo -e "${BLUE}[3/5] Cluster Autoscaler...${NC}"
    install_cluster_autoscaler

    echo ""
    if [ "$CLOUDWATCH" = true ]; then
        echo -e "${BLUE}[4/5] CloudWatch Container Insights...${NC}"
        install_cloudwatch_observability
    else
        log INFO "[4/5] Skipping CloudWatch Container Insights (pass --cloudwatch to enable, ~\$15/mo)"
    fi

    echo ""
    echo -e "${BLUE}[5/5] Scheduled scaling...${NC}"
    add_scheduled_scaling

    echo ""
    echo "=========================================================================="
    echo -e "${GREEN}All addons installed successfully${NC}"
    echo "=========================================================================="
    echo ""
}

##############################################################################
# Function: upgrade_cluster
# Description: Upgrades the EKS control plane, managed node groups, and all
#              addons to the next Kubernetes minor version (or a specified one).
#              EKS only allows upgrading one minor version at a time.
#
# Env vars:
#   AWS_CLUSTER_NAME         (required) EKS cluster name
#   AWS_REGION               cluster region
#   EKS_KUBERNETES_VERSION   target version (default: current + 1 minor)
##############################################################################
upgrade_cluster() {
    if [ -z "${AWS_CLUSTER_NAME:-}" ]; then
        log ERROR "AWS_CLUSTER_NAME must be set to upgrade"
        exit 1
    fi

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

    # Determine current and target versions
    local current_version
    current_version=$(aws eks describe-cluster \
        --name "$AWS_CLUSTER_NAME" \
        --region "$region" \
        --query 'cluster.version' \
        --output text)

    local target_version="${EKS_KUBERNETES_VERSION:-}"
    if [ -z "$target_version" ]; then
        local minor
        minor=$(echo "$current_version" | cut -d. -f2)
        target_version="1.$((minor + 1))"
    fi

    # Validate: EKS only allows single minor version increments
    local current_minor target_minor
    current_minor=$(echo "$current_version" | cut -d. -f2)
    target_minor=$(echo "$target_version" | cut -d. -f2)
    if [ $((target_minor - current_minor)) -gt 1 ]; then
        log ERROR "EKS only supports upgrading one minor version at a time"
        log ERROR "Current: ${current_version}, Target: ${target_version}"
        log ERROR "Upgrade to 1.$((current_minor + 1)) first"
        exit 1
    fi

    echo ""
    echo "=========================================================================="
    echo -e "${BLUE}EKS Cluster Upgrade${NC}"
    echo "=========================================================================="
    echo ""
    echo -e "  Cluster:  ${GREEN}${AWS_CLUSTER_NAME}${NC}"
    echo -e "  From:     ${YELLOW}${current_version}${NC}"
    echo -e "  To:       ${GREEN}${target_version}${NC}"
    echo ""
    echo -e "${YELLOW}WARNING: This cannot be reversed. Ensure you have a backup.${NC}"
    echo ""
    read -r -p "Continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log INFO "Upgrade cancelled"
        exit 0
    fi

    # Step 1: Upgrade control plane
    echo ""
    echo -e "${BLUE}Step 1/4: Upgrading EKS control plane to ${target_version}...${NC}"
    log INFO "This typically takes 10–20 minutes"

    if ! aws eks update-cluster-version \
        --name "$AWS_CLUSTER_NAME" \
        --region "$region" \
        --kubernetes-version "$target_version" \
        --output text &>/dev/null; then
        log ERROR "Failed to initiate control plane upgrade"
        exit 1
    fi

    log INFO "Waiting for control plane upgrade to complete..."
    aws eks wait cluster-active \
        --name "$AWS_CLUSTER_NAME" \
        --region "$region"
    log SUCCESS "Control plane upgraded to ${target_version}"

    # Step 2: Upgrade managed node groups
    echo ""
    echo -e "${BLUE}Step 2/4: Upgrading node groups...${NC}"

    local nodegroups
    nodegroups=$(aws eks list-nodegroups \
        --cluster-name "$AWS_CLUSTER_NAME" \
        --region "$region" \
        --query 'nodegroups[]' \
        --output text)

    for ng in $nodegroups; do
        log INFO "Upgrading node group: ${ng}"
        if ! aws eks update-nodegroup-version \
            --cluster-name "$AWS_CLUSTER_NAME" \
            --nodegroup-name "$ng" \
            --region "$region" \
            --output text &>/dev/null; then
            log WARNING "Failed to initiate upgrade for node group '${ng}' — skipping"
            continue
        fi
        log INFO "Waiting for node group '${ng}' to finish upgrading..."
        aws eks wait nodegroup-active \
            --cluster-name "$AWS_CLUSTER_NAME" \
            --nodegroup-name "$ng" \
            --region "$region"
        log SUCCESS "Node group '${ng}' upgraded"
    done

    # Step 3: Update EBS CSI managed addon to latest compatible version
    echo ""
    echo -e "${BLUE}Step 3/4: Updating EBS CSI driver addon...${NC}"

    local latest_ebs_version
    latest_ebs_version=$(aws eks describe-addon-versions \
        --addon-name aws-ebs-csi-driver \
        --kubernetes-version "$target_version" \
        --region "$region" \
        --query 'addons[0].addonVersions[0].addonVersion' \
        --output text 2>/dev/null || echo "")

    if [ -n "$latest_ebs_version" ] && [ "$latest_ebs_version" != "None" ]; then
        aws eks update-addon \
            --cluster-name "$AWS_CLUSTER_NAME" \
            --addon-name aws-ebs-csi-driver \
            --addon-version "$latest_ebs_version" \
            --region "$region" \
            --output text &>/dev/null || true
        aws eks wait addon-active \
            --cluster-name "$AWS_CLUSTER_NAME" \
            --addon-name aws-ebs-csi-driver \
            --region "$region" || true
        log SUCCESS "EBS CSI driver updated to ${latest_ebs_version}"
    else
        log WARNING "Could not determine latest EBS CSI version for ${target_version} — skipping"
    fi

    # Step 4: Update Helm-based addons (ALB controller, Cluster Autoscaler)
    echo ""
    echo -e "${BLUE}Step 4/4: Updating Helm addons...${NC}"

    helm repo update eks autoscaler 2>/dev/null || true

    if helm status aws-load-balancer-controller -n kube-system &>/dev/null; then
        log INFO "Updating AWS Load Balancer Controller..."
        helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
            -n kube-system \
            --reuse-values \
            --wait --timeout 5m || log WARNING "ALB controller update failed — may need manual attention"
        log SUCCESS "AWS Load Balancer Controller updated"
    fi

    if helm status cluster-autoscaler -n kube-system &>/dev/null; then
        log INFO "Updating Cluster Autoscaler..."
        helm upgrade cluster-autoscaler autoscaler/cluster-autoscaler \
            -n kube-system \
            --reuse-values \
            --wait --timeout 5m || log WARNING "Cluster Autoscaler update failed — may need manual attention"
        log SUCCESS "Cluster Autoscaler updated"
    fi

    echo ""
    echo "=========================================================================="
    echo -e "${GREEN}Cluster upgrade to ${target_version} complete!${NC}"
    echo "=========================================================================="
    echo ""
    echo -e "  Verify: ${GREEN}kubectl get nodes${NC}"
    echo -e "  Verify: ${GREEN}kubectl get pods -n kube-system${NC}"
    echo ""
}

##############################################################################
# Function: teardown_cluster
# Description: Permanently deletes the EKS cluster and all associated AWS
#              resources: node groups, IRSA stacks, IAM policies, and the
#              cluster CloudFormation stack itself.
#
#              Requires confirmation — prints a summary and prompts before
#              doing anything destructive.
##############################################################################
teardown_cluster() {
    if [ -z "${AWS_CLUSTER_NAME:-}" ]; then
        log ERROR "AWS_CLUSTER_NAME must be set to run teardown"
        exit 1
    fi

    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

    echo ""
    echo "=========================================================================="
    echo -e "${RED}Cluster Teardown — PERMANENT DELETION${NC}"
    echo "=========================================================================="
    echo ""
    echo -e "  Cluster:  ${RED}${AWS_CLUSTER_NAME}${NC}"
    echo -e "  Region:   ${RED}${region}${NC}"
    echo ""
    echo -e "${RED}This will permanently delete the EKS cluster and ALL associated"
    echo -e "AWS resources (nodes, load balancers, IAM roles, CloudFormation stacks).${NC}"
    echo -e "${RED}This cannot be undone.${NC}"
    echo ""
    printf "Type the cluster name to confirm: "
    read -r confirm
    if [ "$confirm" != "$AWS_CLUSTER_NAME" ]; then
        log INFO "Confirmation did not match — teardown cancelled"
        exit 0
    fi

    # Disable termination protection on all eksctl stacks first
    log INFO "Disabling termination protection on all eksctl stacks..."
    local stack
    for stack in $(aws cloudformation list-stacks \
        --region "$region" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[?starts_with(StackName, 'eksctl-${AWS_CLUSTER_NAME}-')].StackName" \
        --output text 2>/dev/null); do
        aws cloudformation update-termination-protection \
            --no-enable-termination-protection \
            --stack-name "$stack" --region "$region" &>/dev/null || true
        log INFO "  Termination protection disabled: ${stack}"
    done

    # Delete the cluster (eksctl handles node groups, IRSA stacks, and the cluster stack)
    log INFO "Deleting EKS cluster '${AWS_CLUSTER_NAME}' (this takes 10–15 minutes)..."
    if ! eksctl delete cluster \
        --name "$AWS_CLUSTER_NAME" \
        --region "$region" \
        --wait; then
        log ERROR "eksctl delete cluster failed — check CloudFormation console for stuck stacks"
        exit 1
    fi

    # Clean up the shared ALB controller IAM policy (not cluster-specific)
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    if [ -n "$account_id" ]; then
        local policy_arn="arn:aws:iam::${account_id}:policy/AWSLoadBalancerControllerIAMPolicy"
        if aws iam get-policy --policy-arn "$policy_arn" &>/dev/null; then
            log INFO "Deleting ALB controller IAM policy..."
            aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null || \
                log WARNING "Could not delete ALB policy (may be in use by another cluster)"
        fi
    fi

    echo ""
    echo "=========================================================================="
    echo -e "${GREEN}Teardown complete — cluster '${AWS_CLUSTER_NAME}' deleted${NC}"
    echo "=========================================================================="
    echo ""
}

##############################################################################
# Function: parse_arguments
# Description: Parses command line arguments
##############################################################################
parse_arguments() {
    if [ $# -eq 0 ]; then
        show_usage
    fi
    
    # First argument should be action
    case "$1" in
        setup|addons|upgrade|teardown|up|down|status|pause|resume)
            ACTION="$1"
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log ERROR "Invalid action: $1"
            show_usage
            ;;
    esac
    
    # 'setup' accepts an optional positional cluster name (overrides AWS_CLUSTER_NAME)
    if [ "$ACTION" = "setup" ] && [ $# -gt 0 ] && [[ "$1" != -* ]]; then
        AWS_CLUSTER_NAME="$1"
        export AWS_CLUSTER_NAME
        shift
    fi

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
            --skip-checks)
                SKIP_CHECKS=true
                shift
                ;;
            --cloudwatch)
                CLOUDWATCH=true
                shift
                ;;
            --tz)
                if [ $# -lt 2 ]; then
                    log ERROR "--tz option requires a timezone argument"
                    show_usage
                fi
                case "$2" in
                    london|Europe/London)     SCHEDULE_TIMEZONE="Europe/London" ;;
                    amsterdam|Europe/Amsterdam) SCHEDULE_TIMEZONE="Europe/Amsterdam" ;;
                    newyork|new-york|America/New_York) SCHEDULE_TIMEZONE="America/New_York" ;;
                    california|la|America/Los_Angeles) SCHEDULE_TIMEZONE="America/Los_Angeles" ;;
                    *)
                        # Accept any raw IANA timezone (e.g. America/Chicago)
                        SCHEDULE_TIMEZONE="$2"
                        ;;
                esac
                export SCHEDULE_TIMEZONE
                shift 2
                ;;
            --create-cluster)
                CREATE_CLUSTER=true
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
    
    # pause/resume require AWS_CLUSTER_NAME
    if [ "$ACTION" = "pause" ] || [ "$ACTION" = "resume" ]; then
        if [ -z "${AWS_CLUSTER_NAME:-}" ]; then
            log ERROR "pause/resume require AWS_CLUSTER_NAME to be set"
            exit 1
        fi
    fi

    # For 'down' action, remove both regardless of flags
    if [ "$ACTION" = "down" ]; then
        INSTALL_LS=true
        INSTALL_LD=true
        log INFO "Down action will remove both LangSmith and LangSmith Deployment"
    fi
    
    # Skip verbose logging for status/pause/resume/setup actions
    if [ "$ACTION" != "status" ] && [ "$ACTION" != "pause" ] && [ "$ACTION" != "resume" ] && [ "$ACTION" != "setup" ]; then
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
# Function: ensure_nodes_ready
# Description: Checks for ready worker nodes before deploying. If none are
#              ready and AWS_CLUSTER_NAME is set, triggers a scale-up and waits
#              for at least one node to become Ready. Prevents Helm deployments
#              from timing out when the Cluster Autoscaler has scaled to zero.
##############################################################################
ensure_nodes_ready() {
    # awk on the STATUS column (col 2) is the only reliable cross-version way
    # to count Ready nodes — kubectl field selectors do not support .status.conditions
    count_ready_nodes() {
        kubectl get nodes --no-headers 2>/dev/null \
            | awk '$2=="Ready"{n++} END{print n+0}' || echo 0
    }

    local ready_nodes
    ready_nodes=$(count_ready_nodes)

    if [ "${ready_nodes}" -gt 0 ]; then
        log INFO "Worker nodes ready: ${ready_nodes}"
        return 0
    fi

    log WARNING "No ready worker nodes found — cluster is scaled to zero"

    if [ -z "${AWS_CLUSTER_NAME:-}" ]; then
        log ERROR "No ready nodes and AWS_CLUSTER_NAME is not set — cannot scale up automatically"
        log ERROR "Scale up your cluster manually before running 'up'"
        exit 1
    fi

    log INFO "Scaling up node group before deployment (this takes ~3 minutes)..."
    resume_cluster

    # Wait for at least one node to reach Ready status
    log INFO "Waiting for nodes to become Ready..."
    local attempts=0
    local max_attempts=40  # 40 × 15s = 10 minutes
    while [ $attempts -lt $max_attempts ]; do
        ready_nodes=$(count_ready_nodes)
        if [ "${ready_nodes}" -gt 0 ]; then
            log SUCCESS "${ready_nodes} node(s) Ready — proceeding with deployment"
            return 0
        fi
        attempts=$((attempts + 1))
        log INFO "Waiting for nodes... (${attempts}/${max_attempts})"
        sleep 15
    done

    log ERROR "Timed out waiting for nodes to become Ready"
    exit 1
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
        kubectl create namespace "$NAMESPACE"
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
        else
            ingress_hostname=$(get_ingress_hostname 2>/dev/null || echo "")
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
        log SUCCESS "LangSmith upgraded with deployment feature enabled"
    else
        # Pre-v12: Enable langgraphPlatform feature
        log INFO "Enabling langgraphPlatform feature in LangSmith (pre-v12)..."
        
        # Create/update LangSmith config
        create_langsmith_config
        
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

    local endpoint=""
    local max_attempts=30
    local attempt=0
    local endpoint_pending=false

    while [ $attempt -lt $max_attempts ]; do
        # Try ALB ingress hostname first, then IP fallback
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

    if [ -z "$endpoint" ]; then
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
    echo ""
    echo -e "${YELLOW}⚠️  Cluster Management:${NC}"
    echo -e "    Pause (scale to 0):  ${GREEN}$0 pause${NC}"
    echo -e "    Resume:              ${GREEN}$0 resume${NC}"
    echo -e "    Tear down:           ${GREEN}$0 down${NC}"
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
    
    # For pause/resume actions, configure AWS and execute
    if [ "$ACTION" = "pause" ] || [ "$ACTION" = "resume" ]; then
        setup_aws_account
        if [ "$ACTION" = "pause" ]; then
            pause_cluster
        else
            resume_cluster
        fi
        return 0
    fi

    # For setup action, run full cluster provisioning workflow
    if [ "$ACTION" = "setup" ]; then
        check_prerequisites
        setup_cluster
        return 0
    fi

    # For addons action, install/update addons on an existing cluster
    if [ "$ACTION" = "addons" ]; then
        check_prerequisites
        install_addons
        return 0
    fi

    # For upgrade action, upgrade control plane + node groups + addons
    if [ "$ACTION" = "upgrade" ]; then
        check_prerequisites
        setup_aws_account
        upgrade_cluster
        return 0
    fi

    # For teardown action, permanently delete the cluster
    if [ "$ACTION" = "teardown" ]; then
        check_prerequisites
        teardown_cluster
        return 0
    fi

    log INFO "Starting LangSmith/LangSmith Deployment Installation Script"

    # Check prerequisites (skip with --skip-checks)
    if [ "$SKIP_CHECKS" = true ]; then
        log WARNING "Skipping prerequisite checks (--skip-checks)"
    else
        check_prerequisites
    fi
    
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
        # Create EKS cluster if --create-cluster is set (runs before kubeconfig update)
        create_eks_cluster

        # Configure kubectl for EKS if AWS env vars are present
        setup_aws_account

        # Setup namespace (required for 'up')
        setup_namespace
        
        # Auto-detect ingress type (defaults to ALB for EKS)
        set_ingress_type
        
        # Load configuration
        load_configuration
        
        # Setup Helm repository
        setup_helm_repo

        # Ensure worker nodes are ready before deploying (auto scale-up if at zero)
        if [ "$ACTION" = "up" ]; then
            ensure_nodes_ready
        fi

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

