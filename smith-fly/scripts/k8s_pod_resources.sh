#!/bin/bash

# ==============================================================================
# K8s Pod Resource Calculator
#
# Usage:
#   ./k8s_pod_resources.sh <namespace>
#
# Reports per-pod CPU/memory actual usage, requests, and limits for every pod
# in the given namespace, plus a totals row at the bottom.
#
# Requirements: kubectl, python3
# ==============================================================================

C_BLUE="\033[0;34m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_RED="\033[0;31m"
C_CYAN="\033[0;36m"
C_BOLD="\033[1m"
C_NONE="\033[0m"

# ==============================================================================
# Validation
# ==============================================================================

if [[ -z "$1" ]]; then
    echo -e "${C_RED}Error: namespace argument required${C_NONE}"
    echo ""
    echo "Usage: $0 <namespace>"
    echo ""
    echo "Example:"
    echo "  $0 langsmith-prod"
    exit 1
fi

NS="$1"

if ! command -v kubectl &>/dev/null; then
    echo -e "${C_RED}Error: kubectl not found in PATH${C_NONE}"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo -e "${C_RED}Error: python3 not found in PATH${C_NONE}"
    exit 1
fi

if ! kubectl get namespace "$NS" &>/dev/null; then
    echo -e "${C_RED}Error: namespace '${NS}' not found${C_NONE}"
    exit 1
fi

# ==============================================================================
# Data Collection & Report
# ==============================================================================

echo ""
echo -e "${C_BOLD}${C_CYAN}Pod Resource Report: ${NS}${C_NONE}"
echo ""

TOP_OUTPUT=$(kubectl top pods -n "$NS" --no-headers 2>/dev/null)
if [[ -z "$TOP_OUTPUT" ]]; then
    echo -e "${C_YELLOW}Warning: metrics-server unavailable — actual usage columns will show '-'${C_NONE}"
    echo ""
fi

PODS_JSON=$(kubectl get pods -n "$NS" -o json 2>/dev/null)

COMBINED=$(printf '%s\n---TOP_END---\n%s' "$TOP_OUTPUT" "$PODS_JSON")

echo "$COMBINED" | python3 -c '
import json, sys

raw = sys.stdin.read()
top_section, json_section = raw.split("---TOP_END---\n", 1)

def parse_cpu_m(val):
    if not val or val == "-":
        return 0
    val = str(val).strip()
    if val.endswith("m"):
        return int(val[:-1])
    return int(float(val) * 1000)

def parse_mem_mi(val):
    if not val or val == "-":
        return 0
    val = str(val).strip()
    if val.endswith("Gi"):
        return int(float(val[:-2]) * 1024)
    if val.endswith("Mi"):
        return int(val[:-2])
    if val.endswith("Ki"):
        return int(int(val[:-2]) / 1024)
    return int(int(val) / 1024 / 1024)

def fmt_cpu(m):
    return "-" if m == 0 else "{}m".format(m)

def fmt_mem(mi):
    return "-" if mi == 0 else "{}Mi".format(mi)

usage = {}
for line in top_section.strip().splitlines():
    parts = line.split()
    if len(parts) >= 3:
        usage[parts[0]] = {
            "cpu": parse_cpu_m(parts[1]),
            "mem": parse_mem_mi(parts[2]),
        }

pods_json = json.loads(json_section)
rows = []
for pod in sorted(pods_json.get("items", []), key=lambda p: p["metadata"]["name"]):
    name = pod["metadata"]["name"]
    cpu_req = cpu_lim = mem_req = mem_lim = 0
    for c in pod["spec"].get("containers", []):
        res = c.get("resources", {})
        req = res.get("requests", {})
        lim = res.get("limits", {})
        cpu_req += parse_cpu_m(req.get("cpu", "0"))
        cpu_lim += parse_cpu_m(lim.get("cpu", "0"))
        mem_req += parse_mem_mi(req.get("memory", "0"))
        mem_lim += parse_mem_mi(lim.get("memory", "0"))
    u = usage.get(name, {"cpu": 0, "mem": 0})
    rows.append((name, u["cpu"], cpu_req, cpu_lim, u["mem"], mem_req, mem_lim))

if not rows:
    print("No pods found in namespace.")
    sys.exit(0)

name_w = max(len(r[0]) for r in rows)
name_w = max(name_w, 3)

hdr_fmt = "{:<" + str(name_w) + "}  {:>8} {:>8} {:>8}  {:>8} {:>8} {:>8}"
row_fmt = hdr_fmt

hdr = hdr_fmt.format("Pod", "CPU Use", "CPU Req", "CPU Lim", "Mem Use", "Mem Req", "Mem Lim")
sep = "-" * len(hdr)

print(hdr)
print(sep)

t_cu = t_cr = t_cl = t_mu = t_mr = t_ml = 0
for name, cu, cr, cl, mu, mr, ml in rows:
    t_cu += cu; t_cr += cr; t_cl += cl
    t_mu += mu; t_mr += mr; t_ml += ml
    print(row_fmt.format(name, fmt_cpu(cu), fmt_cpu(cr), fmt_cpu(cl), fmt_mem(mu), fmt_mem(mr), fmt_mem(ml)))

print(sep)
print(row_fmt.format("TOTAL", fmt_cpu(t_cu), fmt_cpu(t_cr), fmt_cpu(t_cl), fmt_mem(t_mu), fmt_mem(t_mr), fmt_mem(t_ml)))
print()
print("  CPU  =>  usage: {}m ({:.2f} cores)  |  requests: {}m ({:.2f} cores)  |  limits: {}m ({:.2f} cores)".format(
    t_cu, t_cu/1000, t_cr, t_cr/1000, t_cl, t_cl/1000))
print("  Mem  =>  usage: {}Mi ({:.2f} Gi)  |  requests: {}Mi ({:.2f} Gi)  |  limits: {}Mi ({:.2f} Gi)".format(
    t_mu, t_mu/1024, t_mr, t_mr/1024, t_ml, t_ml/1024))
print()
'
