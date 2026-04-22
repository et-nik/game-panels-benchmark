#!/bin/bash
# =============================================================
# Import VMs from export created by export-vms.sh
# =============================================================
# Restores VM configs, qcow2 disks, host network and tuning.
# Accepts both .qcow2.zst (default from current export-vms.sh) and
# legacy plain .qcow2 in the same export dir.
#
# Snapshots: pass-through. zstd -d produces a byte-identical qcow2,
# so internal snapshots preserved by export-vms.sh come back as-is;
# the copied .conf keeps its [snap_name] sections and `parent:` field,
# so Proxmox sees a consistent VM. No special handling needed — but
# this script logs snapshot counts after each restore for verification.
#
# Usage: ./import-vms.sh [export_dir]
# Default: /root/loadtest/vm-export/
#
# Prerequisites:
#   - Proxmox VE installed
#   - zstd available on the host
#   - qemu-img (for snapshot verification; from qemu-utils)
#   - Run as root on the Proxmox host
# =============================================================

IMPORT_DIR="${1:-/root/loadtest/vm-export}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*"; }
err() { echo "[$(date '+%H:%M:%S')] ERROR: $*"; }

if [ "$(id -u)" != "0" ]; then
    err "Run as root"
    exit 1
fi

command -v zstd >/dev/null 2>&1 || { err "zstd not installed"; exit 1; }

if [ ! -d "$IMPORT_DIR" ]; then
    err "Export dir not found: $IMPORT_DIR"
    echo "Usage: $0 [export_dir]"
    exit 1
fi

CONFIGS_DIR="$IMPORT_DIR/configs"
STORAGE_PATH="/var/lib/vz/images"

echo ""
echo "============================================"
echo "  Import VMs from $IMPORT_DIR"
echo "  $(date)"
echo "============================================"
echo ""

# ========================
# Step 1: Host tuning
# ========================
log "=== Step 1: Host tuning ==="

if [ -f "$CONFIGS_DIR/host-sysctl.conf" ]; then
    cp "$CONFIGS_DIR/host-sysctl.conf" /etc/sysctl.d/99-loadtest.conf
    sysctl --system > /dev/null 2>&1
    log "  Sysctl applied"
fi

if [ -f "$CONFIGS_DIR/host-grub.txt" ]; then
    log "  GRUB config available at $CONFIGS_DIR/host-grub.txt"
    log "  Review and apply manually if needed (C-states, idle):"
    grep GRUB_CMDLINE_LINUX_DEFAULT "$CONFIGS_DIR/host-grub.txt" | head -1 | sed 's/^/    /'
fi

# CPU governor
if ! systemctl is-active cpu-performance.service &>/dev/null; then
    cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=Set CPU governor to performance

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $f; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now cpu-performance.service 2>/dev/null
    log "  CPU governor set to performance"
fi

# Disable swap
swapoff -a 2>/dev/null
sed -i '/swap/d' /etc/fstab 2>/dev/null
log "  Swap disabled"

echo ""

# ========================
# Step 2: Network — vmbr1 internal bridge
# ========================
log "=== Step 2: Network ==="

if ! ip link show vmbr1 &>/dev/null; then
    log "  Creating internal bridge vmbr1 (10.10.10.1/24)..."

    if [ -f "$CONFIGS_DIR/host-interfaces.conf" ]; then
        # Check if vmbr1 already defined in the exported config
        if grep -q "vmbr1" "$CONFIGS_DIR/host-interfaces.conf"; then
            log "  Found vmbr1 in exported config, appending..."
            grep -A10 "vmbr1" "$CONFIGS_DIR/host-interfaces.conf" >> /etc/network/interfaces
        fi
    fi

    # Fallback: create manually if not in config
    if ! grep -q "vmbr1" /etc/network/interfaces 2>/dev/null; then
        cat >> /etc/network/interfaces << 'EOF'

auto vmbr1
iface vmbr1 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
EOF
    fi

    ifup vmbr1 2>/dev/null || ip link add vmbr1 type bridge 2>/dev/null
    ip addr add 10.10.10.1/24 dev vmbr1 2>/dev/null
    ip link set vmbr1 up 2>/dev/null
    log "  vmbr1 created"
