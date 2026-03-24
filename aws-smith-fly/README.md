# aws-smith-fly — LangSmith on AWS EKS

Automates provisioning an AWS EKS cluster and deploying LangSmith on it.
Designed for **testing and development environments** — not production.

---

## Prerequisites

### Tools

| Tool | Purpose |
|---|---|
| [`aws`](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | AWS API calls |
| [`eksctl`](https://eksctl.io/installation/) | EKS cluster provisioning |
| [`kubectl`](https://kubernetes.io/docs/tasks/tools/) | Kubernetes control |
| [`helm`](https://helm.sh/docs/intro/install/) (v3+) | LangSmith deployment |
| [`openssl`](https://www.openssl.org/) | Secret generation |

### AWS Permissions

Your AWS identity needs:

- `EKSFullAccess` + `IAMFullAccess` (or `PowerUserAccess` + IAM write)
- `cloudformation:*` for stack management
- `ce:UpdateCostAllocationTagsStatus` for cost tags (billing admin — optional, degrades gracefully)

### Credentials

Set one of:

```bash
# Key-based
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...   # if using assumed role / SSO

# Profile-based
export AWS_PROFILE=my-profile
```

---

## Quick Start

```bash
# 1. Create the EKS cluster and install all addons (~20 min)
export AWS_CLUSTER_NAME=my-cluster
export AWS_REGION=us-east-1
export ENGINEER=yourname
./aws-smith-fly.sh setup my-cluster

# 2. Fill in your LangSmith credentials
cp config/.env.example config/.env
$EDITOR config/.env   # set LicenseKey and initialOrgAdminEmail

# 3. Deploy LangSmith
./aws-smith-fly.sh up -l

# 4. When done for the day — stop EC2 billing
./aws-smith-fly.sh pause

# 5. Resume next morning
./aws-smith-fly.sh resume
```

---

## Actions

### Cluster management

| Action | Description |
|---|---|
| `setup [cluster-name]` | Create EKS cluster + all addons (~20 min) |
| `addons` | Install/update addons on an existing cluster (idempotent) |
| `upgrade` | Upgrade Kubernetes version + addons (irreversible, prompts for confirmation) |
| `teardown` | Permanently delete the cluster and all AWS resources (prompts for cluster name) |

**`setup` steps:**

```
Step 1/8  Activate Cost Allocation Tags (account-level, best-effort)
Step 2/8  Create EKS cluster via eksctl
Step 3/8  Configure kubectl context
Step 4/8  EBS CSI driver + gp3 StorageClass (required for PersistentVolumeClaims)
Step 5/8  AWS Load Balancer Controller (ALB ingress)
Step 6/8  Cluster Autoscaler (scale-to-zero when idle)
Step 7/8  CloudWatch Container Insights (--cloudwatch only)
Step 8/8  Scheduled scaling — warm up 08:00, sleep 18:00 Mon–Fri
```

### LangSmith deployment

| Action | Description |
|---|---|
| `up -l` | Deploy LangSmith |
| `up -ld` | Deploy LangSmith Deployment (installs LangSmith first if absent) |
| `down` | Remove LangSmith from all namespaces |
| `down -n <ns>` | Remove from a specific namespace only |
| `status` | Show pod status, Helm chart version, and ingress URL |

### Cost management

| Action | Description |
|---|---|
| `pause` | Scale node group to 0 — EC2 billing stops immediately |
| `resume` | Scale node group back up to `EKS_NODE_COUNT` |

> The cluster also scales automatically: nodes spin up at 08:00 and down at 18:00 Mon–Fri
> (default Europe/London — override with `--tz` or `SCHEDULE_TIMEZONE`).

---

## Options

```
-l                  Install LangSmith (required for 'up')
-ld                 Install LangSmith Deployment (required for 'up')
-v VERSION          Helm chart version (default: latest)
-n NAMESPACE        Kubernetes namespace (auto-generated from hostname if omitted)
-i alb|nginx        Ingress type (auto-detected if omitted)
--cloudwatch        Enable CloudWatch Container Insights (~$15/mo, opt-in)
--tz TIMEZONE       Timezone for scheduled scaling (see below)
--debug             Verbose Helm output
--skip-checks       Skip prerequisite tool checks
-h, --help          Full reference documentation
```

### Timezone aliases for `--tz`

| Alias | IANA timezone |
|---|---|
| `london` | `Europe/London` (default) |
| `amsterdam` | `Europe/Amsterdam` |
| `newyork` / `new-york` | `America/New_York` |
| `california` / `la` | `America/Los_Angeles` |

Any raw IANA name also works: `--tz America/Chicago`

---

## Environment Variables

### Required

| Variable | Description |
|---|---|
| `AWS_CLUSTER_NAME` | EKS cluster name |
| `AWS_REGION` | AWS region (default: `us-east-1`) |

### Cluster configuration (optional)

| Variable | Default | Description |
|---|---|---|
| `ENGINEER` | Auto-detected from AWS identity | Your name, applied as `CreatedBy` tag to all resources |
| `EKS_NODE_TYPE` | `m5.xlarge` | EC2 instance type |
| `EKS_NODE_COUNT` | `2` | Initial and resume node count |
| `EKS_NODE_MAX` | `10` | Cluster Autoscaler maximum |
| `EKS_KUBERNETES_VERSION` | Latest | Kubernetes version |
| `EKS_NODEGROUP_NAME` | Auto-discovered | Node group name override |
| `EKS_TAGS` | — | Extra AWS tags: `key=val,key2=val2` |

### Scheduled scaling (optional)

| Variable | Default | Description |
|---|---|---|
| `SCHEDULE_TIMEZONE` | `Europe/London` | IANA timezone (overridden by `--tz`) |
| `SCHEDULE_SCALE_UP` | `0 8 * * MON-FRI` | Cron expression for morning warm-up |
| `SCHEDULE_SCALE_DOWN` | `0 18 * * MON-FRI` | Cron expression for evening shutdown |

### Cluster Autoscaler (optional)

| Variable | Default | Description |
|---|---|---|
| `CA_SCALE_DOWN_UNNEEDED_TIME` | `10m` | How long a node must be idle before scale-down |
| `CA_SCALE_DOWN_DELAY_AFTER_ADD` | `10m` | Grace period after a scale-up event |

---

## Configuration Files

| File | Required for | Notes |
|---|---|---|
| `config/.env` | `up` | LangSmith credentials — **do not commit** |
| `config/.env.example` | — | Template to copy from |
| `config/config.yaml` | `up` | Helm values (resource limits, ingress settings) |
| `config/ls_config.yaml` | — | Auto-generated on each `up` run — do not edit |

### `config/.env`

```bash
cp config/.env.example config/.env
```

| Field | Required | Description |
|---|---|---|
| `LicenseKey` | Yes | Obtain from [smith.langchain.com/settings](https://smith.langchain.com/settings) |
| `initialOrgAdminEmail` | Yes | Email for the initial admin account |
| `initialOrgAdminPassword` | No | Auto-generated (strong random) if blank |
| `LANGSMITH_HOSTNAME` | No | Custom domain — leave blank to use ALB hostname |

### `config/config.yaml`

Controls Helm values passed to the LangSmith chart. The defaults in this file are sized for dev/test use (~2 vCPU, ~6 Gi RAM total). For production sizing, see the [LangSmith self-hosted docs](https://docs.smith.langchain.com/).

---

## Cost Optimisation

### Scheduled scaling

Nodes automatically scale up at 08:00 and down at 18:00 Mon–Fri in your chosen timezone. EC2 costs accrue only during those hours (plus any Cluster Autoscaler activity outside them).

Override the schedule:

```bash
SCHEDULE_SCALE_UP="0 9 * * MON-FRI" \
SCHEDULE_SCALE_DOWN="0 17 * * MON-FRI" \
./aws-smith-fly.sh setup my-cluster --tz newyork
```

### Manual pause / resume

```bash
./aws-smith-fly.sh pause    # immediately scale to 0 nodes
./aws-smith-fly.sh resume   # scale back up
```

### Engineer cost attribution

All AWS resources are tagged with `CreatedBy=<engineer>` and `Application=langsmith`. To see per-engineer costs in Cost Explorer, activate these as Cost Allocation Tags:

**AWS Console → Billing → Cost Allocation Tags → Activate `CreatedBy`, `Application`, `Engineer`**

The script attempts to activate these automatically during `setup` — it requires billing-admin permissions (`ce:UpdateCostAllocationTagsStatus`). If your role lacks that permission the script warns and continues; ask an AWS account admin to activate them once.

---

## Destroying the Environment

```bash
AWS_CLUSTER_NAME=my-cluster AWS_REGION=us-east-1 ./aws-smith-fly.sh teardown
```

You will be prompted to type the cluster name to confirm. The command:

1. Disables termination protection on all eksctl CloudFormation stacks
2. Deletes the EKS cluster, node groups, and IRSA stacks via `eksctl delete cluster --wait`
3. Deletes the shared `AWSLoadBalancerControllerIAMPolicy` (skipped if in use by another cluster)

Takes 10–15 minutes.

---

## Troubleshooting

### Pods not starting

```bash
kubectl get pods -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

### Nodes not coming up after resume

```bash
kubectl get nodes
aws eks describe-nodegroup \
  --cluster-name $AWS_CLUSTER_NAME \
  --nodegroup-name <ng-name> \
  --region $AWS_REGION \
  --query 'nodegroup.scalingConfig'
```

### ALB not provisioned

```bash
# Check ALB controller is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check ingress events
kubectl describe ingress -n <namespace>
```

### CloudFormation stuck stacks

The script auto-detects and deletes stacks in `ROLLBACK_COMPLETE`, `CREATE_FAILED`, `ROLLBACK_FAILED`, or `DELETE_FAILED` states before retrying. To inspect manually:

```bash
aws cloudformation describe-stack-events \
  --stack-name eksctl-<cluster>-cluster \
  --region $AWS_REGION \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output table
```

### PersistentVolumeClaims stuck Pending

The EBS CSI driver must be installed and the `gp3` StorageClass must exist. Run:

```bash
AWS_CLUSTER_NAME=<cluster> AWS_REGION=<region> ./aws-smith-fly.sh addons
```

### Manual cluster teardown (if `teardown` fails)

```bash
# Disable termination protection on all stacks first
for stack in $(aws cloudformation list-stacks \
  --region $AWS_REGION \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?starts_with(StackName,'eksctl-${AWS_CLUSTER_NAME}-')].StackName" \
  --output text); do
  aws cloudformation update-termination-protection \
    --no-enable-termination-protection \
    --stack-name "$stack" --region $AWS_REGION
done

eksctl delete cluster --name $AWS_CLUSTER_NAME --region $AWS_REGION --wait
```

---

## File Structure

```
smith-fly/
├── aws-smith-fly.sh          Main script
├── README.md             This file
├── .gitignore            Excludes .env and generated configs
├── config/
│   ├── .env              Your credentials — DO NOT COMMIT
│   ├── .env.example      Template for .env
│   ├── config.yaml       Helm values (edit for resource sizing)
│   └── ls_config.yaml    Auto-generated per run — do not edit
```

---

## Support

- **Script issues**: check the Troubleshooting section above
- **LangSmith / LangSmith Deployment**: [LangSmith self-hosted docs](https://docs.smith.langchain.com/)
- **LangChain support portal**: [support.langchain.com](https://support.langchain.com/)
