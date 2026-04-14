#!/bin/bash

##############################################################################
# LangSmith on AWS EKS — Provisioning and Deployment Orchestrator
#
# Description: Provisions and manages AWS EKS clusters for LangSmith.
#              AWS-specific operations (setup, addons, upgrade, teardown,
#              pause, resume) are handled directly. Kubernetes deployment
#              operations (up, down, status) are delegated to smith-fly.sh
#              so that K8s/Helm logic is maintained in a single place.
#
# Usage: ./aws-smith-fly.sh <setup|addons|upgrade|teardown|pause|resume|up|down|status> [options]
#
# Date: 2025-10-14
##############################################################################

set -euo pipefail

# For debugging
# set -x

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"  # Passed to smith-fly via --config-dir

SMITH_FLY_SCRIPT="${SCRIPT_DIR}/../smith-fly/smith-fly.sh"

ACTION=""
INSTALL_LS=false
INSTALL_LD=false
INSTALL_AB=false  # Agent Builder (requires Deployment, v0.13+)
VERSION=""
DEBUG=false
SKIP_CHECKS=false
CREATE_CLUSTER=false
CLOUDWATCH=false
EKS_NODEGROUP_NAME=""  # Auto-discovered if not set
NAMESPACE=""
INGRESS_TYPE=""  # Empty means auto-detect; 'alb' or 'nginx' if explicitly set

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
    up -lda                Deploy LangSmith Deployment + Agent Builder (v0.13+)
    down                   Remove LangSmith from all namespaces
    down -n <ns>           Remove from a specific namespace only
    status                 Show deployment status

ACTIONS — cost management
    pause                  Scale node group to 0 (EC2 billing stops, pods Pending)
    resume                 Scale node group back up to EKS_NODE_COUNT

OPTIONS
    -l                     Install LangSmith (required for 'up')
    -ld                    Install LangSmith Deployment (required for 'up')
    -lda                   Install LangSmith Deployment + Agent Builder (v0.13+)
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
    $0 up -ld
    $0 up -lda -v 0.13.23
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
            -lda)
                INSTALL_LD=true
                INSTALL_AB=true
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
                    london|Europe/London)       SCHEDULE_TIMEZONE="Europe/London" ;;
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

    # Validate that at least one of -l, -ld, or -lda is specified for 'up' action
    if [ "$ACTION" = "up" ]; then
        if [ "$INSTALL_LS" = false ] && [ "$INSTALL_LD" = false ]; then
            log ERROR "At least one of -l, -ld, or -lda must be specified with 'up' action"
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
# Function: call_smith_fly
# Description: Delegates Kubernetes/Helm operations (up, down, status) to
#              smith-fly.sh, passing this script's config directory so both
#              tools share the same .env and config.yaml.
##############################################################################
call_smith_fly() {
    if [ ! -f "$SMITH_FLY_SCRIPT" ]; then
        log ERROR "smith-fly.sh not found at: ${SMITH_FLY_SCRIPT}"
        log ERROR "Ensure smith-fly/ is a sibling directory of aws-smith-fly/"
        exit 1
    fi

    local args=("$ACTION")

    # Add install flags for 'up' action
    if [ "$ACTION" = "up" ]; then
        if [ "$INSTALL_LD" = true ] && [ "$INSTALL_AB" = true ]; then
            args+=("-lda")
        else
            [ "$INSTALL_LS" = true ] && args+=("-l")
            [ "$INSTALL_LD" = true ] && args+=("-ld")
        fi
    fi

    [ -n "$VERSION" ]      && args+=("-v" "$VERSION")
    [ -n "$NAMESPACE" ]    && args+=("-n" "$NAMESPACE")
    [ -n "$INGRESS_TYPE" ] && args+=("-i" "$INGRESS_TYPE")
    [ "$DEBUG" = true ]    && args+=("--debug")
    args+=("--config-dir" "${CONFIG_DIR}")

    log INFO "Delegating to smith-fly: ${args[*]}"
    bash "$SMITH_FLY_SCRIPT" "${args[@]}"
}

##############################################################################
# Main execution
##############################################################################
main() {
    parse_arguments "$@"

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

    # For up/down/status: handle AWS pre-steps then delegate to smith-fly
    if [ "$SKIP_CHECKS" = true ]; then
        log WARNING "Skipping prerequisite checks (--skip-checks)"
    else
        check_prerequisites
    fi

    if [ "$ACTION" = "up" ]; then
        # Optionally create EKS cluster (--create-cluster flag)
        create_eks_cluster

        # Configure kubectl for the EKS cluster
        setup_aws_account

        # Ensure worker nodes are ready (auto scale-up if cluster is at zero)
        ensure_nodes_ready
    else
        # down/status: configure kubectl if AWS env vars are present
        setup_aws_account
    fi

    call_smith_fly

    log SUCCESS "Script completed successfully"
}

# Execute main function with all arguments
main "$@"
