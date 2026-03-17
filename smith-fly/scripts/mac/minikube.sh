#!/bin/bash

# ==============================================================================
# Smart Minikube Starter for macOS
#
# Usage:
#   ./minikube.sh up     - Evaluate resources and start Minikube
#   ./minikube.sh down   - Stop Minikube
#
# This script automatically detects current system resource usage and allocates
# the remaining available resources to Minikube, while keeping a safety buffer
# for the host operating system to remain responsive.
#
# No manual configuration required - everything is calculated dynamically.
# ==============================================================================

# --- Safety Buffers (internal defaults) ---
# These ensure macOS stays responsive while giving Minikube adequate resources
SAFETY_BUFFER_GB=2       # Extra GB buffer on top of current usage for macOS headroom
MIN_MINIKUBE_MEM_GB=4    # Minimum GB required for Minikube to be useful
MIN_MINIKUBE_CPUS=2      # Minimum CPUs required for Minikube

# Use ANSI color codes for better output
C_BLUE="\033[0;34m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_RED="\033[0;31m"
C_CYAN="\033[0;36m"
C_NONE="\033[0m"

# ==============================================================================
# Helper Functions
# ==============================================================================

get_total_memory_gb() {
    local total_bytes
    total_bytes=$(sysctl -n hw.memsize)
    echo $((total_bytes / 1024 / 1024 / 1024))
}

get_total_cpus() {
    sysctl -n hw.ncpu
}

get_wired_memory_gb() {
    # Get "wired" memory - memory that CANNOT be released by macOS
    # This is the truly unavailable memory (kernel, drivers, etc.)
    local vm_output page_size wired wired_bytes
    
    vm_output=$(vm_stat)
    
    # Get page size from first line (e.g., "page size of 16384 bytes")
    page_size=$(echo "$vm_output" | head -1 | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/) print $i}')
    page_size=${page_size:-16384}
    
    # Get wired pages (last field, remove trailing period)
    wired=$(echo "$vm_output" | awk '/Pages wired down/ {gsub(/\./,"",$NF); print $NF}')
    wired=${wired:-0}
    
    wired_bytes=$((wired * page_size))
    echo $((wired_bytes / 1073741824))
}

get_app_memory_gb() {
    # Get memory actively used by applications (wired + active only)
    # We exclude compressed memory as it's already accounted for in active
    # and macOS can release it under pressure
    local vm_output page_size wired active used_pages used_bytes
    
    vm_output=$(vm_stat)
    
    page_size=$(echo "$vm_output" | head -1 | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/) print $i}')
    page_size=${page_size:-16384}
    
    wired=$(echo "$vm_output" | awk '/Pages wired down/ {gsub(/\./,"",$NF); print $NF}')
    active=$(echo "$vm_output" | awk '/Pages active/ {gsub(/\./,"",$NF); print $NF}')
    
    wired=${wired:-0}
    active=${active:-0}
    
    used_pages=$((wired + active))
    used_bytes=$((used_pages * page_size))
    
    echo $((used_bytes / 1073741824))
}

get_cpu_load() {
    # Get 1-minute load average
    local load_avg
    load_avg=$(sysctl -n vm.loadavg | awk '{print $2}')
    # Round to integer
    printf "%.0f" "$load_avg"
}

get_cpu_usage_percent() {
    # Get CPU usage percentage using top
    # Format: "CPU usage: 12.34% user, 5.67% sys, 81.99% idle"
    local idle_pct usage_pct
    idle_pct=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ {gsub(/%/,"",$7); print int($7)}')
    idle_pct=${idle_pct:-80}
    usage_pct=$((100 - idle_pct))
    echo "$usage_pct"
}

get_docker_memory_gb() {
    # Get Docker Desktop's memory limit from settings
    # Returns 0 if Docker is not running or settings can't be read
    local docker_settings docker_mem_bytes docker_mem_gb
    
    docker_settings="$HOME/Library/Group Containers/group.com.docker/settings.json"
    
    if [ -f "$docker_settings" ]; then
        # Extract memoryMiB from Docker settings
        docker_mem_mb=$(grep -o '"memoryMiB"[[:space:]]*:[[:space:]]*[0-9]*' "$docker_settings" 2>/dev/null | grep -o '[0-9]*$')
        if [ -n "$docker_mem_mb" ] && [ "$docker_mem_mb" -gt 0 ]; then
            echo $((docker_mem_mb / 1024))
            return
        fi
    fi
    
    # Fallback: try to get from docker info
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        docker_mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null)
        if [ -n "$docker_mem_bytes" ] && [ "$docker_mem_bytes" -gt 0 ]; then
            echo $((docker_mem_bytes / 1024 / 1024 / 1024))
            return
        fi
    fi
    
    echo "0"
}

