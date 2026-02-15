#!/usr/bin/env bash
set -uo pipefail

# homelab-healthcheck — Outputs JSON health report to stdout
# https://github.com/wickkit/homelab-healthcheck
VERSION="0.6.0"

# ─── Configuration (defaults, overridden by config file) ─────────────────────

DISK_WARN_PCT=80
DISK_CRIT_PCT=90
MEM_WARN_PCT=85
MEM_CRIT_PCT=95
SWAP_WARN_PCT=50
LOAD_WARN_MULTIPLIER=1
DOCKER_RESTART_WARN=3
STATE_DIR="/var/lib/homelab-healthcheck"
INSTALL_DIR="/opt/homelab-healthcheck"
CONFIG_FILE="${INSTALL_DIR}/config.env"

# Load config overrides if present
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

LAST_CHECK_FILE="$STATE_DIR/last_check"
HISTORY_DIR="$STATE_DIR/history"

# ─── Helpers ─────────────────────────────────────────────────────────────────

overall_status="ok"

escalate() {
    local level="$1"
    if [[ "$level" == "critical" ]]; then
        overall_status="critical"
    elif [[ "$level" == "warning" && "$overall_status" != "critical" ]]; then
        overall_status="warning"
    fi
}

json_escape() {
    python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))"
}

