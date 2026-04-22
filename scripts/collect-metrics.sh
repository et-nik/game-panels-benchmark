#!/bin/bash
# =============================================================
# Collect metrics from Prometheus for one or all panels
# =============================================================
# Results structure:
#   /root/loadtest/results/<panel>/metrics/
#     ├── cpu_percent.csv
#     ├── ram_mb.csv
#     ├── network_rx_mbps.csv
#     ├── network_tx_mbps.csv
#     ├── disk_write_iops.csv
#     ├── disk_read_iops.csv
#     ├── process_cpu.csv
#     ├── process_ram.csv
#     └── peak_summary.csv
#
# Usage:
#   ./collect-metrics.sh gameap-4       # One panel
#   ./collect-metrics.sh all            # All panels
# =============================================================

PANEL_FILTER="${1:?Usage: $0 <panel|all>}"
RESULTS_BASE="/root/loadtest/results"
PROM="http://10.10.10.40:9090"

declare -A PANEL_INSTANCES=(
    ["gameap-4"]="10.10.10.11:9100"
    ["gameap-3"]="10.10.10.10:9100"
    ["pterodactyl"]="10.10.10.12:9100"
    ["pelican"]="10.10.10.13:9100"
    ["pufferpanel"]="10.10.10.14:9100"
)

declare -A PROCESS_INSTANCES=(
    ["gameap-4"]="10.10.10.11:9256"
    ["gameap-3"]="10.10.10.10:9256"
    ["pterodactyl"]="10.10.10.12:9256"
    ["pelican"]="10.10.10.13:9256"
    ["pufferpanel"]="10.10.10.14:9256"
)

prom_range() {
    curl -s "${PROM}/api/v1/query_range" \
        --data-urlencode "query=${1}" \
        --data-urlencode "start=${2}" \
        --data-urlencode "end=${3}" \
        --data-urlencode "step=${4:-15s}"
}

collect_panel() {
    local panel=$1
    local panel_dir="${RESULTS_BASE}/${panel}"
    local start_file="${panel_dir}/start_time.txt"
    local end_file="${panel_dir}/end_time.txt"

    if [ ! -f "$start_file" ] || [ ! -f "$end_file" ]; then
        echo "SKIP $panel — no start/end time files in ${panel_dir}/"
        return
    fi

    local start=$(cat "$start_file")
    local end=$(cat "$end_file")
    local inst=${PANEL_INSTANCES[$panel]}
    local proc_inst=${PROCESS_INSTANCES[$panel]}
    local out="${panel_dir}/metrics"

    mkdir -p "$out"

    echo "=== $panel: $start → $end ==="

    # ---- Node-level metrics ----

    echo "  CPU..."
    prom_range \
        "100*(1-avg(rate(node_cpu_seconds_total{instance=\"${inst}\",mode=\"idle\"}[1m])))" \
        "$start" "$end" "15s" | \
        python3 -c "import sys,json; [print(f\"{v[0]},{v[1]}\") for v in json.load(sys.stdin)['data']['result'][0]['values']]" \
        > "${out}/cpu_percent.csv" 2>/dev/null

    echo "  RAM..."
    prom_range \
        "(node_memory_MemTotal_bytes{instance=\"${inst}\"}-node_memory_MemAvailable_bytes{instance=\"${inst}\"})/1024/1024" \
        "$start" "$end" "15s" | \
        python3 -c "import sys,json; [print(f\"{v[0]},{v[1]}\") for v in json.load(sys.stdin)['data']['result'][0]['values']]" \
        > "${out}/ram_mb.csv" 2>/dev/null

    echo "  Network..."
    prom_range \
        "rate(node_network_receive_bytes_total{instance=\"${inst}\",device=\"eth0\"}[1m])/1024/1024" \
        "$start" "$end" "15s" | \
        python3 -c "import sys,json; [print(f\"{v[0]},{v[1]}\") for v in json.load(sys.stdin)['data']['result'][0]['values']]" \
        > "${out}/network_rx_mbps.csv" 2>/dev/null

    prom_range \
        "rate(node_network_transmit_bytes_total{instance=\"${inst}\",device=\"eth0\"}[1m])/1024/1024" \
        "$start" "$end" "15s" | \
        python3 -c "import sys,json; [print(f\"{v[0]},{v[1]}\") for v in json.load(sys.stdin)['data']['result'][0]['values']]" \
        > "${out}/network_tx_mbps.csv" 2>/dev/null

    echo "  Disk..."
    prom_range \
        "rate(node_disk_writes_completed_total{instance=\"${inst}\",device=\"sda\"}[1m])" \
        "$start" "$end" "15s" | \
        python3 -c "import sys,json; [print(f\"{v[0]},{v[1]}\") for v in json.load(sys.stdin)['data']['result'][0]['values']]" \
        > "${out}/disk_write_iops.csv" 2>/dev/null

    prom_range \
        "rate(node_disk_reads_completed_total{instance=\"${inst}\",device=\"sda\"}[1m])" \
        "$start" "$end" "15s" | \
        python3 -c "import sys,json; [print(f\"{v[0]},{v[1]}\") for v in json.load(sys.stdin)['data']['result'][0]['values']]" \
        > "${out}/disk_read_iops.csv" 2>/dev/null

    # ---- Process-level metrics ----

    echo "  Processes..."
    prom_range \
        "rate(namedprocess_namegroup_cpu_seconds_total{instance=\"${proc_inst}\"}[1m])*100" \
        "$start" "$end" "30s" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for series in data['data']['result']:
    group = series['metric']['groupname']
    for v in series['values']:
        print(f\"{v[0]},{group},{v[1]}\")
" > "${out}/process_cpu.csv" 2>/dev/null

    prom_range \
        "namedprocess_namegroup_memory_bytes{instance=\"${proc_inst}\",memtype=\"resident\"}/1024/1024" \
        "$start" "$end" "30s" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for series in data['data']['result']:
    group = series['metric']['groupname']
    for v in series['values']:
        print(f\"{v[0]},{group},{v[1]}\")
" > "${out}/process_ram.csv" 2>/dev/null

    # ---- Peak summary ----

    echo "  Peaks..."
    python3 << PEAKS > "${out}/peak_summary.csv"
import csv

def peak(filename, col=1):
    mx = 0
    try:
        with open("${out}/" + filename) as f:
            for line in f:
                parts = line.strip().split(",")
                val = float(parts[col])
                if val > mx:
                    mx = val
    except:
        pass
    return mx

print("metric,value")
print(f"cpu_peak_percent,{peak('cpu_percent.csv'):.1f}")
print(f"ram_peak_mb,{peak('ram_mb.csv'):.0f}")
print(f"network_tx_peak_mbps,{peak('network_tx_mbps.csv'):.2f}")
print(f"network_rx_peak_mbps,{peak('network_rx_mbps.csv'):.2f}")
print(f"disk_write_iops_peak,{peak('disk_write_iops.csv'):.0f}")
print(f"disk_read_iops_peak,{peak('disk_read_iops.csv'):.0f}")
PEAKS

    echo "  Files:"
    ls -1 "${out}/" | sed 's/^/    /'
    echo ""
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
echo "Collecting Prometheus metrics"
echo ""

for panel in $PANELS; do
    collect_panel "$panel"
done

echo "=== DONE ==="
