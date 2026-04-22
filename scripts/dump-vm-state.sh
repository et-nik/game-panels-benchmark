#!/bin/bash
# =============================================================
# Collect all data from all VMs for reproducibility
# =============================================================
# Creates per-VM archives with configs, apps, databases,
# package lists, and other data needed to reproduce the setup.
#
# Usage: ./collect-all-data.sh [output_dir]
# Default output: /root/loadtest/vm-snapshots/
# =============================================================

OUT="${1:-/root/loadtest/vm-snapshots}"
mkdir -p "$OUT"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ========================
# Per-VM collection function
# ========================
collect_vm() {
    local ip=$1
    local name=$2
    local vm_dir="${OUT}/${name}"

    log "=== ${name} (${ip}) ==="

    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "ubuntu@${ip}" 'true' 2>/dev/null; then
        log "  SKIP — VM not reachable"
        return 0
    fi

    ssh "ubuntu@${ip}" bash << 'REMOTE_SCRIPT' || true
set +e

SNAP="/tmp/vm-snapshot"
sudo rm -rf "$SNAP"
mkdir -p "$SNAP"

echo "  Collecting system info..."

# 1. System info
cat /etc/hostname > "$SNAP/hostname.txt"
uname -a > "$SNAP/uname.txt"
cat /etc/os-release > "$SNAP/os-release.txt"
ip addr show > "$SNAP/ip-addr.txt" 2>/dev/null
systemctl list-units --type=service --state=running --no-pager > "$SNAP/services-running.txt" 2>/dev/null
systemctl list-unit-files --type=service --state=enabled --no-pager > "$SNAP/services-enabled.txt" 2>/dev/null
sudo crontab -l > "$SNAP/crontab-root.txt" 2>/dev/null

# 2. Package list
echo "  Collecting package list..."
dpkg --get-selections > "$SNAP/dpkg-selections.txt"
sudo apt list --installed 2>/dev/null | grep -v "^Listing" > "$SNAP/apt-installed.txt"
sudo cp /etc/apt/sources.list "$SNAP/sources.list" 2>/dev/null
sudo cp -r /etc/apt/sources.list.d "$SNAP/sources.list.d" 2>/dev/null

# 3. /etc (configs)
echo "  Collecting /etc..."
sudo tar czf "$SNAP/etc.tar.gz" \
    --exclude="*.pem" --exclude="*.key" --exclude="*.crt" \
    --exclude="ssl/private" --exclude="shadow" --exclude="shadow-" \
    --exclude="gshadow" --exclude="gshadow-" \
    --exclude=".ssh" --exclude="ssh/ssh_host_*" \
    --exclude="__pycache__" \
    /etc 2>/dev/null

# 4. /var/www (web apps)
if [ -d /var/www ] && [ "$(ls -A /var/www 2>/dev/null)" ]; then
    echo "  Collecting /var/www..."
    sudo tar czf "$SNAP/var-www.tar.gz" \
        --exclude="vendor" --exclude="node_modules" \
        --exclude=".git" --exclude="cache" --exclude="Cache" \
        --exclude="__pycache__" --exclude="*.pyc" \
        --exclude="storage/logs/*.log" \
        --exclude="storage/framework/cache/*" \
        --exclude="storage/framework/sessions/*" \
        --exclude="storage/framework/views/*" \
        /var/www 2>/dev/null
fi

# 5. /srv
if [ -d /srv ] && [ "$(ls -A /srv 2>/dev/null)" ]; then
    echo "  Collecting /srv..."
    sudo tar czf "$SNAP/srv.tar.gz" \
        --exclude=".git" --exclude="node_modules" \
        --exclude="__pycache__" --exclude="*.pyc" \
        /srv 2>/dev/null
fi

# 6. MySQL dump
if command -v mysqldump &>/dev/null && systemctl is-active mysql &>/dev/null; then
    echo "  Dumping MySQL..."
    sudo mysqldump --all-databases --single-transaction --routines --triggers \
        --events --set-gtid-purged=OFF 2>/dev/null | gzip > "$SNAP/mysql-all.sql.gz"
    sudo cp /etc/mysql/conf.d/*.cnf "$SNAP/" 2>/dev/null
fi

# 7. PostgreSQL dump
if command -v pg_dumpall &>/dev/null && systemctl is-active postgresql &>/dev/null; then
    echo "  Dumping PostgreSQL..."
    sudo -u postgres pg_dumpall 2>/dev/null | gzip > "$SNAP/postgresql-all.sql.gz"
fi

# 8. Home directories (root + ubuntu + app users)
echo "  Collecting home dirs..."
for home_dir in /root /home/ubuntu /home/gameap; do
    if [ -d "$home_dir" ]; then
        dir_name=$(basename "$home_dir")
        [ "$home_dir" = "/root" ] && dir_name="root"
        sudo tar czf "$SNAP/home-${dir_name}.tar.gz" \
            --exclude=".ssh" --exclude=".bash_history" \
            --exclude=".python_history" --exclude=".lesshst" \
            --exclude=".gnupg" --exclude=".cache" \
            --exclude="__pycache__" --exclude="*.pyc" \
            --exclude="node_modules" --exclude=".git" \
            --exclude="*.tar.gz" --exclude="*.tar" \
            "$home_dir" 2>/dev/null
    fi
done

# 9. Systemd overrides
if [ -d /etc/systemd/system ]; then
    echo "  Collecting systemd overrides..."
    sudo tar czf "$SNAP/systemd-overrides.tar.gz" \
        /etc/systemd/system/*.service \
        /etc/systemd/system/*.d \
        /usr/lib/systemd/system/pufferpanel.service \
        /usr/lib/systemd/system/gameap*.service \
        /usr/lib/systemd/system/wings.service \
        2>/dev/null
fi

# 10. Docker (compose files, volumes list)
if command -v docker &>/dev/null; then
    echo "  Collecting Docker info..."
    docker ps -a --format "{{.Names}} {{.Image}} {{.Status}}" > "$SNAP/docker-ps.txt" 2>/dev/null
    docker volume ls > "$SNAP/docker-volumes.txt" 2>/dev/null
    docker network ls > "$SNAP/docker-networks.txt" 2>/dev/null

    for f in /opt/docker-compose.yml /opt/*/docker-compose.yml /root/docker-compose.yml /root/*/docker-compose.yml /home/ubuntu/docker-compose.yml /home/ubuntu/*/docker-compose.yml; do
        if [ -f "$f" ]; then
            cp "$f" "$SNAP/docker-compose-$(echo $f | tr '/' '_').yml" 2>/dev/null
        fi
    done
fi

# 11. Prometheus & Grafana configs (monitoring VM)
if [ -d /opt/prometheus ] || [ -d /opt/grafana ] || [ -d /root/monitoring ] || [ -d /home/ubuntu/monitoring ]; then
    echo "  Collecting monitoring configs..."
    for d in /opt/prometheus /opt/grafana /root/monitoring /home/ubuntu/monitoring; do
        if [ -d "$d" ]; then
            dir_name=$(echo "$d" | tr '/' '_')
            sudo tar czf "$SNAP/monitoring${dir_name}.tar.gz" \
                --exclude="data" --exclude="tsdb" --exclude="wal" \
                --exclude="chunks_head" --exclude="*.tmp" \
                "$d" 2>/dev/null
        fi
    done
fi

# 12. process_exporter config
cp /etc/process-exporter/config.yml "$SNAP/process-exporter-config.yml" 2>/dev/null

# 13. Sysctl and limits
cp /etc/sysctl.d/*.conf "$SNAP/" 2>/dev/null
cp /etc/security/limits.d/*.conf "$SNAP/" 2>/dev/null

# 14. PHP version and modules
if command -v php &>/dev/null; then
    php -v > "$SNAP/php-version.txt" 2>/dev/null
    php -m > "$SNAP/php-modules.txt" 2>/dev/null
fi

# 15. Go version
if command -v go &>/dev/null; then
    go version > "$SNAP/go-version.txt" 2>/dev/null
fi

# 16. Installed binaries info
for bin in gameap pufferpanel wings gameap-daemon nginx redis-server mysqld postgres node_exporter process-exporter k6; do
    path=$(which $bin 2>/dev/null)
    if [ -n "$path" ]; then
        ver=$($path --version 2>/dev/null || $path -v 2>/dev/null || echo 'unknown')
        echo "$bin: $path ($ver)" >> "$SNAP/binaries.txt"
    fi
done

# 17. Sizes summary
echo "  Sizes:"
du -sh "$SNAP"/* 2>/dev/null | sort -rh | head -20

# Final archive
echo "  Creating final archive..."
sudo tar czf /tmp/vm-snapshot.tar.gz -C "$SNAP" .
echo "  Archive size: $(du -sh /tmp/vm-snapshot.tar.gz | cut -f1)"
sudo rm -rf "$SNAP"
REMOTE_SCRIPT

    # Download
    mkdir -p "$vm_dir"
    scp "ubuntu@${ip}:/tmp/vm-snapshot.tar.gz" "${vm_dir}/snapshot.tar.gz" 2>/dev/null || {
        log "  ERROR: could not download snapshot"
        return 0
    }
    ssh "ubuntu@${ip}" 'sudo rm -f /tmp/vm-snapshot.tar.gz' 2>/dev/null

    local size=$(du -sh "${vm_dir}/snapshot.tar.gz" | cut -f1)
    log "  Saved: ${vm_dir}/snapshot.tar.gz (${size})"
}

# ========================
# Host (Hertz) collection
# ========================
collect_host() {
    log "=== Hertz (host) ==="
    local host_dir="${OUT}/hertz-host"
    mkdir -p "$host_dir"

    # System info
    hostname > "${host_dir}/hostname.txt"
    uname -a > "${host_dir}/uname.txt"
    cat /etc/os-release > "${host_dir}/os-release.txt" 2>/dev/null
    pveversion > "${host_dir}/pve-version.txt" 2>/dev/null
    cat /proc/cpuinfo | head -30 > "${host_dir}/cpuinfo.txt"
    free -h > "${host_dir}/memory.txt"
    lsblk > "${host_dir}/lsblk.txt"
    ip addr show > "${host_dir}/ip-addr.txt" 2>/dev/null
    cat /proc/cmdline > "${host_dir}/cmdline.txt" 2>/dev/null

    # VM configs
    log "  Collecting VM configs..."
    mkdir -p "${host_dir}/vm-configs"
    for vmid in 100 101 102 103 104 110 111 112 113 114 120 130 9000; do
        conf="/etc/pve/qemu-server/${vmid}.conf"
        [ -f "$conf" ] && cp "$conf" "${host_dir}/vm-configs/${vmid}.conf"
    done


    # Network config
    cp /etc/network/interfaces "${host_dir}/interfaces.conf" 2>/dev/null

    # Sysctl / GRUB / tuning
    cp /etc/sysctl.d/*.conf "${host_dir}/" 2>/dev/null
    cp /etc/security/limits.d/*.conf "${host_dir}/" 2>/dev/null
    cp /etc/default/grub "${host_dir}/grub-default.txt" 2>/dev/null

    # Loadtest scripts
    log "  Collecting loadtest scripts..."
    tar czf "${host_dir}/loadtest-scripts.tar.gz" \
        --exclude="results" --exclude="*.tar" --exclude="*.tar.gz" \
        --exclude="vm-snapshots" \
        -C /root loadtest/ 2>/dev/null

    # Results listing
    log "  Collecting loadtest results reference..."
    ls -laR /root/loadtest/results/ > "${host_dir}/results-listing.txt" 2>/dev/null

    # SSH config (without keys)
    cp /etc/ssh/sshd_config "${host_dir}/sshd_config.txt" 2>/dev/null

    # iptables / NAT
    iptables-save > "${host_dir}/iptables-rules.txt" 2>/dev/null

    # CPU governor service
    cp /etc/systemd/system/cpu-performance.service "${host_dir}/" 2>/dev/null

    local size=$(du -sh "${host_dir}" | cut -f1)
    log "  Saved: ${host_dir}/ (${size})"
}

# ========================
# MAIN
# ========================

echo ""
echo "============================================"
echo "  Collecting VM data for reproducibility"
echo "  Output: ${OUT}"
echo "  $(date)"
echo "============================================"
echo ""

# Host
collect_host

# All VMs
declare -A VM_MAP=(
    ["10.10.10.10"]="gameap-3"
    ["10.10.10.11"]="gameap-4"
    ["10.10.10.12"]="pterodactyl"
    ["10.10.10.13"]="pelican"
    ["10.10.10.14"]="pufferpanel"
    ["10.10.10.20"]="gameap-3-daemon"
    ["10.10.10.21"]="pterodactyl-wings"
    ["10.10.10.22"]="gameap-4-daemon"
    ["10.10.10.23"]="pelican-wings"
    ["10.10.10.24"]="pufferpanel-daemon"
    ["10.10.10.30"]="k6-runner"
    ["10.10.10.40"]="monitoring"
)

# Start all VMs first
log "Starting all VMs..."
for vmid in 100 101 102 103 104 110 111 112 113 114 120 130; do
    qm start $vmid 2>/dev/null || true
done
log "Waiting 40s for boot..."
sleep 40

for ip in 10.10.10.10 10.10.10.11 10.10.10.12 10.10.10.13 10.10.10.14 \
          10.10.10.20 10.10.10.21 10.10.10.22 10.10.10.23 10.10.10.24 \
          10.10.10.30 10.10.10.40; do
    name="${VM_MAP[$ip]}"
    collect_vm "$ip" "$name"
    echo ""
done

# Final archive
log "Creating final archive..."
tar czf "/root/loadtest/vm-data-${TIMESTAMP}.tar.gz" -C "$OUT" .
FINAL_SIZE=$(du -sh "/root/loadtest/vm-data-${TIMESTAMP}.tar.gz" | cut -f1)

echo ""
echo "============================================"
echo "  DONE at $(date)"
echo "============================================"
echo ""
echo "Per-VM snapshots: ${OUT}/"
du -sh "${OUT}"/*/ 2>/dev/null | sort -rh
echo ""
echo "Final archive: /root/loadtest/vm-data-${TIMESTAMP}.tar.gz (${FINAL_SIZE})"
echo ""
echo "To reproduce a VM:"
echo "  1. Install Ubuntu 24.04"
echo "  2. Restore apt sources from sources.list.d/"
echo "  3. Install packages: dpkg --set-selections < dpkg-selections.txt && apt-get dselect-upgrade"
echo "  4. Restore /etc: tar xzf etc.tar.gz -C /"
echo "  5. Restore /var/www: tar xzf var-www.tar.gz -C /"
echo "  6. Restore database: gunzip -c mysql-all.sql.gz | mysql"
echo "     or: gunzip -c postgresql-all.sql.gz | sudo -u postgres psql"
echo "  7. Restore home dirs: tar xzf home-root.tar.gz -C /"
echo "  8. systemctl daemon-reload && systemctl restart all services"