# Calculate disk usage trends from history
check_disk_trends() {
    local current_disks="$1"
    local trends="[]"
    local history_files=()

    # Gather last 7 days of history
    for i in $(seq 1 7); do
        local d
        d=$(date -d "$i days ago" +"%Y-%m-%d" 2>/dev/null || date -v-"${i}d" +"%Y-%m-%d" 2>/dev/null)
        [[ -n "$d" && -f "$HISTORY_DIR/${d}.json" ]] && history_files+=("$HISTORY_DIR/${d}.json")
    done

    # Need at least 2 days of history for trends
    if (( ${#history_files[@]} < 2 )); then
        echo '[]'
        return
    fi

    # For each current mount, calculate growth rate
    local mounts
    mounts=$(echo "$current_disks" | jq -r '.[].mount')

    while IFS= read -r mount; do
        [[ -z "$mount" ]] && continue
        local current_pct
        current_pct=$(echo "$current_disks" | jq -r --arg m "$mount" '.[] | select(.mount==$m) | .use_percent')

        # Get oldest available historical value for this mount
        local oldest_pct="" oldest_days=0
        for f in "${history_files[@]}"; do
            local hist_pct
            hist_pct=$(jq -r --arg m "$mount" '.checks.disk[] | select(.mount==$m) | .use_percent' "$f" 2>/dev/null)
            if [[ -n "$hist_pct" && "$hist_pct" != "null" ]]; then
                oldest_pct="$hist_pct"
                oldest_days=$(( oldest_days + 1 ))
            fi
        done

        if [[ -z "$oldest_pct" || "$oldest_days" -lt 2 ]]; then
            continue
        fi

        # Calculate daily growth rate
        local growth_per_day days_until_full=-1
        growth_per_day=$(awk "BEGIN {printf \"%.2f\", ($current_pct - $oldest_pct) / $oldest_days}")

        # Project days until full (only if growing)
        if (( $(awk "BEGIN {print ($growth_per_day > 0.01) ? 1 : 0}") )); then
            days_until_full=$(awk "BEGIN {printf \"%d\", (100 - $current_pct) / $growth_per_day}")
        fi

        local trend_status="ok"
        if (( days_until_full > 0 && days_until_full <= 14 )); then
            trend_status="critical"; escalate warning
        elif (( days_until_full > 0 && days_until_full <= 30 )); then
            trend_status="warning"; escalate warning
        fi

        trends=$(echo "$trends" | jq \
            --arg mount "$mount" \
            --argjson current "$current_pct" \
            --arg growth "$growth_per_day" \
            --argjson days_until_full "$days_until_full" \
            --arg status "$trend_status" \
            '. + [{"mount":$mount,"current_percent":$current,"growth_per_day":($growth|tonumber),"days_until_full":$days_until_full,"status":$status}]')
    done <<< "$mounts"

    echo "$trends"
}

# ─── Checks ──────────────────────────────────────────────────────────────────

check_disk() {
    local disks="[]"
    while IFS= read -r line; do
        local fs mount size used avail pct
        fs=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        avail=$(echo "$line" | awk '{print $4}')
        pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
        mount=$(echo "$line" | awk '{print $6}')

        local status="ok"
        if (( pct >= DISK_CRIT_PCT )); then
            status="critical"; escalate critical
        elif (( pct >= DISK_WARN_PCT )); then
            status="warning"; escalate warning
        fi

        disks=$(echo "$disks" | jq --arg fs "$fs" --arg mount "$mount" \
            --arg size "$size" --arg used "$used" --arg avail "$avail" \
            --argjson pct "$pct" --arg status "$status" \
            '. + [{"filesystem":$fs,"mount":$mount,"size":$size,"used":$used,"available":$avail,"use_percent":$pct,"status":$status}]')
    done < <(df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n+2)

    echo "$disks"
}

check_smart() {
    if ! command -v smartctl &>/dev/null; then
        echo '"smartctl not installed"'
        return
    fi

    local drives="[]"
    while IFS= read -r dev; do
        dev=$(echo "$dev" | awk '{print $1}')
        [[ -z "$dev" ]] && continue

        local smart_output
        smart_output=$(sudo smartctl -a "$dev" 2>/dev/null)

        local health
        health=$(echo "$smart_output" | grep -i "result\|SMART Health Status" | head -1 | sed 's/.*: *//')
        local status="ok"
        if [[ -z "$health" ]]; then
            health="unknown"
        elif ! echo "$health" | grep -qi "passed\|ok"; then
            status="critical"; escalate critical
        fi

        # Extract key SMART attributes
        local temp realloc pending uncorrectable power_on model serial
        temp=$(echo "$smart_output" | grep -i "Temperature_Celsius" | awk '{print $10}' | cut -d'(' -f1)
        realloc=$(echo "$smart_output" | grep "Reallocated_Sector_Ct" | awk '{print $10}')
        pending=$(echo "$smart_output" | grep "Current_Pending_Sector" | awk '{print $10}')
        uncorrectable=$(echo "$smart_output" | grep "Offline_Uncorrectable" | awk '{print $10}')
        power_on=$(echo "$smart_output" | grep "Power_On_Hours" | awk '{print $10}')
        model=$(echo "$smart_output" | grep "Device Model" | sed 's/.*: *//')
        serial=$(echo "$smart_output" | grep "Serial Number" | sed 's/.*: *//')

        # Warn on concerning SMART values
        if [[ -n "$realloc" ]] && (( realloc > 0 )); then
            status="warning"; escalate warning
        fi
        if [[ -n "$pending" ]] && (( pending > 0 )); then
            status="warning"; escalate warning
        fi
        if [[ -n "$temp" ]] && (( temp >= 55 )); then
            status="warning"; escalate warning
        fi

        drives=$(echo "$drives" | jq \
            --arg dev "$dev" --arg health "$health" --arg status "$status" \
            --arg model "${model:-unknown}" --arg serial "${serial:-unknown}" \
            --argjson temp "${temp:-null}" \
            --argjson realloc "${realloc:-null}" \
            --argjson pending "${pending:-null}" \
            --argjson uncorrectable "${uncorrectable:-null}" \
            --argjson power_on_hours "${power_on:-null}" \
            '. + [{
                "device":$dev, "model":$model, "serial":$serial, "health":$health,
                "temperature_c":$temp, "reallocated_sectors":$realloc,
                "pending_sectors":$pending, "uncorrectable_sectors":$uncorrectable,
                "power_on_hours":$power_on_hours, "status":$status
            }]')
    done < <(sudo smartctl --scan 2>/dev/null | grep -v "^#")

    echo "$drives"
}

check_docker() {
    if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
        echo '{"available":false}'
        return
    fi

    local section_status="ok"

    # Use docker inspect for reliable structured data (avoids text parsing bugs)
    local raw
    raw=$(docker inspect $(docker ps -aq) 2>/dev/null) || raw="[]"

    local containers
    containers=$(echo "$raw" | jq -r --argjson warn "$DOCKER_RESTART_WARN" '
        [.[] | {
            name: .Name[1:],
            state: .State.Status,
            health: (if .State.Health then .State.Health.Status else "none" end),
            restart_count: .RestartCount,
            image: .Config.Image,
            status: (
                if .State.Status != "running" then "warning"
                elif (.State.Health and .State.Health.Status == "unhealthy") then "warning"
                elif .RestartCount >= $warn then "warning"
                else "ok"
                end
            )
        }]
    ')

    # Determine section status
    local warn_count
    warn_count=$(echo "$containers" | jq '[.[] | select(.status != "ok")] | length')
    if (( warn_count > 0 )); then
        section_status="warning"; escalate warning
    fi

    local total running
    total=$(echo "$containers" | jq 'length')
    running=$(echo "$containers" | jq '[.[] | select(.state=="running")] | length')

    jq -n --argjson containers "$containers" --argjson total "$total" \
        --argjson running "$running" --arg status "$section_status" \
        '{"available":true,"total":$total,"running":$running,"status":$status,"containers":$containers}'
}

check_resources() {
    local cores
    cores=$(nproc 2>/dev/null || echo 1)

    # Load averages
    local load1 load5 load15
    read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || { load1=0; load5=0; load15=0; }

    local load_status="ok"
    if (( $(echo "$load5 > $cores * $LOAD_WARN_MULTIPLIER" | bc -l 2>/dev/null || echo 0) )); then
        load_status="warning"; escalate warning
    fi

    # Memory
    local mem_total mem_avail mem_used_pct mem_status="ok"
    mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    if [[ -n "$mem_total" && "$mem_total" -gt 0 ]]; then
        mem_used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
    else
        mem_used_pct=0
    fi

    if (( mem_used_pct >= MEM_CRIT_PCT )); then
        mem_status="critical"; escalate critical
    elif (( mem_used_pct >= MEM_WARN_PCT )); then
        mem_status="warning"; escalate warning
    fi

    local mem_total_h mem_avail_h
    mem_total_h=$(awk "BEGIN {printf \"%.1fG\", $mem_total/1048576}")
    mem_avail_h=$(awk "BEGIN {printf \"%.1fG\", $mem_avail/1048576}")

    # Swap
    local swap_total swap_used swap_pct=0 swap_status="ok"
    swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_used=$(( swap_total - $(grep SwapFree /proc/meminfo | awk '{print $2}') ))
    if [[ -n "$swap_total" && "$swap_total" -gt 0 ]]; then
        swap_pct=$(( swap_used * 100 / swap_total ))
        if (( swap_pct >= SWAP_WARN_PCT )); then
            swap_status="warning"; escalate warning
        fi
    fi

    jq -n \
        --argjson cores "$cores" \
        --argjson load1 "$load1" --argjson load5 "$load5" --argjson load15 "$load15" \
        --arg load_status "$load_status" \
        --argjson mem_used_pct "$mem_used_pct" --arg mem_total "$mem_total_h" \
        --arg mem_available "$mem_avail_h" --arg mem_status "$mem_status" \
        --argjson swap_used_pct "$swap_pct" --arg swap_status "$swap_status" \
        '{
            "cpu": {"cores":$cores,"load_1m":$load1,"load_5m":$load5,"load_15m":$load15,"status":$load_status},
            "memory": {"total":$mem_total,"available":$mem_available,"used_percent":$mem_used_pct,"status":$mem_status},
            "swap": {"used_percent":$swap_used_pct,"status":$swap_status}
        }'
}

check_updates() {
    # Refresh package list
    sudo apt-get update -qq 2>/dev/null

    local total=0 security=0 status="ok"

    if command -v /usr/lib/update-notifier/apt-check &>/dev/null; then
        local output
        output=$(sudo /usr/lib/update-notifier/apt-check 2>&1 || true)
        total=$(echo "$output" | cut -d';' -f1)
        security=$(echo "$output" | cut -d';' -f2)
    else
        total=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo 0)
        security=$(apt list --upgradable 2>/dev/null | grep -ci "security" || echo 0)
    fi

    if (( security > 0 )); then
        status="critical"; escalate critical
    elif (( total > 0 )); then
        status="warning"; escalate warning
    fi

    jq -n --argjson total "${total:-0}" --argjson security "${security:-0}" --arg status "$status" \
        '{"pending":$total,"security":$security,"status":$status}'
}

check_uptime() {
    local uptime_seconds
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)

    local days hours minutes
    days=$(( uptime_seconds / 86400 ))
    hours=$(( (uptime_seconds % 86400) / 3600 ))
    minutes=$(( (uptime_seconds % 3600) / 60 ))

    jq -n --argjson seconds "$uptime_seconds" \
        --arg human "${days}d ${hours}h ${minutes}m" \
        '{"seconds":$seconds,"human":$human}'
}