get_docker_cpus() {
    # Get Docker Desktop's CPU limit from settings
    local docker_settings docker_cpus
    
    docker_settings="$HOME/Library/Group Containers/group.com.docker/settings.json"
    
    if [ -f "$docker_settings" ]; then
        docker_cpus=$(grep -o '"cpus"[[:space:]]*:[[:space:]]*[0-9]*' "$docker_settings" 2>/dev/null | grep -o '[0-9]*$')
        if [ -n "$docker_cpus" ] && [ "$docker_cpus" -gt 0 ]; then
            echo "$docker_cpus"
            return
        fi
    fi
    
    # Fallback: try to get from docker info
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        docker_cpus=$(docker info --format '{{.NCPU}}' 2>/dev/null)
        if [ -n "$docker_cpus" ] && [ "$docker_cpus" -gt 0 ]; then
            echo "$docker_cpus"
            return
        fi
    fi
    
    echo "0"
}

# ==============================================================================
# Command: up - Start Minikube with optimal resources
# ==============================================================================

cmd_up() {
    echo -e "${C_BLUE}### Smart Minikube Starter ###${C_NONE}"
    echo ""

    # 1. Detect total system resources
    echo -e "${C_CYAN}--> Detecting system resources...${C_NONE}"
    TOTAL_MEM_GB=$(get_total_memory_gb)
    TOTAL_CPUS=$(get_total_cpus)
    DOCKER_MEM_GB=$(get_docker_memory_gb)
    DOCKER_CPUS=$(get_docker_cpus)

    echo "    Total Physical Memory: ${TOTAL_MEM_GB} GB"
    echo "    Total CPU Cores: ${TOTAL_CPUS}"

    if [ "$DOCKER_MEM_GB" -gt 0 ]; then
        echo ""
        echo -e "    ${C_YELLOW}Docker Desktop Limits:${C_NONE}"
        echo "        Memory: ${DOCKER_MEM_GB} GB"
        echo "        CPUs:   ${DOCKER_CPUS} cores"
        echo -e "        ${C_YELLOW}^ Minikube cannot exceed these limits!${C_NONE}"
    fi
    echo ""

    # 2. Get current resource usage (for display purposes)
    echo -e "${C_CYAN}--> Analyzing current resource usage...${C_NONE}"
    WIRED_MEM_GB=$(get_wired_memory_gb)
    APP_MEM_GB=$(get_app_memory_gb)
    CPU_LOAD=$(get_cpu_load)
    CPU_USAGE_PCT=$(get_cpu_usage_percent)

    echo "    Memory locked by system (wired): ~${WIRED_MEM_GB} GB"
    echo -e "        ${C_YELLOW}^ Kernel, drivers, system processes - cannot be released${C_NONE}"
    echo "    Memory used by apps (active):    ~${APP_MEM_GB} GB"
    echo -e "        ${C_YELLOW}^ Your running apps (IDE, browser, etc.) - we protect this${C_NONE}"
    echo "    CPU load average: ${CPU_LOAD} (${CPU_USAGE_PCT}% usage)"
    echo ""

    # 3. Calculate resources to allocate to Minikube
    echo -e "${C_CYAN}--> Calculating optimal allocation...${C_NONE}"

    # Memory: Reserve current app usage + safety buffer for macOS
    # This ensures your running apps (IDE, browser, etc.) aren't starved
    HOST_NEEDS_GB=$((APP_MEM_GB + SAFETY_BUFFER_GB))

    # Cap Minikube at 50% of total RAM to always leave headroom for macOS
    MAX_MINIKUBE_MEM_GB=$((TOTAL_MEM_GB / 2))

    # Calculate what's left for Minikube
    MINIKUBE_MEM_GB=$((TOTAL_MEM_GB - HOST_NEEDS_GB))

    # Apply the 50% cap
    if [ "$MINIKUBE_MEM_GB" -gt "$MAX_MINIKUBE_MEM_GB" ]; then
        MINIKUBE_MEM_GB=$MAX_MINIKUBE_MEM_GB
    fi

    # Apply Docker Desktop memory limit (critical constraint!)
    DOCKER_LIMITED="no"
    if [ "$DOCKER_MEM_GB" -gt 0 ]; then
        if [ "$MINIKUBE_MEM_GB" -gt "$DOCKER_MEM_GB" ]; then
            MINIKUBE_MEM_GB=$DOCKER_MEM_GB
            DOCKER_LIMITED="yes"
        fi
        # Also cap MAX for display purposes
        if [ "$MAX_MINIKUBE_MEM_GB" -gt "$DOCKER_MEM_GB" ]; then
            MAX_MINIKUBE_MEM_GB=$DOCKER_MEM_GB
        fi
    fi

    # Ensure minimum allocation for Minikube to be functional
    if [ "$MINIKUBE_MEM_GB" -lt "$MIN_MINIKUBE_MEM_GB" ]; then
        MINIKUBE_MEM_GB=$MIN_MINIKUBE_MEM_GB
    fi

    # CPUs: Split 50/50 between host and Minikube (fair and simple)
    MINIKUBE_CPUS=$((TOTAL_CPUS / 2))

    # Apply Docker Desktop CPU limit
    if [ "$DOCKER_CPUS" -gt 0 ] && [ "$MINIKUBE_CPUS" -gt "$DOCKER_CPUS" ]; then
        MINIKUBE_CPUS=$DOCKER_CPUS
    fi

    # Ensure minimum CPU allocation
    if [ "$MINIKUBE_CPUS" -lt "$MIN_MINIKUBE_CPUS" ]; then
        MINIKUBE_CPUS=$MIN_MINIKUBE_CPUS
    fi

    # 4. Validation checks
    echo ""
    if [ "$MINIKUBE_MEM_GB" -lt "$MIN_MINIKUBE_MEM_GB" ]; then
        echo -e "${C_RED}Error: Not enough memory available for Minikube.${C_NONE}"
        echo "    Total memory: ${TOTAL_MEM_GB} GB"
        echo "    Current app usage: ${APP_MEM_GB} GB"
        echo "    Safety buffer: ${SAFETY_BUFFER_GB} GB"
        echo "    Available for Minikube: ${MINIKUBE_MEM_GB} GB"
        echo "    Required minimum: ${MIN_MINIKUBE_MEM_GB} GB"
        echo ""
        echo "Try closing some applications to free up memory."
        exit 1
    fi

    if [ "$MINIKUBE_CPUS" -lt "$MIN_MINIKUBE_CPUS" ]; then
        echo -e "${C_RED}Error: Not enough CPU cores on this machine.${C_NONE}"
        echo "    Total CPUs: ${TOTAL_CPUS}"
        echo "    Available for Minikube (50%): ${MINIKUBE_CPUS}"
        echo "    Required minimum: ${MIN_MINIKUBE_CPUS}"
        exit 1
    fi

    # 5. Display allocation summary
    HOST_RESERVED_MEM=$((TOTAL_MEM_GB - MINIKUBE_MEM_GB))
    HOST_RESERVED_CPUS=$((TOTAL_CPUS - MINIKUBE_CPUS))

    echo -e "${C_GREEN}=== Proposed Resource Allocation ===${C_NONE}"
    echo ""
    echo -e "    ${C_GREEN}[MINIKUBE - Kubernetes VM]${C_NONE}"
    echo -e "        Memory: ${C_GREEN}${MINIKUBE_MEM_GB} GB${C_NONE}"
    if [ "$DOCKER_LIMITED" = "yes" ]; then
        echo -e "            ${C_YELLOW}^ Limited by Docker Desktop (max ${DOCKER_MEM_GB} GB)${C_NONE}"
    else
        echo -e "            Calculation: min(available, 50% cap) = min($((TOTAL_MEM_GB - HOST_NEEDS_GB)), ${MAX_MINIKUBE_MEM_GB}) GB"
    fi
    echo -e "        CPUs:   ${C_GREEN}${MINIKUBE_CPUS} cores${C_NONE}"
    if [ "$DOCKER_CPUS" -gt 0 ] && [ "$MINIKUBE_CPUS" -eq "$DOCKER_CPUS" ]; then
        echo -e "            ${C_YELLOW}^ Limited by Docker Desktop (max ${DOCKER_CPUS} cores)${C_NONE}"
    else
        echo -e "            Calculation: 50% of ${TOTAL_CPUS} total cores"
    fi
    echo ""
    echo -e "    ${C_BLUE}[macOS - Your Apps]${C_NONE}"
    echo -e "        Memory: ${HOST_RESERVED_MEM} GB"
    echo -e "            Calculation: current app usage (${APP_MEM_GB} GB) + safety buffer (${SAFETY_BUFFER_GB} GB)"
    echo -e "        CPUs:   ${HOST_RESERVED_CPUS} cores"
    echo -e "            Calculation: remaining 50% of ${TOTAL_CPUS} total cores"
    echo ""
    if [ "$DOCKER_LIMITED" = "yes" ]; then
        echo -e "    ${C_RED}WARNING: Docker Desktop memory limit (${DOCKER_MEM_GB} GB) is the bottleneck!${C_NONE}"
        echo -e "    ${C_YELLOW}To allocate more memory to Minikube, increase Docker Desktop's memory:${C_NONE}"
        echo -e "    ${C_CYAN}    Docker Desktop -> Settings -> Resources -> Memory${C_NONE}"
        echo ""
    fi
    echo -e "    ${C_CYAN}Note: Minikube memory is reserved exclusively for the VM.${C_NONE}"
    echo -e "    ${C_CYAN}      macOS can still use swap if needed, but may slow down.${C_NONE}"
    echo ""

    # 6. Ask for confirmation
    echo -e "${C_YELLOW}WARNING: This will DELETE any existing Minikube cluster and create a new one.${C_NONE}"
    echo ""
    read -p "Proceed with these settings? (y/n): " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${C_YELLOW}Aborted by user.${C_NONE}"
        exit 0
    fi

    echo ""

    # 7. Stop and delete any existing cluster
    echo -e "${C_YELLOW}--> Deleting existing Minikube cluster (if any)...${C_NONE}"
    minikube delete 2>/dev/null || true
    echo ""

    # 8. Start the new Minikube cluster with the calculated resources
    echo -e "${C_BLUE}--> Starting new Minikube cluster...${C_NONE}"
    echo "    Command: minikube start --memory=${MINIKUBE_MEM_GB}g --cpus=${MINIKUBE_CPUS}"
    echo ""

    if ! minikube start --memory="${MINIKUBE_MEM_GB}g" --cpus="${MINIKUBE_CPUS}"; then
        echo -e "${C_RED}Error: Failed to start Minikube.${C_NONE}"
        exit 1
    fi

    echo ""

    # 9. Enable useful addons (only if not already enabled)
    echo -e "${C_BLUE}--> Checking addons...${C_NONE}"

    if ! minikube addons list | grep -q "ingress.*enabled"; then
        minikube addons enable ingress
        echo -e "${C_GREEN}    - Ingress (NGINX) enabled${C_NONE}"
    else
        echo -e "${C_YELLOW}    - Ingress (NGINX) already enabled${C_NONE}"
    fi

    if ! minikube addons list | grep -q "metrics-server.*enabled"; then
        minikube addons enable metrics-server
        echo -e "${C_GREEN}    - Metrics Server enabled${C_NONE}"
    else
        echo -e "${C_YELLOW}    - Metrics Server already enabled${C_NONE}"
    fi

    echo ""
    echo -e "${C_GREEN}### Minikube started successfully! ###${C_NONE}"
    echo ""
    echo "    Allocated: ${MINIKUBE_MEM_GB} GB RAM, ${MINIKUBE_CPUS} CPUs"
    echo ""
    echo "    Useful commands:"
    echo "        minikube status      - Check cluster status"
    echo "        minikube tunnel      - Access ingress on macOS"
    echo "        minikube dashboard   - Open Kubernetes dashboard"
    echo ""
}

