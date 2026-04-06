#!/bin/bash
set -euo pipefail

##############################################################################
# smith-fly: Synthetic Data Population Script
#
# Populates a LangSmith instance with synthetic traces, feedback, datasets,
# annotation queues, and prompts for testing. Exercises every major UI feature.
# No external dependencies beyond curl + standard Unix tools.
#
# Usage: ./scripts/populate.sh <endpoint> <email> <password> [options]
##############################################################################

# ==============================================================================
# Colors & Logging
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        INFO)    echo -e "${BLUE}[${timestamp}] [INFO]${NC} ${message}" ;;
        SUCCESS) echo -e "${GREEN}[${timestamp}] [SUCCESS]${NC} ${message}" ;;
        WARNING) echo -e "${YELLOW}[${timestamp}] [WARNING]${NC} ${message}" ;;
        ERROR)   echo -e "${RED}[${timestamp}] [ERROR]${NC} ${message}" ;;
        *)       echo -e "[${timestamp}] ${message}" ;;
    esac
}

# Step-style output for the progress display
step_start() {
    printf "  [%s] %-42s" "$1" "$2"
}

step_ok() {
    local extra="${1:-}"
    if [ -n "$extra" ]; then
        echo -e " ${GREEN}OK${NC}  ${extra}"
    else
        echo -e " ${GREEN}OK${NC}"
    fi
}

step_fail() {
    echo -e " ${RED}FAIL${NC}"
}

step_warn() {
    echo -e " ${YELLOW}WARN${NC}"
}

# ==============================================================================
# Utility Functions
# ==============================================================================

##############################################################################
# Function: gen_uuid
# Description: Generate a UUID v4 using available system tools
##############################################################################
gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v python3 &>/dev/null; then
        python3 -c "import uuid; print(uuid.uuid4())"
    elif [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        log ERROR "No UUID generator found. Install uuidgen or python3."
        exit 1
    fi
}

##############################################################################
# Function: json_val
# Description: Extract a value from JSON using jq, python3, or grep fallback
# Args: key - JSON key path (jq syntax, e.g. ".field" or ".[0].field")
##############################################################################
json_val() {
    local key="$1"
    if command -v jq &>/dev/null; then
        jq -r "$key"
    elif command -v python3 &>/dev/null; then
        python3 -c "
import sys, json
data = json.load(sys.stdin)
keys = '${key}'.strip('.').split('.')
result = data
for k in keys:
    if k.startswith('[') and k.endswith(']'):
        result = result[int(k[1:-1])]
    elif k.isdigit():
        result = result[int(k)]
    else:
        result = result[k]
print(result if result is not None else '')
"
    else
        # Minimal grep fallback — works for simple top-level string fields
        local simple_key="${key#.}"
        grep -o "\"${simple_key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:.*"\(.*\)"/\1/'
    fi
}

##############################################################################
# Function: json_val_raw
# Description: Extract a raw (possibly non-string) value from JSON
# Args: key - JSON key path (jq syntax)
##############################################################################
json_val_raw() {
    local key="$1"
    if command -v jq &>/dev/null; then
        jq "$key"
    elif command -v python3 &>/dev/null; then
        python3 -c "
import sys, json
data = json.load(sys.stdin)
keys = '${key}'.strip('.').split('.')
result = data
for k in keys:
    if k.startswith('[') and k.endswith(']'):
        result = result[int(k[1:-1])]
    elif k.isdigit():
        result = result[int(k)]
    else:
        result = result[k]
print(json.dumps(result))
"
    else
        cat  # passthrough if no parser
    fi
}

##############################################################################
# Function: iso_timestamp
# Description: Generate ISO 8601 timestamp with milliseconds
# Args: offset_ms - milliseconds to add to base time (optional, default 0)
##############################################################################
iso_timestamp() {
    local offset_ms="${1:-0}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        python3 -c "
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc) + timedelta(milliseconds=${offset_ms})
print(now.strftime('%Y-%m-%dT%H:%M:%S.') + f'{now.microsecond:06d}Z')
"
    else
        local secs=$((offset_ms / 1000))
        local us=$((offset_ms % 1000 * 1000))
        date -u -d "+${secs} seconds" "+%Y-%m-%dT%H:%M:%S.$(printf '%06d' $us)Z" 2>/dev/null || \
            date -u "+%Y-%m-%dT%H:%M:%S.000000Z"
    fi
}

##############################################################################
# Function: dotted_order
# Description: Generate dotted_order string for LangSmith run ordering
# Args: timestamp - ISO timestamp, uuid - run UUID, parent_dotted (optional)
##############################################################################
dotted_order() {
    local ts="$1"
    local uuid="$2"
    local parent_dotted="${3:-}"
    # SDK format: YYYYMMDDTHHMMSSffffffZ<uuid>  (no dot before microseconds)
    # The "." separator is ONLY between parent and child parts
    local compact
    # Remove dashes, colons, and the dot before microseconds
    compact=$(echo "$ts" | sed 's/[-:]//g; s/\.\([0-9]\{6\}\)Z/\1Z/')
    if [ -n "$parent_dotted" ]; then
        echo "${parent_dotted}.${compact}${uuid}"
    else
        echo "${compact}${uuid}"
    fi
}

# ==============================================================================
# Argument Parsing
# ==============================================================================

ENDPOINT=""
EMAIL=""
PASSWORD=""
PROJECT_NAME="smith-fly-demo"
TRACE_COUNT=1

usage() {
    echo "Usage: $0 <endpoint> <email> <password> [--project NAME] [--traces N]"
    echo ""
    echo "Arguments:"
    echo "  endpoint    LangSmith URL (e.g., http://192.168.49.2.nip.io)"
    echo "  email       Admin email"
    echo "  password    Admin password"
    echo ""
    echo "Options:"
    echo "  --project   Project name (default: smith-fly-demo)"
    echo "  --traces    Number of each trace type (default: 1, so 6 traces / ~16 runs)"
    exit 1
}

parse_args() {
    if [ $# -lt 3 ]; then
        usage
    fi

    ENDPOINT="${1%/}"  # strip trailing slash
    EMAIL="$2"
    PASSWORD="$3"
    shift 3

    while [ $# -gt 0 ]; do
        case "$1" in
            --project)
                PROJECT_NAME="$2"
                shift 2
                ;;
            --traces)
                TRACE_COUNT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                log ERROR "Unknown option: $1"
                usage
                ;;
        esac
    done
}

# ==============================================================================
# Step 1: Wait for LangSmith to be ready
# ==============================================================================

wait_for_ready() {
    local max_retries=5
    local retry_interval=10

    for i in $(seq 1 $max_retries); do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "${ENDPOINT}/api/v1/info" 2>/dev/null || echo "000")
        if [ "$http_code" = "200" ]; then
            return 0
        fi
        if [ "$i" -lt "$max_retries" ]; then
            log WARNING "LangSmith not ready (HTTP ${http_code}), retrying in ${retry_interval}s... (${i}/${max_retries})"
            sleep "$retry_interval"
        fi
    done

    log ERROR "LangSmith at ${ENDPOINT} is not responding after ${max_retries} attempts."
    log ERROR "Ensure pods are running: kubectl get pods -n <namespace>"
    exit 1
}