check_zfs() {
    if ! command -v zpool &>/dev/null; then
        echo '{"available":false}'
        return
    fi

    local pools="[]"
    local section_status="ok"

    while IFS=$'\t' read -r name health; do
        [[ -z "$name" ]] && continue
        local pstatus="ok"
        if [[ "$health" == "DEGRADED" ]]; then
            pstatus="warning"; escalate warning; section_status="warning"
        elif [[ "$health" == "FAULTED" || "$health" == "UNAVAIL" ]]; then
            pstatus="critical"; escalate critical; section_status="critical"
        fi

        pools=$(echo "$pools" | jq --arg name "$name" --arg health "$health" --arg status "$pstatus" \
            '. + [{"name":$name,"health":$health,"status":$status}]')
    done < <(zpool list -H -o name,health 2>/dev/null)

    jq -n --argjson pools "$pools" --arg status "$section_status" \
        '{"available":true,"status":$status,"pools":$pools}'
}

check_raid() {
    if [[ ! -f /proc/mdstat ]]; then
        echo '{"available":false}'
        return
    fi

    local content
    content=$(cat /proc/mdstat 2>/dev/null)
    local status="ok"

    if echo "$content" | grep -qE "\[.*_.*\]"; then
        status="warning"; escalate warning
    fi

    local arrays
    arrays=$(echo "$content" | grep "^md" | awk '{print $1}' | jq -R . | jq -s .)

    jq -n --arg status "$status" --argjson arrays "$arrays" \
        '{"available":true,"status":$status,"arrays":$arrays}'
}