else
    log "  vmbr1 already exists"
fi

# NAT
if ! iptables -t nat -C POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
    log "  NAT rule added"
else
    log "  NAT rule already exists"
fi

echo 1 > /proc/sys/net/ipv4/ip_forward
echo ""

# ========================
# Step 3: Import VM disks and configs
# ========================
log "=== Step 3: Importing VMs ==="

IMPORTED=0
SKIPPED=0
declare -A DONE_VMID

shopt -s nullglob
# Process .qcow2.zst first (preferred), then plain .qcow2 for legacy exports
for src in "$IMPORT_DIR"/*.qcow2.zst "$IMPORT_DIR"/*.qcow2; do
    fname=$(basename "$src")
    case "$fname" in
        *.qcow2.zst) base="${fname%.zst}"; compressed=1 ;;
        *.qcow2)     base="$fname";        compressed=0 ;;
        *)           continue ;;
    esac

    # Parse: 100-gameap-3.qcow2 → vmid=100, name=gameap-3
    vmid=$(echo "$base" | grep -oP '^\d+')
    name=$(echo "$base" | sed "s/^${vmid}-//; s/\.qcow2$//")

    if [ -z "$vmid" ]; then
        warn "Cannot parse VMID from $fname, skipping"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # If a .qcow2.zst for this VM was already processed, skip the plain .qcow2
    if [ -n "${DONE_VMID[$vmid]}" ]; then
        log "  Skipping $fname (VM $vmid already imported)"
        continue
    fi

    if [ "$compressed" = "1" ]; then
        log "  --- VM $vmid ($name) [zstd compressed] ---"
    else
        log "  --- VM $vmid ($name) ---"
    fi

    # Check if VM already exists on the Proxmox host
    if qm status $vmid &>/dev/null; then
        warn "  VM $vmid already exists, skipping"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Restore config
    conf_file="$CONFIGS_DIR/${vmid}.conf"
    if [ -f "$conf_file" ]; then
        cp "$conf_file" "/etc/pve/qemu-server/${vmid}.conf"
        log "  Config restored"
    else
        warn "  No config for VM $vmid, creating minimal"
        cat > "/etc/pve/qemu-server/${vmid}.conf" << MINCONF
boot: order=scsi0
cores: 4
memory: 8192
name: $name
net0: virtio,bridge=vmbr1
ostype: l26
scsi0: local:${vmid}/vm-${vmid}-disk-0.qcow2,size=40G
scsihw: virtio-scsi-single
MINCONF
    fi

    # Resolve target disk path from the restored config
    disk_dir="${STORAGE_PATH}/${vmid}"
    mkdir -p "$disk_dir"

    target_disk=$(grep -oP 'local:\K[^,]+' "/etc/pve/qemu-server/${vmid}.conf" 2>/dev/null | head -1)
    if [ -n "$target_disk" ]; then
        target_path="${STORAGE_PATH}/${target_disk}"
        mkdir -p "$(dirname "$target_path")"
    else
        target_path="${disk_dir}/vm-${vmid}-disk-0.qcow2"
    fi

    src_size=$(du -sh "$src" | cut -f1)
    if [ "$compressed" = "1" ]; then
        log "  Decompressing zstd ($src_size) → $target_path..."
        zstd -d -T0 -f "$src" -o "$target_path"
        if [ $? -ne 0 ]; then
            err "  zstd decompression failed for VM $vmid"
            rm -f "$target_path"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    else
        log "  Copying disk ($src_size) → $target_path..."
        cp "$src" "$target_path"
    fi

    log "  Disk: $target_path ($(du -sh "$target_path" | cut -f1))"

    # Report any preserved internal qcow2 snapshots (qemu-img snapshot -l
    # has a 2-line header). Proxmox .conf stores snapshots as [name] sections;
    # [PENDING] is a pending-changes section, not a snapshot, so exclude it.
    # If the .conf references snapshots but the qcow2 has none, qm rollback
    # on that snapshot will fail — surface this now.
    if command -v qemu-img >/dev/null 2>&1; then
        disk_snaps=$(qemu-img snapshot -l "$target_path" 2>/dev/null | tail -n +3)
        conf="/etc/pve/qemu-server/${vmid}.conf"
        total_sections=$(grep -cE '^\[[^]]+\]$' "$conf" 2>/dev/null || echo 0)
        has_pending=$(grep -cE '^\[PENDING\]$' "$conf" 2>/dev/null || echo 0)
        conf_snap_count=$((total_sections - has_pending))
        if [ -n "$disk_snaps" ]; then
            disk_snap_count=$(echo "$disk_snaps" | wc -l)
            log "  Snapshots: $disk_snap_count in disk, $conf_snap_count in config"
            if [ "$disk_snap_count" != "$conf_snap_count" ]; then
                warn "  Snapshot count mismatch — qm rollback may fail"
            fi
        elif [ "$conf_snap_count" -gt 0 ]; then
            warn "  Config references $conf_snap_count snapshot(s) but disk has none — qm rollback will fail"
        fi
    fi

    DONE_VMID[$vmid]=1
    IMPORTED=$((IMPORTED + 1))
done

echo ""

# ========================
# Step 4: Verify and start
# ========================
log "=== Step 4: Verify ==="

echo ""
echo "Imported VMs:"
echo ""
printf "  %-6s %-22s %-16s %s\n" "VMID" "Name" "Status" "Config"
echo "  $(printf '%.0s-' {1..65})"

for vmid in 100 101 102 103 104 110 111 112 113 114 120 130; do
    if [ -f "/etc/pve/qemu-server/${vmid}.conf" ]; then
        name=$(grep "^name:" "/etc/pve/qemu-server/${vmid}.conf" 2>/dev/null | awk '{print $2}')
        status=$(qm status $vmid 2>/dev/null | awk '{print $2}' || echo "unknown")

        # Check disk exists
        disk_ref=$(grep -oP 'local:\K[^,]+' "/etc/pve/qemu-server/${vmid}.conf" | head -1)
        if [ -n "$disk_ref" ] && [ -f "${STORAGE_PATH}/${disk_ref}" ]; then
            disk_status="OK ($(du -sh "${STORAGE_PATH}/${disk_ref}" | cut -f1))"
        else
            disk_status="MISSING"
        fi

        printf "  %-6s %-22s %-16s %s\n" "$vmid" "$name" "$status" "$disk_status"
    fi
done

echo ""
log "Imported: $IMPORTED, Skipped: $SKIPPED"
echo ""

# ========================
# Step 5: Optional — start all VMs
# ========================
echo "Start all VMs? (y/N)"
read -r answer
if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    log "Starting VMs..."
    for vmid in 130 120 100 101 102 103 104 110 111 112 113 114; do
        if qm status $vmid &>/dev/null; then
            qm start $vmid 2>/dev/null && log "  Started VM $vmid" || warn "  Failed to start VM $vmid"
            sleep 2
        fi
    done

    log "Waiting 40s for boot..."
    sleep 40

    log "Checking connectivity..."
    declare -A IP_MAP=(
        [100]="10.10.10.10" [101]="10.10.10.11" [102]="10.10.10.12"
        [103]="10.10.10.13" [104]="10.10.10.14" [110]="10.10.10.20"
        [111]="10.10.10.21" [112]="10.10.10.22" [113]="10.10.10.23"
        [114]="10.10.10.24" [120]="10.10.10.30" [130]="10.10.10.40"
    )
    for vmid in 100 101 102 103 104 110 111 112 113 114 120 130; do
        ip="${IP_MAP[$vmid]}"
        if ping -c1 -W2 "$ip" &>/dev/null; then
            log "  VM $vmid ($ip): reachable"
        else
            warn "  VM $vmid ($ip): not reachable"
        fi
    done
fi

echo ""
log "=== IMPORT COMPLETE ==="
echo ""
echo "Next steps:"
echo "  1. Verify SSH: ssh ubuntu@10.10.10.10"
echo "  2. Check panels: curl http://10.10.10.10/login"
echo "  3. Run tests: bash /root/loadtest/run-final.sh gameap-4"