# ==============================================================================
# Step 2: Login
# ==============================================================================

JWT_TOKEN=""

do_login() {
    local auth_header
    auth_header=$(printf '%s:%s' "$EMAIL" "$PASSWORD" | base64)

    local max_retries=6
    local retry_interval=5
    local response http_code body

    for i in $(seq 1 $max_retries); do
        response=$(curl -s -w "\n%{http_code}" \
            -X POST "${ENDPOINT}/api/v1/login" \
            -H "Authorization: Basic ${auth_header}" \
            -H "Content-Type: application/json" \
            2>/dev/null) || true

        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')

        if [ "$http_code" = "200" ]; then
            JWT_TOKEN=$(echo "$body" | json_val '.access_token')
            if [ -z "$JWT_TOKEN" ] || [ "$JWT_TOKEN" = "null" ]; then
                log ERROR "Login succeeded but no access_token in response."
                exit 1
            fi
            return 0
        fi

        # 401 on fresh install likely means the initial user hasn't been seeded yet
        if [ "$http_code" = "401" ] && [ "$i" -lt "$max_retries" ]; then
            log WARNING "Login returned 401 — user may not be seeded yet, retrying in ${retry_interval}s... (${i}/${max_retries})"
            sleep "$retry_interval"
            continue
        fi

        log ERROR "Login failed (HTTP ${http_code}) — check email/password."
        log ERROR "Response: ${body}"
        exit 1
    done

    log ERROR "Login failed after ${max_retries} attempts (HTTP ${http_code})."
    log ERROR "Response: ${body}"
    exit 1
}

# ==============================================================================
# Step 3: Get Tenant Info
# ==============================================================================

TENANT_ID=""
TENANT_HANDLE=""
ORG_ID=""

get_tenant_info() {
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X GET "${ENDPOINT}/api/v1/tenants" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        2>/dev/null) || true

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log ERROR "Failed to get tenant info (HTTP ${http_code})."
        exit 1
    fi

    # Response is an array of tenants — use the first one
    TENANT_ID=$(echo "$body" | json_val '.[0].id')
    TENANT_HANDLE=$(echo "$body" | json_val '.[0].tenant_handle')
    ORG_ID=$(echo "$body" | json_val '.[0].organization_id')

    if [ -z "$TENANT_ID" ] || [ "$TENANT_ID" = "null" ]; then
        log ERROR "Could not extract tenant_id from response."
        exit 1
    fi
}

# ==============================================================================
# Step 4: Create API Key
# ==============================================================================

API_KEY=""

create_api_key() {
    local key_name="smith-fly-populate-$(date +%s)"

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${ENDPOINT}/api/v1/api-key" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Tenant-Id: ${TENANT_ID}" \
        ${ORG_ID:+-H "X-Organization-Id: ${ORG_ID}"} \
        -d "{\"description\": \"${key_name}\"}" \
        2>/dev/null) || true

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        log ERROR "Could not create API key (HTTP ${http_code})."
        log ERROR "You can create one manually in the LangSmith UI → Settings → API Keys"
        exit 1
    fi

    API_KEY=$(echo "$body" | json_val '.key')
    if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
        # Some versions return the key differently
        API_KEY=$(echo "$body" | json_val '.api_key')
    fi
    if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
        log ERROR "API key created but could not extract key value from response."
        exit 1
    fi
}

# ==============================================================================
# Step 5: Create Synthetic Traces
# ==============================================================================

TOTAL_RUNS=0

# Array to track root run IDs for feedback and annotation queues
ROOT_RUN_IDS=()

##############################################################################
# Function: post_batch
# Description: POST a batch of runs to LangSmith
# Args: trace_name - name for logging, payload - JSON string
# Returns: 0 on success, 1 on failure
##############################################################################
post_batch() {
    local trace_name="$1"
    local payload="$2"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${ENDPOINT}/api/v1/runs/batch" \
        -H "X-Api-Key: ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        2>/dev/null) || true

    if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
        return 0
    else
        log WARNING "Batch POST for '${trace_name}' returned HTTP ${http_code}"
        return 1
    fi
}