# ==============================================================================
# Command: down - Stop Minikube
# ==============================================================================

cmd_down() {
    echo -e "${C_BLUE}### Stopping Minikube ###${C_NONE}"
    echo ""
    
    # Check if minikube is running
    if ! minikube status &>/dev/null; then
        echo -e "${C_YELLOW}Minikube is not running.${C_NONE}"
        exit 0
    fi
    
    echo -e "${C_CYAN}--> Stopping Minikube cluster...${C_NONE}"
    if minikube stop; then
        echo ""
        echo -e "${C_GREEN}### Minikube stopped successfully! ###${C_NONE}"
        echo ""
        echo "    To start again: ./minikube.sh up"
        echo ""
    else
        echo -e "${C_RED}Error: Failed to stop Minikube.${C_NONE}"
        exit 1
    fi
}

# ==============================================================================
# Usage Help
# ==============================================================================

show_usage() {
    echo -e "${C_BLUE}### Smart Minikube Manager ###${C_NONE}"
    echo ""
    echo "Usage: ./minikube.sh <command>"
    echo ""
    echo "Commands:"
    echo "    up      Evaluate system resources and start Minikube"
    echo "    down    Stop Minikube"
    echo ""
    echo "Examples:"
    echo "    ./minikube.sh up     # Start with optimal resources"
    echo "    ./minikube.sh down   # Stop the cluster"
    echo ""
}

# ==============================================================================
# Main Entry Point
# ==============================================================================

case "${1:-}" in
    up)
        cmd_up
        ;;
    down)
        cmd_down
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