check_network() {
    local dns_ok=false gateway_ok=false internet_ok=false status="ok"

    if host -W 3 google.com &>/dev/null 2>&1 || nslookup google.com &>/dev/null 2>&1; then
        dns_ok=true
    fi

    local gateway
    gateway=$(ip route | awk '/default/ {print $3}' | head -1)
    if [[ -n "$gateway" ]] && ping -c1 -W3 "$gateway" &>/dev/null; then
        gateway_ok=true
    fi

    # Internet connectivity check
    if curl -sf --max-time 5 -o /dev/null https://www.google.com 2>/dev/null; then
        internet_ok=true
    fi

    if ! $dns_ok || ! $gateway_ok; then
        status="warning"; escalate warning
    fi
    if ! $internet_ok; then
        status="warning"; escalate warning
    fi

    # Check listening Docker service ports
    local services="[]"
    if command -v docker &>/dev/null; then
        while IFS=$'\t' read -r name ports; do
            [[ -z "$ports" ]] && continue
            # Extract host-bound ports (0.0.0.0:PORT->)
            while [[ "$ports" =~ 0\.0\.0\.0:([0-9]+)-\> ]]; do
                local port="${BASH_REMATCH[1]}"
                ports="${ports#*${BASH_REMATCH[0]}}"
                local port_ok=false svc_status="ok"
                if timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
                    port_ok=true
                else
                    svc_status="warning"; escalate warning
                fi
                services=$(echo "$services" | jq \
                    --arg name "$name" --argjson port "$port" \
                    --argjson reachable "$port_ok" --arg status "$svc_status" \
                    '. + [{"container":$name,"port":$port,"reachable":$reachable,"status":$status}]')
            done
        done < <(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null)
    fi

    jq -n --argjson dns "$dns_ok" --argjson gateway "$gateway_ok" \
        --argjson internet "$internet_ok" --argjson services "$services" \
        --arg status "$status" \
        '{"dns_resolution":$dns,"gateway_reachable":$gateway,"internet":$internet,"services":$services,"status":$status}'
}

