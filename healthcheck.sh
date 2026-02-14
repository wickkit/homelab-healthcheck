#!/usr/bin/env bash
set -uo pipefail

# homelab-healthcheck — Outputs JSON health report to stdout
# https://github.com/wickkit/homelab-healthcheck
VERSION="0.2.0"

# ─── Configuration ───────────────────────────────────────────────────────────

DISK_WARN_PCT=80
DISK_CRIT_PCT=90
MEM_WARN_PCT=85
MEM_CRIT_PCT=95
SWAP_WARN_PCT=50
LOAD_WARN_MULTIPLIER=1
DOCKER_RESTART_WARN=3
STATE_DIR="/var/lib/homelab-healthcheck"
LAST_CHECK_FILE="$STATE_DIR/last_check"

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

        local health
        health=$(sudo smartctl --health "$dev" 2>/dev/null | grep -i "result\|status" | head -1 | sed 's/.*: *//')
        local status="ok"
        if [[ -z "$health" ]]; then
            health="unknown"
        elif ! echo "$health" | grep -qi "passed\|ok"; then
            status="critical"; escalate critical
        fi

        drives=$(echo "$drives" | jq --arg dev "$dev" --arg health "$health" --arg status "$status" \
            '. + [{"device":$dev,"health":$health,"status":$status}]')
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
    local dns_ok=false gateway_ok=false status="ok"

    if host -W 3 google.com &>/dev/null 2>&1 || nslookup google.com &>/dev/null 2>&1; then
        dns_ok=true
    fi

    local gateway
    gateway=$(ip route | awk '/default/ {print $3}' | head -1)
    if [[ -n "$gateway" ]] && ping -c1 -W3 "$gateway" &>/dev/null; then
        gateway_ok=true
    fi

    if ! $dns_ok || ! $gateway_ok; then
        status="warning"; escalate warning
    fi

    jq -n --argjson dns "$dns_ok" --argjson gateway "$gateway_ok" --arg status "$status" \
        '{"dns_resolution":$dns,"gateway_reachable":$gateway,"status":$status}'
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
echo "$timestamp" > "$LAST_CHECK_FILE" 2>/dev/null || true

# Assemble final JSON
jq -n \
    --arg status "$overall_status" \
    --arg timestamp "$timestamp" \
    --arg hostname "$hostname" \
    --argjson disk "$disk" \
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
    }'