##############################################################################
# Function: create_simple_chat
# Description: Creates a simple chain → llm trace (2 runs)
#              Enriched with token usage, metadata, events
##############################################################################
create_simple_chat() {
    local parent_id child_id trace_id
    parent_id=$(gen_uuid)
    child_id=$(gen_uuid)
    trace_id="$parent_id"

    local ts_start ts_child_start ts_first_token ts_child_end ts_end
    ts_start=$(iso_timestamp 0)
    ts_child_start=$(iso_timestamp 100)
    ts_first_token=$(iso_timestamp 350)
    ts_child_end=$(iso_timestamp 1100)
    ts_end=$(iso_timestamp 1200)

    local parent_dotted child_dotted
    parent_dotted=$(dotted_order "$ts_start" "$parent_id")
    child_dotted=$(dotted_order "$ts_child_start" "$child_id" "$parent_dotted")

    local conv_id user_id
    conv_id=$(gen_uuid)
    user_id="user-$(( RANDOM % 1000 ))"

    local payload
    payload=$(cat <<EOF
{
  "post": [
    {
      "id": "${parent_id}",
      "name": "ChatBot",
      "run_type": "chain",
      "inputs": {"question": "What is the capital of France?"},
      "outputs": {"answer": "The capital of France is Paris."},
      "start_time": "${ts_start}",
      "end_time": "${ts_end}",
      "trace_id": "${trace_id}",
      "dotted_order": "${parent_dotted}",
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly", "chat"],
      "extra": {
        "metadata": {
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    },
    {
      "id": "${child_id}",
      "name": "gpt-4o-mini",
      "run_type": "llm",
      "parent_run_id": "${parent_id}",
      "trace_id": "${trace_id}",
      "dotted_order": "${child_dotted}",
      "inputs": {"messages": [{"role": "user", "content": "What is the capital of France?"}]},
      "outputs": {"choices": [{"message": {"role": "assistant", "content": "The capital of France is Paris."}}]},
      "start_time": "${ts_child_start}",
      "end_time": "${ts_child_end}",
      "first_token_time": "${ts_first_token}",
      "prompt_tokens": 14,
      "completion_tokens": 9,
      "total_tokens": 23,
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly"],
      "events": [
        {"name": "start", "time": "${ts_child_start}"},
        {"name": "new_token", "time": "${ts_first_token}"},
        {"name": "end", "time": "${ts_child_end}"}
      ],
      "extra": {
        "metadata": {
          "ls_provider": "openai",
          "ls_model_name": "gpt-4o-mini",
          "ls_model_type": "chat",
          "ls_temperature": 0.7,
          "ls_max_tokens": 256,
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    }
  ]
}
EOF
)

    if post_batch "Simple chat completion" "$payload"; then
        TOTAL_RUNS=$((TOTAL_RUNS + 2))
        ROOT_RUN_IDS+=("$parent_id")
        return 0
    fi
    return 1
}

##############################################################################
# Function: create_rag_pipeline
# Description: Creates a chain → retriever → llm trace (3 runs)
#              Enriched with token usage, metadata, events
##############################################################################
create_rag_pipeline() {
    local parent_id retriever_id llm_id trace_id
    parent_id=$(gen_uuid)
    retriever_id=$(gen_uuid)
    llm_id=$(gen_uuid)
    trace_id="$parent_id"

    local ts_start ts_ret_start ts_ret_end ts_llm_start ts_first_token ts_llm_end ts_end
    ts_start=$(iso_timestamp 2000)
    ts_ret_start=$(iso_timestamp 2100)
    ts_ret_end=$(iso_timestamp 2600)
    ts_llm_start=$(iso_timestamp 2700)
    ts_first_token=$(iso_timestamp 2950)
    ts_llm_end=$(iso_timestamp 3800)
    ts_end=$(iso_timestamp 3900)

    local parent_dotted ret_dotted llm_dotted
    parent_dotted=$(dotted_order "$ts_start" "$parent_id")
    ret_dotted=$(dotted_order "$ts_ret_start" "$retriever_id" "$parent_dotted")
    llm_dotted=$(dotted_order "$ts_llm_start" "$llm_id" "$parent_dotted")

    local conv_id user_id
    conv_id=$(gen_uuid)
    user_id="user-$(( RANDOM % 1000 ))"

    local payload
    payload=$(cat <<EOF
{
  "post": [
    {
      "id": "${parent_id}",
      "name": "RAG Pipeline",
      "run_type": "chain",
      "inputs": {"question": "How does photosynthesis work?"},
      "outputs": {"answer": "Photosynthesis converts light energy into chemical energy. Plants use chlorophyll to absorb sunlight, which drives the conversion of CO2 and water into glucose and oxygen."},
      "start_time": "${ts_start}",
      "end_time": "${ts_end}",
      "trace_id": "${trace_id}",
      "dotted_order": "${parent_dotted}",
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly", "rag"],
      "extra": {
        "metadata": {
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    },
    {
      "id": "${retriever_id}",
      "name": "VectorStoreRetriever",
      "run_type": "retriever",
      "parent_run_id": "${parent_id}",
      "trace_id": "${trace_id}",
      "dotted_order": "${ret_dotted}",
      "inputs": {"query": "How does photosynthesis work?"},
      "outputs": {"documents": [{"page_content": "Photosynthesis is a process used by plants to convert light energy into chemical energy.", "metadata": {"source": "biology_textbook.pdf", "page": 42}}, {"page_content": "Chlorophyll absorbs sunlight and drives the conversion of CO2 and water into glucose.", "metadata": {"source": "biology_textbook.pdf", "page": 43}}]},
      "start_time": "${ts_ret_start}",
      "end_time": "${ts_ret_end}",
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly"],
      "extra": {
        "metadata": {
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    },
    {
      "id": "${llm_id}",
      "name": "claude-3-5-sonnet",
      "run_type": "llm",
      "parent_run_id": "${parent_id}",
      "trace_id": "${trace_id}",
      "dotted_order": "${llm_dotted}",
      "inputs": {"messages": [{"role": "system", "content": "Answer based on the provided context."}, {"role": "user", "content": "How does photosynthesis work?\\n\\nContext:\\nPhotosynthesis is a process used by plants to convert light energy into chemical energy.\\nChlorophyll absorbs sunlight and drives the conversion of CO2 and water into glucose."}]},
      "outputs": {"choices": [{"message": {"role": "assistant", "content": "Photosynthesis converts light energy into chemical energy. Plants use chlorophyll to absorb sunlight, which drives the conversion of CO2 and water into glucose and oxygen."}}]},
      "start_time": "${ts_llm_start}",
      "end_time": "${ts_llm_end}",
      "first_token_time": "${ts_first_token}",
      "prompt_tokens": 72,
      "completion_tokens": 34,
      "total_tokens": 106,
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly"],
      "events": [
        {"name": "start", "time": "${ts_llm_start}"},
        {"name": "new_token", "time": "${ts_first_token}"},
        {"name": "end", "time": "${ts_llm_end}"}
      ],
      "extra": {
        "metadata": {
          "ls_provider": "anthropic",
          "ls_model_name": "claude-3-5-sonnet-20241022",
          "ls_model_type": "chat",
          "ls_temperature": 0.3,
          "ls_max_tokens": 512,
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    }
  ]
}
EOF
)

    if post_batch "RAG pipeline" "$payload"; then
        TOTAL_RUNS=$((TOTAL_RUNS + 3))
        ROOT_RUN_IDS+=("$parent_id")
        return 0
    fi
    return 1
}

##############################################################################
# Function: create_agent_tool
# Description: Creates chain → llm → tool → llm trace (4 runs)
#              Enriched with token usage, metadata, events
##############################################################################
create_agent_tool() {
    local parent_id llm1_id tool_id llm2_id trace_id
    parent_id=$(gen_uuid)
    llm1_id=$(gen_uuid)
    tool_id=$(gen_uuid)
    llm2_id=$(gen_uuid)
    trace_id="$parent_id"

    local ts_start ts_llm1_start ts_llm1_first ts_llm1_end ts_tool_start ts_tool_end ts_llm2_start ts_llm2_first ts_llm2_end ts_end
    ts_start=$(iso_timestamp 5000)
    ts_llm1_start=$(iso_timestamp 5100)
    ts_llm1_first=$(iso_timestamp 5300)
    ts_llm1_end=$(iso_timestamp 5800)
    ts_tool_start=$(iso_timestamp 5900)
    ts_tool_end=$(iso_timestamp 6200)
    ts_llm2_start=$(iso_timestamp 6300)
    ts_llm2_first=$(iso_timestamp 6500)
    ts_llm2_end=$(iso_timestamp 7000)
    ts_end=$(iso_timestamp 7100)

    local parent_dotted llm1_dotted tool_dotted llm2_dotted
    parent_dotted=$(dotted_order "$ts_start" "$parent_id")
    llm1_dotted=$(dotted_order "$ts_llm1_start" "$llm1_id" "$parent_dotted")
    tool_dotted=$(dotted_order "$ts_tool_start" "$tool_id" "$parent_dotted")
    llm2_dotted=$(dotted_order "$ts_llm2_start" "$llm2_id" "$parent_dotted")

    local conv_id user_id
    conv_id=$(gen_uuid)
    user_id="user-$(( RANDOM % 1000 ))"

    local payload
    payload=$(cat <<EOF
{
  "post": [
    {
      "id": "${parent_id}",
      "name": "WeatherAgent",
      "run_type": "chain",
      "inputs": {"question": "What's the weather in San Francisco?"},
      "outputs": {"answer": "The current weather in San Francisco is 62\u00b0F (17\u00b0C) with partly cloudy skies."},
      "start_time": "${ts_start}",
      "end_time": "${ts_end}",
      "trace_id": "${trace_id}",
      "dotted_order": "${parent_dotted}",
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly", "agent"],
      "extra": {
        "metadata": {
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    },
    {
      "id": "${llm1_id}",
      "name": "gpt-4o",
      "run_type": "llm",
      "parent_run_id": "${parent_id}",
      "trace_id": "${trace_id}",
      "dotted_order": "${llm1_dotted}",
      "inputs": {"messages": [{"role": "user", "content": "What's the weather in San Francisco?"}]},
      "outputs": {"choices": [{"message": {"role": "assistant", "content": "", "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"location\": \"San Francisco, CA\"}"}}]}}]},
      "start_time": "${ts_llm1_start}",
      "end_time": "${ts_llm1_end}",
      "first_token_time": "${ts_llm1_first}",
      "prompt_tokens": 18,
      "completion_tokens": 22,
      "total_tokens": 40,
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly"],
      "events": [
        {"name": "start", "time": "${ts_llm1_start}"},
        {"name": "new_token", "time": "${ts_llm1_first}"},
        {"name": "end", "time": "${ts_llm1_end}"}
      ],
      "extra": {
        "metadata": {
          "ls_provider": "openai",
          "ls_model_name": "gpt-4o",
          "ls_model_type": "chat",
          "ls_temperature": 0.0,
          "ls_max_tokens": 1024,
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    },
    {
      "id": "${tool_id}",
      "name": "get_weather",
      "run_type": "tool",
      "parent_run_id": "${parent_id}",
      "trace_id": "${trace_id}",
      "dotted_order": "${tool_dotted}",
      "inputs": {"location": "San Francisco, CA"},
      "outputs": {"temperature": "62\u00b0F", "condition": "Partly Cloudy", "humidity": "72%"},
      "start_time": "${ts_tool_start}",
      "end_time": "${ts_tool_end}",
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly"],
      "extra": {
        "metadata": {
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    },
    {
      "id": "${llm2_id}",
      "name": "gpt-4o",
      "run_type": "llm",
      "parent_run_id": "${parent_id}",
      "trace_id": "${trace_id}",
      "dotted_order": "${llm2_dotted}",
      "inputs": {"messages": [{"role": "user", "content": "What's the weather in San Francisco?"}, {"role": "assistant", "content": "", "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"location\": \"San Francisco, CA\"}"}}]}, {"role": "tool", "content": "{\"temperature\": \"62\u00b0F\", \"condition\": \"Partly Cloudy\", \"humidity\": \"72%\"}", "tool_call_id": "call_1"}]},
      "outputs": {"choices": [{"message": {"role": "assistant", "content": "The current weather in San Francisco is 62\u00b0F (17\u00b0C) with partly cloudy skies."}}]},
      "start_time": "${ts_llm2_start}",
      "end_time": "${ts_llm2_end}",
      "first_token_time": "${ts_llm2_first}",
      "prompt_tokens": 65,
      "completion_tokens": 20,
      "total_tokens": 85,
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly"],
      "events": [
        {"name": "start", "time": "${ts_llm2_start}"},
        {"name": "new_token", "time": "${ts_llm2_first}"},
        {"name": "end", "time": "${ts_llm2_end}"}
      ],
      "extra": {
        "metadata": {
          "ls_provider": "openai",
          "ls_model_name": "gpt-4o",
          "ls_model_type": "chat",
          "ls_temperature": 0.0,
          "ls_max_tokens": 1024,
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    }
  ]
}
EOF
)

    if post_batch "Agent with tool use" "$payload"; then
        TOTAL_RUNS=$((TOTAL_RUNS + 4))
        ROOT_RUN_IDS+=("$parent_id")
        return 0
    fi
    return 1
}

##############################################################################
# Function: create_multi_step
# Description: Creates chain → chain → llm trace (3 runs)
#              Enriched with token usage, metadata, events
##############################################################################
create_multi_step() {
    local parent_id sub_chain_id llm_id trace_id
    parent_id=$(gen_uuid)
    sub_chain_id=$(gen_uuid)
    llm_id=$(gen_uuid)
    trace_id="$parent_id"

    local ts_start ts_sub_start ts_llm_start ts_llm_first ts_llm_end ts_sub_end ts_end
    ts_start=$(iso_timestamp 8000)
    ts_sub_start=$(iso_timestamp 8100)
    ts_llm_start=$(iso_timestamp 8200)
    ts_llm_first=$(iso_timestamp 8400)
    ts_llm_end=$(iso_timestamp 9000)
    ts_sub_end=$(iso_timestamp 9100)
    ts_end=$(iso_timestamp 9200)

    local parent_dotted sub_dotted llm_dotted
    parent_dotted=$(dotted_order "$ts_start" "$parent_id")
    sub_dotted=$(dotted_order "$ts_sub_start" "$sub_chain_id" "$parent_dotted")
    llm_dotted=$(dotted_order "$ts_llm_start" "$llm_id" "$sub_dotted")

    local conv_id user_id
    conv_id=$(gen_uuid)
    user_id="user-$(( RANDOM % 1000 ))"

    local payload
    payload=$(cat <<EOF
{
  "post": [
    {
      "id": "${parent_id}",
      "name": "SummarizeAndTranslate",
      "run_type": "chain",
      "inputs": {"text": "LangSmith is a platform for building production-grade LLM applications. It provides tools for debugging, testing, evaluating, and monitoring LLM apps.", "target_language": "Spanish"},
      "outputs": {"translated_summary": "LangSmith es una plataforma para construir aplicaciones LLM de nivel de producci\u00f3n con herramientas de depuraci\u00f3n, pruebas y monitoreo."},
      "start_time": "${ts_start}",
      "end_time": "${ts_end}",
      "trace_id": "${trace_id}",
      "dotted_order": "${parent_dotted}",
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly", "multi-step"],
      "extra": {
        "metadata": {
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    },
    {
      "id": "${sub_chain_id}",
      "name": "TranslationChain",
      "run_type": "chain",
      "parent_run_id": "${parent_id}",
      "trace_id": "${trace_id}",
      "dotted_order": "${sub_dotted}",
      "inputs": {"text": "LangSmith is a platform for building production-grade LLM applications with debugging, testing, and monitoring tools.", "language": "Spanish"},
      "outputs": {"translation": "LangSmith es una plataforma para construir aplicaciones LLM de nivel de producci\u00f3n con herramientas de depuraci\u00f3n, pruebas y monitoreo."},
      "start_time": "${ts_sub_start}",
      "end_time": "${ts_sub_end}",
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly"],
      "extra": {
        "metadata": {
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    },
    {
      "id": "${llm_id}",
      "name": "gpt-4o-mini",
      "run_type": "llm",
      "parent_run_id": "${sub_chain_id}",
      "trace_id": "${trace_id}",
      "dotted_order": "${llm_dotted}",
      "inputs": {"messages": [{"role": "system", "content": "Translate the following text to Spanish."}, {"role": "user", "content": "LangSmith is a platform for building production-grade LLM applications with debugging, testing, and monitoring tools."}]},
      "outputs": {"choices": [{"message": {"role": "assistant", "content": "LangSmith es una plataforma para construir aplicaciones LLM de nivel de producci\u00f3n con herramientas de depuraci\u00f3n, pruebas y monitoreo."}}]},
      "start_time": "${ts_llm_start}",
      "end_time": "${ts_llm_end}",
      "first_token_time": "${ts_llm_first}",
      "prompt_tokens": 38,
      "completion_tokens": 25,
      "total_tokens": 63,
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly"],
      "events": [
        {"name": "start", "time": "${ts_llm_start}"},
        {"name": "new_token", "time": "${ts_llm_first}"},
        {"name": "end", "time": "${ts_llm_end}"}
      ],
      "extra": {
        "metadata": {
          "ls_provider": "openai",
          "ls_model_name": "gpt-4o-mini",
          "ls_model_type": "chat",
          "ls_temperature": 0.5,
          "ls_max_tokens": 512,
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    }
  ]
}
EOF
)

    if post_batch "Multi-step chain" "$payload"; then
        TOTAL_RUNS=$((TOTAL_RUNS + 3))
        ROOT_RUN_IDS+=("$parent_id")
        return 0
    fi
    return 1
}

##############################################################################
# Function: create_error_trace
# Description: Creates chain → llm (with error) trace (2 runs)
##############################################################################
create_error_trace() {
    local parent_id child_id trace_id
    parent_id=$(gen_uuid)
    child_id=$(gen_uuid)
    trace_id="$parent_id"

    local ts_start ts_child_start ts_child_end ts_end
    ts_start=$(iso_timestamp 10000)
    ts_child_start=$(iso_timestamp 10100)
    ts_child_end=$(iso_timestamp 10500)
    ts_end=$(iso_timestamp 10600)

    local parent_dotted child_dotted
    parent_dotted=$(dotted_order "$ts_start" "$parent_id")
    child_dotted=$(dotted_order "$ts_child_start" "$child_id" "$parent_dotted")

    local conv_id user_id
    conv_id=$(gen_uuid)
    user_id="user-$(( RANDOM % 1000 ))"

    local payload
    payload=$(cat <<EOF
{
  "post": [
    {
      "id": "${parent_id}",
      "name": "FailingChain",
      "run_type": "chain",
      "inputs": {"question": "Generate an image of a cat"},
      "error": "RateLimitError: Rate limit exceeded. Please retry after 30 seconds.",
      "start_time": "${ts_start}",
      "end_time": "${ts_end}",
      "trace_id": "${trace_id}",
      "dotted_order": "${parent_dotted}",
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly", "error"],
      "extra": {
        "metadata": {
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    },
    {
      "id": "${child_id}",
      "name": "dall-e-3",
      "run_type": "llm",
      "parent_run_id": "${parent_id}",
      "trace_id": "${trace_id}",
      "dotted_order": "${child_dotted}",
      "inputs": {"messages": [{"role": "user", "content": "Generate an image of a cat"}]},
      "error": "RateLimitError: Rate limit exceeded. Please retry after 30 seconds.",
      "start_time": "${ts_child_start}",
      "end_time": "${ts_child_end}",
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly"],
      "extra": {
        "metadata": {
          "ls_provider": "openai",
          "ls_model_name": "dall-e-3",
          "ls_model_type": "chat",
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    }
  ]
}
EOF
)

    if post_batch "Error scenario" "$payload"; then
        TOTAL_RUNS=$((TOTAL_RUNS + 2))
        ROOT_RUN_IDS+=("$parent_id")
        return 0
    fi
    return 1
}

##############################################################################
# Function: create_embedding_pipeline
# Description: Creates chain → embedding trace (2 runs)
#              Exercises the embedding run type in UI
##############################################################################
create_embedding_pipeline() {
    local parent_id embed_id trace_id
    parent_id=$(gen_uuid)
    embed_id=$(gen_uuid)
    trace_id="$parent_id"

    local ts_start ts_embed_start ts_embed_end ts_end
    ts_start=$(iso_timestamp 12000)
    ts_embed_start=$(iso_timestamp 12100)
    ts_embed_end=$(iso_timestamp 12400)
    ts_end=$(iso_timestamp 12500)

    local parent_dotted embed_dotted
    parent_dotted=$(dotted_order "$ts_start" "$parent_id")
    embed_dotted=$(dotted_order "$ts_embed_start" "$embed_id" "$parent_dotted")

    local conv_id user_id
    conv_id=$(gen_uuid)
    user_id="user-$(( RANDOM % 1000 ))"

    local payload
    payload=$(cat <<EOF
{
  "post": [
    {
      "id": "${parent_id}",
      "name": "EmbeddingPipeline",
      "run_type": "chain",
      "inputs": {"texts": ["LangSmith is a platform for LLM apps", "Tracing helps debug AI applications", "Evaluations measure LLM quality"]},
      "outputs": {"summary": "Embedded 3 texts into 1536-dimensional vectors"},
      "start_time": "${ts_start}",
      "end_time": "${ts_end}",
      "trace_id": "${trace_id}",
      "dotted_order": "${parent_dotted}",
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly", "embedding"],
      "extra": {
        "metadata": {
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    },
    {
      "id": "${embed_id}",
      "name": "text-embedding-3-small",
      "run_type": "embedding",
      "parent_run_id": "${parent_id}",
      "trace_id": "${trace_id}",
      "dotted_order": "${embed_dotted}",
      "inputs": {"texts": ["LangSmith is a platform for LLM apps", "Tracing helps debug AI applications", "Evaluations measure LLM quality"]},
      "outputs": {"embeddings_count": 3, "dimensions": 1536, "model": "text-embedding-3-small"},
      "start_time": "${ts_embed_start}",
      "end_time": "${ts_embed_end}",
      "prompt_tokens": 24,
      "total_tokens": 24,
      "session_name": "${PROJECT_NAME}",
      "tags": ["synthetic", "smith-fly"],
      "extra": {
        "metadata": {
          "ls_provider": "openai",
          "ls_model_name": "text-embedding-3-small",
          "ls_model_type": "embeddings",
          "source": "smith-fly-populate",
          "conversation_id": "${conv_id}",
          "user_id": "${user_id}"
        }
      }
    }
  ]
}
EOF
)

    if post_batch "Embedding pipeline" "$payload"; then
        TOTAL_RUNS=$((TOTAL_RUNS + 2))
        ROOT_RUN_IDS+=("$parent_id")
        return 0
    fi
    return 1
}

# ==============================================================================
# Step 6: Create Feedback
# ==============================================================================

FEEDBACK_COUNT=0

##############################################################################
# Function: post_feedback
# Description: POST a single feedback item to LangSmith
# Args: run_id, key, score, comment (optional)
# Returns: 0 on success, 1 on failure
##############################################################################
post_feedback() {
    local run_id="$1"
    local key="$2"
    local score="$3"
    local comment="${4:-}"

    local feedback_id
    feedback_id=$(gen_uuid)

    local payload
    if [ -n "$comment" ]; then
        payload=$(cat <<EOF
{
  "id": "${feedback_id}",
  "run_id": "${run_id}",
  "key": "${key}",
  "score": ${score},
  "comment": "${comment}"
}
EOF
)
    else
        payload=$(cat <<EOF
{
  "id": "${feedback_id}",
  "run_id": "${run_id}",
  "key": "${key}",
  "score": ${score}
}
EOF
)
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${ENDPOINT}/api/v1/feedback" \
        -H "X-Api-Key: ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        2>/dev/null) || true

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "202" ]; then
        FEEDBACK_COUNT=$((FEEDBACK_COUNT + 1))
        return 0
    else
        log WARNING "Feedback POST for run '${run_id}' key '${key}' returned HTTP ${http_code}"
        return 1
    fi
}

create_feedback() {
    # We need at least 5 root run IDs
    local num_roots=${#ROOT_RUN_IDS[@]}
    if [ "$num_roots" -lt 5 ]; then
        log WARNING "Only ${num_roots} root runs available (need 5 for full feedback). Skipping some."
    fi

    # Simple Chat → thumbs up
    if [ "$num_roots" -ge 1 ]; then
        post_feedback "${ROOT_RUN_IDS[0]}" "user_rating" 1 || true
    fi

    # RAG Pipeline → correctness score + comment
    if [ "$num_roots" -ge 2 ]; then
        post_feedback "${ROOT_RUN_IDS[1]}" "correctness" 0.95 "Answer accurately describes photosynthesis process" || true
    fi

    # Agent + Tool → helpfulness score + comment
    if [ "$num_roots" -ge 3 ]; then
        post_feedback "${ROOT_RUN_IDS[2]}" "helpfulness" 0.8 "Successfully used weather tool and provided clear answer" || true
    fi

    # Multi-step → quality categorical (1-5)
    if [ "$num_roots" -ge 4 ]; then
        post_feedback "${ROOT_RUN_IDS[3]}" "quality" 4 || true
    fi

    # Error trace → thumbs down + comment
    if [ "$num_roots" -ge 5 ]; then
        post_feedback "${ROOT_RUN_IDS[4]}" "user_rating" 0 "Request failed due to rate limiting" || true
    fi
}

# ==============================================================================
# Step 7: Create Dataset with Examples
# ==============================================================================

DATASET_ID=""
EXAMPLE_COUNT=0

create_dataset() {
    # Create the dataset
    local ds_payload
    ds_payload=$(cat <<EOF
{
  "name": "smith-fly-demo-dataset",
  "description": "Demo QA dataset created by smith-fly populate script",
  "data_type": "kv"
}
EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${ENDPOINT}/api/v1/datasets" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Tenant-Id: ${TENANT_ID}" \
        ${ORG_ID:+-H "X-Organization-Id: ${ORG_ID}"} \
        -d "$ds_payload" \
        2>/dev/null) || true

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "409" ]; then
        # Dataset already exists — look it up and reuse
        local lookup_resp
        lookup_resp=$(curl -s "${ENDPOINT}/api/v1/datasets?name=smith-fly-demo-dataset" \
            -H "Authorization: Bearer ${JWT_TOKEN}" \
            -H "X-Tenant-Id: ${TENANT_ID}" \
            ${ORG_ID:+-H "X-Organization-Id: ${ORG_ID}"} \
            2>/dev/null) || true
        DATASET_ID=$(echo "$lookup_resp" | json_val '.[0].id')
        if [ -z "$DATASET_ID" ] || [ "$DATASET_ID" = "null" ]; then
            log WARNING "Dataset exists but could not look up its ID. Skipping examples."
            return 1
        fi
    elif [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        DATASET_ID=$(echo "$body" | json_val '.id')
        if [ -z "$DATASET_ID" ] || [ "$DATASET_ID" = "null" ]; then
            log WARNING "Could not extract dataset ID from response."
            return 1
        fi
    else
        log WARNING "Dataset creation returned HTTP ${http_code}. Skipping."
        return 1
    fi

    # Add 5 QA examples via bulk endpoint
    local examples_payload
    examples_payload=$(cat <<EOF
[
  {
    "dataset_id": "${DATASET_ID}",
    "inputs": {"question": "What is LangSmith?"},
    "outputs": {"answer": "LangSmith is a platform for building production-grade LLM applications with tools for debugging, testing, evaluating, and monitoring."},
    "metadata": {"difficulty": "easy", "split": "train", "source": "smith-fly"}
  },
  {
    "dataset_id": "${DATASET_ID}",
    "inputs": {"question": "How do you create a LangGraph agent?"},
    "outputs": {"answer": "Define a StateGraph with nodes for each step, add edges for the control flow, compile it, and invoke with initial state."},
    "metadata": {"difficulty": "medium", "split": "train", "source": "smith-fly"}
  },
  {
    "dataset_id": "${DATASET_ID}",
    "inputs": {"question": "What is the difference between tracing and evaluation?"},
    "outputs": {"answer": "Tracing captures the execution flow of your LLM application at runtime, while evaluation systematically tests your application against a dataset with scoring criteria."},
    "metadata": {"difficulty": "medium", "split": "test", "source": "smith-fly"}
  },
  {
    "dataset_id": "${DATASET_ID}",
    "inputs": {"question": "How do you implement RAG with LangChain?"},
    "outputs": {"answer": "Load documents, split into chunks, embed and store in a vector store, create a retriever, and chain it with an LLM using a prompt template."},
    "metadata": {"difficulty": "hard", "split": "test", "source": "smith-fly"}
  },
  {
    "dataset_id": "${DATASET_ID}",
    "inputs": {"question": "What is prompt caching?"},
    "outputs": {"answer": "Prompt caching stores and reuses processed prompt prefixes to reduce latency and cost for repeated prompt patterns in LLM applications."},
    "metadata": {"difficulty": "easy", "split": "train", "source": "smith-fly"}
  }
]
EOF
)

    local ex_http_code
    ex_http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${ENDPOINT}/api/v1/examples/bulk" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Tenant-Id: ${TENANT_ID}" \
        ${ORG_ID:+-H "X-Organization-Id: ${ORG_ID}"} \
        -d "$examples_payload" \
        2>/dev/null) || true

    if [ "$ex_http_code" = "200" ] || [ "$ex_http_code" = "201" ]; then
        EXAMPLE_COUNT=5
        return 0
    else
        log WARNING "Examples bulk POST returned HTTP ${ex_http_code}."
        return 1
    fi
}

# ==============================================================================
# Step 8: Create Annotation Queue
# ==============================================================================

QUEUE_ID=""
QUEUED_RUNS=0

create_annotation_queue() {
    # Create the annotation queue with rubric
    local queue_payload
    queue_payload=$(cat <<EOF
{
  "name": "smith-fly-review-queue",
  "description": "Demo annotation queue created by smith-fly populate script for reviewing traces",
  "rubric_items": [
    {
      "feedback_key": "correctness",
      "description": "Is the response factually correct and accurate?",
      "score_descriptions": {"0": "Incorrect", "1": "Correct"}
    },
    {
      "feedback_key": "helpfulness",
      "description": "Does the response adequately address the user's question?",
      "score_descriptions": {"0": "Not helpful", "1": "Helpful"}
    }
  ]
}
EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${ENDPOINT}/api/v1/annotation-queues" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Tenant-Id: ${TENANT_ID}" \
        ${ORG_ID:+-H "X-Organization-Id: ${ORG_ID}"} \
        -d "$queue_payload" \
        2>/dev/null) || true

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        QUEUE_ID=$(echo "$body" | json_val '.id')
    elif [ "$http_code" = "400" ] || [ "$http_code" = "409" ]; then
        # Queue may already exist — look it up
        local lookup_resp
        lookup_resp=$(curl -s "${ENDPOINT}/api/v1/annotation-queues" \
            -H "Authorization: Bearer ${JWT_TOKEN}" \
            -H "X-Tenant-Id: ${TENANT_ID}" \
            ${ORG_ID:+-H "X-Organization-Id: ${ORG_ID}"} \
            2>/dev/null) || true
        QUEUE_ID=$(echo "$lookup_resp" | json_val '.[0].id')
        if [ -z "$QUEUE_ID" ] || [ "$QUEUE_ID" = "null" ]; then
            log WARNING "Annotation queue may exist but could not look up ID. Skipping."
            return 1
        fi
    else
        log WARNING "Annotation queue creation returned HTTP ${http_code}. Skipping."
        return 1
    fi

    if [ -z "$QUEUE_ID" ] || [ "$QUEUE_ID" = "null" ]; then
        log WARNING "Could not extract annotation queue ID from response."
        return 1
    fi

    # Add up to 3 root run IDs to the queue
    local num_roots=${#ROOT_RUN_IDS[@]}
    local max_queue=3
    if [ "$num_roots" -lt "$max_queue" ]; then
        max_queue=$num_roots
    fi

    local run_ids_json=""
    for i in $(seq 0 $((max_queue - 1))); do
        if [ -n "$run_ids_json" ]; then
            run_ids_json="${run_ids_json},"
        fi
        run_ids_json="${run_ids_json}\"${ROOT_RUN_IDS[$i]}\""
    done

    local add_runs_payload="[${run_ids_json}]"

    local ar_http_code
    ar_http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${ENDPOINT}/api/v1/annotation-queues/${QUEUE_ID}/runs" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Tenant-Id: ${TENANT_ID}" \
        ${ORG_ID:+-H "X-Organization-Id: ${ORG_ID}"} \
        -d "$add_runs_payload" \
        2>/dev/null) || true

    if [ "$ar_http_code" = "200" ] || [ "$ar_http_code" = "201" ] || [ "$ar_http_code" = "204" ]; then
        QUEUED_RUNS=$max_queue
        return 0
    else
        log WARNING "Adding runs to annotation queue returned HTTP ${ar_http_code}."
        return 1
    fi
}

# ==============================================================================
# Step 8: Create Prompt
# ==============================================================================

PROMPT_REPO_HANDLE="smith-fly-demo-prompt"

create_prompt() {
    # Step 1: Create the prompt repo
    local repo_payload
    repo_payload=$(cat <<'REPO_EOF'
{
  "repo_handle": "smith-fly-demo-prompt",
  "description": "Demo structured chat prompt created by smith-fly",
  "is_public": false,
  "tags": ["smith-fly", "demo"]
}
REPO_EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${ENDPOINT}/api/v1/repos/" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Tenant-Id: ${TENANT_ID}" \
        ${ORG_ID:+-H "X-Organization-Id: ${ORG_ID}"} \
        -d "$repo_payload" \
        2>/dev/null) || true

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ] && [ "$http_code" != "409" ]; then
        log WARNING "Prompt repo creation returned HTTP ${http_code}."
        return 1
    fi

    # Resolve the owner handle for the commit endpoint
    local owner="$TENANT_HANDLE"
    if [ -z "$owner" ] || [ "$owner" = "null" ]; then
        # Fallback: try to extract from the repo response
        owner=$(echo "$body" | json_val '.owner' 2>/dev/null || true)
    fi
    if [ -z "$owner" ] || [ "$owner" = "null" ]; then
        # Last resort: look up the repo
        local lookup_resp
        lookup_resp=$(curl -s "${ENDPOINT}/api/v1/repos/" \
            -H "Authorization: Bearer ${JWT_TOKEN}" \
            -H "X-Tenant-Id: ${TENANT_ID}" \
            ${ORG_ID:+-H "X-Organization-Id: ${ORG_ID}"} \
            2>/dev/null) || true
        owner=$(echo "$lookup_resp" | json_val '.[0].owner' 2>/dev/null || true)
    fi
    if [ -z "$owner" ] || [ "$owner" = "null" ]; then
        log WARNING "Could not determine owner handle for prompt commit. Skipping."
        return 1
    fi

    # Step 2: Create a commit with the ChatPromptTemplate manifest
    local commit_payload
    commit_payload=$(cat <<'COMMIT_EOF'
{
  "manifest": {
    "lc": 1,
    "type": "constructor",
    "id": ["langchain", "prompts", "chat", "ChatPromptTemplate"],
    "kwargs": {
      "messages": [
        {
          "lc": 1,
          "type": "constructor",
          "id": ["langchain", "prompts", "chat", "SystemMessagePromptTemplate"],
          "kwargs": {
            "prompt": {
              "lc": 1,
              "type": "constructor",
              "id": ["langchain", "prompts", "prompt", "PromptTemplate"],
              "kwargs": {
                "template": "You are a helpful customer support assistant for LangSmith. Help users understand tracing, evaluation, datasets, and prompt management. Be concise and provide code examples when relevant.",
                "input_variables": [],
                "template_format": "f-string"
              }
            }
          }
        },
        {
          "lc": 1,
          "type": "constructor",
          "id": ["langchain", "prompts", "chat", "HumanMessagePromptTemplate"],
          "kwargs": {
            "prompt": {
              "lc": 1,
              "type": "constructor",
              "id": ["langchain", "prompts", "prompt", "PromptTemplate"],
              "kwargs": {
                "template": "{question}",
                "input_variables": ["question"],
                "template_format": "f-string"
              }
            }
          }
        }
      ],
      "input_variables": ["question"]
    }
  },
  "parent_commit": null
}
COMMIT_EOF
)

    local commit_response
    commit_response=$(curl -s -w "\n%{http_code}" \
        -X POST "${ENDPOINT}/api/v1/commits/${owner}/${PROMPT_REPO_HANDLE}" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Tenant-Id: ${TENANT_ID}" \
        ${ORG_ID:+-H "X-Organization-Id: ${ORG_ID}"} \
        -d "$commit_payload" \
        2>/dev/null) || true

    local commit_http_code
    commit_http_code=$(echo "$commit_response" | tail -1)

    if [ "$commit_http_code" = "200" ] || [ "$commit_http_code" = "201" ]; then
        return 0
    elif [ "$commit_http_code" = "409" ]; then
        # Identical manifest already committed — that's fine
        log INFO "Prompt manifest already committed (409). Continuing."
        return 0
    else
        log WARNING "Prompt commit returned HTTP ${commit_http_code}."
        return 1
    fi
}

# ==============================================================================
# Verify Traces
# ==============================================================================

verify_traces() {
    # Verify by checking the session/project exists via GET /api/v1/sessions?name=
    local response
    response=$(curl -s "${ENDPOINT}/api/v1/sessions?name=${PROJECT_NAME}" \
        -H "X-Api-Key: ${API_KEY}" \
        2>/dev/null) || true

    # Check if we got a valid response with at least one session
    local count
    if command -v jq &>/dev/null; then
        count=$(echo "$response" | jq 'if type == "array" then length else 0 end' 2>/dev/null || echo "0")
    elif command -v python3 &>/dev/null; then
        count=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo "0")
    else
        if echo "$response" | grep -q '"id"'; then
            count=1
        else
            count=0
        fi
    fi

    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    parse_args "$@"

    echo ""
    echo -e "${BLUE}==========================================================================${NC}"
    echo -e "${BLUE}Populating LangSmith with test data...${NC}"
    echo -e "${BLUE}==========================================================================${NC}"

    # Step 1: Wait for ready
    step_start "1/9" "Waiting for LangSmith to be ready..."
    if wait_for_ready; then
        step_ok
    else
        step_fail
        exit 1
    fi

    # Step 2: Login
    step_start "2/9" "Logging in as ${EMAIL}..."
    if do_login; then
        step_ok
    else
        step_fail
        exit 1
    fi

    # Step 3: Get tenant info + Create API key
    step_start "3/9" "Creating API key..."
    get_tenant_info
    create_api_key
    step_ok

    # Step 4: Create traces
    echo -e "  [4/9] Creating synthetic traces..."
    echo -e "        Project: ${GREEN}${PROJECT_NAME}${NC}"

    local round failed=0
    for round in $(seq 1 "$TRACE_COUNT"); do
        if [ "$TRACE_COUNT" -gt 1 ]; then
            echo -e "        ${BLUE}--- Round ${round}/${TRACE_COUNT} ---${NC}"
        fi

        printf "        - %-38s" "Simple chat (+ tokens, metadata)"
        if create_simple_chat; then step_ok; else step_fail; failed=$((failed + 1)); fi

        printf "        - %-38s" "RAG pipeline (+ tokens, metadata)"
        if create_rag_pipeline; then step_ok; else step_fail; failed=$((failed + 1)); fi

        printf "        - %-38s" "Agent with tool use (+ tokens)"
        if create_agent_tool; then step_ok; else step_fail; failed=$((failed + 1)); fi

        printf "        - %-38s" "Multi-step chain (+ tokens)"
        if create_multi_step; then step_ok; else step_fail; failed=$((failed + 1)); fi

        printf "        - %-38s" "Error scenario"
        if create_error_trace; then step_ok; else step_fail; failed=$((failed + 1)); fi

        printf "        - %-38s" "Embedding pipeline"
        if create_embedding_pipeline; then step_ok; else step_fail; failed=$((failed + 1)); fi
    done

    if [ "$failed" -gt 0 ]; then
        log WARNING "${failed} trace type(s) failed to create."
    fi

    # Wait for async run ingestion before posting feedback/annotations
    # The batch endpoint returns 202 (accepted) — runs need time to be indexed
    sleep 5

    # Step 5: Add feedback (non-critical)
    step_start "5/9" "Adding feedback..."
    if create_feedback; then
        step_ok "(${FEEDBACK_COUNT} items)"
    else
        step_warn
        log WARNING "Feedback creation had errors. Continuing."
    fi

    # Step 6: Create dataset (non-critical)
    step_start "6/9" "Creating dataset..."
    if create_dataset; then
        step_ok "(${EXAMPLE_COUNT} examples)"
    else
        step_warn
        log WARNING "Dataset creation failed. Continuing."
    fi

    # Step 7: Create annotation queue (non-critical)
    step_start "7/9" "Creating annotation queue..."
    if create_annotation_queue; then
        step_ok "(${QUEUED_RUNS} runs queued)"
    else
        step_warn
        log WARNING "Annotation queue creation failed. Continuing."
    fi

    # Step 8: Create prompt (non-critical)
    step_start "8/9" "Creating prompt..."
    if create_prompt; then
        step_ok "(${PROMPT_REPO_HANDLE})"
    else
        step_warn
        log WARNING "Prompt creation failed. Continuing."
    fi

    # Step 9: Verify
    step_start "9/9" "Verifying traces..."
    # Brief pause to let the backend process the batch
    sleep 2
    if verify_traces; then
        step_ok
    else
        step_warn
        log WARNING "Could not verify traces. They may still be processing."
    fi

    # Summary
    echo ""
    echo -e "  ${GREEN}Done!${NC} ${TOTAL_RUNS} runs created in project \"${PROJECT_NAME}\""
    if [ "$FEEDBACK_COUNT" -gt 0 ]; then
        echo -e "  Feedback:         ${FEEDBACK_COUNT} items"
    fi
    if [ -n "$DATASET_ID" ] && [ "$DATASET_ID" != "null" ]; then
        echo -e "  Dataset:          smith-fly-demo-dataset (${EXAMPLE_COUNT} examples)"
    fi
    if [ -n "$QUEUE_ID" ] && [ "$QUEUE_ID" != "null" ]; then
        echo -e "  Annotation Queue: smith-fly-review-queue (${QUEUED_RUNS} runs)"
    fi
    echo -e "  Prompt:           ${PROMPT_REPO_HANDLE}"
    echo ""
    echo -e "  API Key:  ${API_KEY}"
    echo -e "  Endpoint: ${ENDPOINT}"
    echo ""
    echo -e "  Open: ${ENDPOINT} → project \"${PROJECT_NAME}\""
    echo -e "${BLUE}==========================================================================${NC}"
    echo ""
}

main "$@"