check_logs() {
    local since="24 hours ago"
    if [[ -f "$LAST_CHECK_FILE" ]]; then
        since=$(cat "$LAST_CHECK_FILE")
    fi

    local entries="[]"
    local status="ok"

    if command -v journalctl &>/dev/null; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            entries=$(echo "$entries" | jq --arg line "$line" '. + [$line]')

            if echo "$line" | grep -qi "emerg"; then
                status="critical"; escalate critical
            elif [[ "$status" != "critical" ]]; then
                status="warning"; escalate warning
            fi
        done < <(sudo journalctl --no-pager -p emerg+crit --since "$since" -q --output=short 2>/dev/null | head -50)
    fi

    local count
    count=$(echo "$entries" | jq 'length')

    jq -n --argjson count "$count" --argjson entries "$entries" --arg status "$status" \
        --arg since "$since" \
        '{"since":$since,"count":$count,"status":$status,"entries":$entries}'
}

# ─── Main ────────────────────────────────────────────────────────────────────

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
hostname=$(hostname)

# Run all checks
disk=$(check_disk)
disk_trends=$(check_disk_trends "$disk")
smart=$(check_smart)
docker_info=$(check_docker)
resources=$(check_resources)
updates=$(check_updates)
uptime_info=$(check_uptime)
zfs=$(check_zfs)
raid=$(check_raid)
network=$(check_network)
logs=$(check_logs)

# Save timestamp for next log check
mkdir -p "$STATE_DIR" 2>/dev/null
mkdir -p "$HISTORY_DIR" 2>/dev/null
echo "$timestamp" > "$LAST_CHECK_FILE" 2>/dev/null || true

# Assemble final JSON
output=$(jq -n \
    --arg status "$overall_status" \
    --arg timestamp "$timestamp" \
    --arg hostname "$hostname" \
    --argjson disk "$disk" \
    --argjson disk_trends "$disk_trends" \
    --argjson smart "$smart" \
    --argjson docker "$docker_info" \
    --argjson resources "$resources" \
    --argjson updates "$updates" \
    --argjson uptime "$uptime_info" \
    --argjson zfs "$zfs" \
    --argjson raid "$raid" \
    --argjson network "$network" \
    --argjson logs "$logs" \
    --arg version "$VERSION" \
    '{
        "version": $version,
        "status": $status,
        "timestamp": $timestamp,
        "hostname": $hostname,
        "checks": {
            "disk": $disk,
            "disk_trends": $disk_trends,
            "smart": $smart,
            "docker": $docker,
            "resources": $resources,
            "updates": $updates,
            "uptime": $uptime,
            "zfs": $zfs,
            "raid": $raid,
            "network": $network,
            "logs": $logs
        }
    }')

# Save to history
local_date=$(date +"%Y-%m-%d")
echo "$output" > "$HISTORY_DIR/${local_date}.json" 2>/dev/null || true

# Prune history older than 90 days
find "$HISTORY_DIR" -name "*.json" -mtime +90 -delete 2>/dev/null || true

# Output to stdout
echo "$output"
