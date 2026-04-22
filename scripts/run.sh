#!/bin/bash
# =============================================================
# FINAL STAGE 1: Benchmark run for one or all panels
# =============================================================
# Results structure:
#   /root/loadtest/results/<panel>/
#     ├── api-read_smoke.json
#     ├── api-read_baseline.json
#     ├── api-read_load.json
#     ├── api-read_stress.json
#     ├── api-read_stress-1000.json
#     ├── api-read_stress-1200.json
#     ├── max-throughput_max-100vus.json
#     ├── start_time.txt
#     ├── end_time.txt
#     └── run.log
#
# Usage:
#   ./run-final.sh gameap-4                # One panel, all profiles
#   ./run-final.sh gameap-4 baseline       # One panel, one profile
#   ./run-final.sh all                     # All panels, all profiles
# =============================================================

set -e

PANEL_FILTER="${1:?Usage: $0 <panel|all> [profile]}"
PROFILE_FILTER="${2:-all}"
RESULTS_BASE="/root/loadtest/results"
COOLDOWN_PANELS=300
COOLDOWN_PROFILES=60
WARMUP=60

declare -A PANEL_VMS=(
    ["gameap-4"]="101 112"
    ["pufferpanel"]="104 114"
    ["gameap-3"]="100 110"
    ["pterodactyl"]="102 111"
    ["pelican"]="103 113"
)

ALL_PANEL_VMS="100 101 102 103 104 110 111 112 113 114"

PROFILES="smoke baseline load stress stress-1000 stress-1200"

log() {
    local panel_dir="${CURRENT_PANEL_DIR:-/tmp}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${panel_dir}/run.log"
}

stop_all_panels() {
    log "Stopping all panel VMs..."
    for vmid in $ALL_PANEL_VMS; do
        qm status $vmid 2>/dev/null | grep -q running && qm stop $vmid --timeout 30 2>/dev/null || true
    done
    sleep 10
}

start_panel() {
    local panel=$1
    local vms=${PANEL_VMS[$panel]}
    log "Starting VMs for $panel: $vms"
    for vmid in $vms; do
        qm start $vmid 2>/dev/null || true
    done
    log "Waiting 30s for VMs to boot..."
    sleep 30

    for vmid in $vms; do
        log "  VM $vmid: $(qm status $vmid 2>/dev/null)"
    done
}

restart_services() {
    local panel=$1
    log "Restarting services on $panel..."
    case $panel in
        gameap-3)
            ssh -o ConnectTimeout=10 ubuntu@10.10.10.10 'sudo systemctl restart php8.4-fpm nginx mysql redis-server 2>/dev/null; true' 2>/dev/null
            ;;
        gameap-4)
            ssh -o ConnectTimeout=10 ubuntu@10.10.10.11 'sudo systemctl restart nginx' 2>/dev/null || true
            ;;
        pterodactyl)
            ssh -o ConnectTimeout=10 ubuntu@10.10.10.12 'sudo systemctl restart php8.4-fpm nginx mysql' 2>/dev/null
            ;;
        pelican)
            ssh -o ConnectTimeout=10 ubuntu@10.10.10.13 'sudo systemctl restart php8.4-fpm nginx mysql' 2>/dev/null
            ;;
        pufferpanel)
            ssh -o ConnectTimeout=10 ubuntu@10.10.10.14 'sudo systemctl restart pufferpanel' 2>/dev/null || true
            ;;
    esac
    sleep 5
    log "Services restarted"
}

run_k6() {
    local panel=$1
    local profile=$2
    local scenario="${3:-api-read}"
    local extra_env="${4:-}"
    local panel_dir="$CURRENT_PANEL_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local out_name="${scenario}_${profile}"

    log ">>> ${panel} / ${scenario} / ${profile}"

    ssh k6-runner "cd /home/ubuntu/k6-project && \
        K6_PROMETHEUS_RW_SERVER_URL=http://10.10.10.40:9090/api/v1/write \
        PANEL=${panel} PROFILE=${profile} ${extra_env} \
        k6 run \
            --tag run_id=${timestamp} \
            --tag panel=${panel} \
            --tag profile=${profile} \
            --summary-export=/tmp/k6-summary.json \
            -o experimental-prometheus-rw \
            scenarios/${scenario}.js 2>&1" | tee -a "${panel_dir}/run.log"

    scp k6-runner:/tmp/k6-summary.json "${panel_dir}/${out_name}.json" 2>/dev/null || \
        log "WARNING: Could not copy summary JSON"

    log "<<< Saved: ${panel_dir}/${out_name}.json"
}

run_panel() {
    local panel=$1

    CURRENT_PANEL_DIR="${RESULTS_BASE}/${panel}"
    mkdir -p "$CURRENT_PANEL_DIR"

    log ""
    log "============================================"
    log "  PANEL: $panel"
    log "  Results: $CURRENT_PANEL_DIR"
    log "  Started: $(date)"
    log "============================================"

    stop_all_panels
    start_panel $panel
    restart_services $panel

    # Record start time
    date -u +%Y-%m-%dT%H:%M:%SZ > "${CURRENT_PANEL_DIR}/start_time.txt"

    # Warmup
    log "Warmup (${WARMUP}s)..."
    ssh k6-runner "cd /home/ubuntu/k6-project && \
        PANEL=${panel} PROFILE=smoke \
        k6 run --quiet scenarios/api-read.js 2>/dev/null" || true
    sleep 10

    # API Read — all profiles
    for profile in $PROFILES; do
        if [ "$PROFILE_FILTER" != "all" ] && [ "$PROFILE_FILTER" != "$profile" ]; then
            continue
        fi

        log ""
        log "--- $panel / $profile ---"
        restart_services $panel
        sleep 5

        run_k6 "$panel" "$profile" "api-read"

        log "Cooldown ${COOLDOWN_PROFILES}s..."
        sleep $COOLDOWN_PROFILES
    done

    # Max throughput
    if [ "$PROFILE_FILTER" = "all" ] || [ "$PROFILE_FILTER" = "max-throughput" ]; then
        log ""
        log "--- $panel / max-throughput ---"
        restart_services $panel
        sleep 5

        run_k6 "$panel" "max-100vus" "max-throughput" "TARGET_VUS=100 DURATION=2m"

        log "Cooldown ${COOLDOWN_PROFILES}s..."
        sleep $COOLDOWN_PROFILES
    fi

    # Record end time
    date -u +%Y-%m-%dT%H:%M:%SZ > "${CURRENT_PANEL_DIR}/end_time.txt"

    log ""
    log "=== $panel DONE at $(date) ==="
    log "=== Results: $CURRENT_PANEL_DIR ==="
}

# ========================
# MAIN
# ========================

if [ "$PANEL_FILTER" = "all" ]; then
    PANELS="gameap-4 pufferpanel gameap-3 pterodactyl pelican"
else
    PANELS="$PANEL_FILTER"
fi

echo ""
echo "============================================"
echo "  FINAL STAGE 1 BENCHMARK"
echo "  Panels: $PANELS"
echo "  Profiles: $([ "$PROFILE_FILTER" = "all" ] && echo "$PROFILES + max-throughput" || echo "$PROFILE_FILTER")"
echo "  Date: $(date)"
echo "============================================"
echo ""

FIRST=true
for panel in $PANELS; do
    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        echo ""
        echo "Cooling down between panels (${COOLDOWN_PANELS}s)..."
        sleep $COOLDOWN_PANELS
    fi
    run_panel "$panel"
done

echo ""
echo "============================================"
echo "  ALL DONE at $(date)"
echo "============================================"
echo ""
echo "Results:"
for panel in $PANELS; do
    echo "  ${RESULTS_BASE}/${panel}/"
    ls -1 "${RESULTS_BASE}/${panel}/"*.json 2>/dev/null | sed 's/^/    /'
done
echo ""
echo "Next: ./collect-metrics.sh <panel>"
