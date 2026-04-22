#!/bin/bash
# =============================================================
# Export all VMs as zstd-compressed qcow2 + configs
# =============================================================
# 1. Zeroes free space inside each VM (fstrim)
# 2. Stops VMs
# 3. Converts each disk to qcow2 and compresses with zstd
#    Output: <vmid>-<name>.qcow2.zst (single-disk VMs)
#            <vmid>-<name>-<disk-file>.qcow2.zst (multi-disk VMs)
# 4. Saves VM configs
#
# Snapshots: if a qcow2 image has internal snapshots, qemu-img convert
# would drop them silently. This script detects them and falls back to
# `cp --sparse=always`, which preserves snapshots at the cost of no
# image compaction. To drop snapshots intentionally, run
# `qm delsnapshot <vmid> <name>` for each before exporting.
#
# Usage: ./export-vms.sh [output_dir]
# Default: /root/loadtest/vm-export/
# Env:    ZSTD_LEVEL (default 19; 1-19 standard, 20-22 --ultra)
# =============================================================

OUT="${1:-/root/loadtest/vm-export}"
mkdir -p "$OUT"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

command -v zstd >/dev/null 2>&1 || { log "ERROR: zstd not installed"; exit 1; }
ZSTD_LEVEL="${ZSTD_LEVEL:-19}"

declare -A VM_MAP=(
    [100]="gameap-3:10.10.10.10"
    [101]="gameap-4:10.10.10.11"
    [102]="pterodactyl:10.10.10.12"
    [103]="pelican:10.10.10.13"
    [104]="pufferpanel:10.10.10.14"
    [110]="gameap-3-daemon:10.10.10.20"
    [111]="pterodactyl-wings:10.10.10.21"
    [112]="gameap-4-daemon:10.10.10.22"
    [113]="pelican-wings:10.10.10.23"
    [114]="pufferpanel-daemon:10.10.10.24"
    [120]="k6-runner:10.10.10.30"
    [130]="monitoring:10.10.10.40"
)

ALL_VMIDS="100 101 102 103 104 110 111 112 113 114 120 130"

# ========================
# Step 1: Zero free space inside VMs (for better compression)
# ========================
log "=== Step 1: Zeroing free space inside VMs ==="
log "Starting all VMs..."
for vmid in $ALL_VMIDS; do
    qm start $vmid 2>/dev/null || true
done
log "Waiting 40s for boot..."
sleep 40

for vmid in $ALL_VMIDS; do
    info="${VM_MAP[$vmid]}"
    name="${info%%:*}"
    ip="${info##*:}"

    log "  $name ($ip): fstrim..."
    # Fallback writes zeros to /var/tmp/zero (NOT /tmp — that's tmpfs on
    # Ubuntu 24.04, so zeros would fill RAM instead of the VM's disk).
    ssh -o ConnectTimeout=5 -o BatchMode=yes "ubuntu@${ip}" \
        'sudo fstrim -av 2>/dev/null || (sudo dd if=/dev/zero of=/var/tmp/zero bs=1M 2>/dev/null; sudo rm -f /var/tmp/zero)' \
        2>/dev/null || log "    SKIP — not reachable"
done

# ========================
# Step 2: Stop all VMs
# ========================
log ""
log "=== Step 2: Stopping all VMs ==="
for vmid in $ALL_VMIDS; do
    info="${VM_MAP[$vmid]}"
    name="${info%%:*}"
    qm shutdown $vmid --timeout 60 2>/dev/null || qm stop $vmid 2>/dev/null || true
    log "  $name (VM $vmid): stopped"
done
log "Waiting 30s for clean shutdown..."
sleep 30

# Verify all stopped
for vmid in $ALL_VMIDS; do
    status=$(qm status $vmid 2>/dev/null | awk '{print $2}')
    if [ "$status" = "running" ]; then
        log "  WARNING: VM $vmid still running, force stopping..."
        qm stop $vmid --timeout 30 2>/dev/null
    fi
done
sleep 10

# ========================
# Step 3: Save configs
# ========================
log ""
log "=== Step 3: Saving VM configs ==="
mkdir -p "$OUT/configs"
for vmid in $ALL_VMIDS 9000; do
    conf="/etc/pve/qemu-server/${vmid}.conf"
    if [ -f "$conf" ]; then
        cp "$conf" "$OUT/configs/${vmid}.conf"
        log "  Saved ${vmid}.conf"
    fi
done

# Save host info
cp /etc/network/interfaces "$OUT/configs/host-interfaces.conf" 2>/dev/null || true
iptables-save > "$OUT/configs/host-iptables.txt" 2>/dev/null || true
cp /etc/default/grub "$OUT/configs/host-grub.txt" 2>/dev/null || true
cp /etc/sysctl.d/99-loadtest.conf "$OUT/configs/host-sysctl.conf" 2>/dev/null || true

# ========================
# Step 4: Compress qcow2 images
# ========================
log ""
log "=== Step 4: Compressing qcow2 images ==="
log "This will take a while..."

# Find storage path
STORAGE_PATH="/var/lib/vz/images"

# --ultra is only meaningful for levels 20-22; harmless but noisy at lower levels.
ULTRA_FLAG=""
if [ "$ZSTD_LEVEL" -gt 19 ] 2>/dev/null; then
    ULTRA_FLAG="--ultra"
fi

for vmid in $ALL_VMIDS; do
    info="${VM_MAP[$vmid]}"
    name="${info%%:*}"

    # Find ALL qcow2 disks for this VM (multi-disk VMs had their extra
    # disks silently dropped when this used `head -1`).
    mapfile -t disk_paths < <(find "${STORAGE_PATH}/${vmid}/" -maxdepth 1 -name "*.qcow2" 2>/dev/null | sort)

    if [ ${#disk_paths[@]} -eq 0 ]; then
        log "  $name (VM $vmid): disk not found, skipping"
        continue
    fi

    disk_count=${#disk_paths[@]}
    if [ "$disk_count" -gt 1 ]; then
        log "  $name (VM $vmid): found $disk_count disks"
    fi

    for disk_path in "${disk_paths[@]}"; do
        orig_size=$(du -sh "$disk_path" | cut -f1)
        disk_base=$(basename "$disk_path" .qcow2)

        if [ "$disk_count" -gt 1 ]; then
            out_file="$OUT/${vmid}-${name}-${disk_base}.qcow2"
        else
            out_file="$OUT/${vmid}-${name}.qcow2"
        fi

        # Detect internal qcow2 snapshots. `qemu-img convert` drops them;
        # fall back to sparse cp when they're present so the exported image
        # round-trips losslessly. Header is 2 lines, so data starts at line 3.
        snap_list=$(qemu-img snapshot -l "$disk_path" 2>/dev/null | tail -n +3)

        log "  $name (VM $vmid): $disk_path ($orig_size)"
        if [ -n "$snap_list" ]; then
            snap_count=$(echo "$snap_list" | wc -l)
            log "    WARN: $snap_count internal snapshot(s) found — using cp (no compaction)"
            cp --sparse=always "$disk_path" "$out_file"
            rc=$?
        else
            log "    converting with qemu-img..."
            qemu-img convert -O qcow2 "$disk_path" "$out_file"
            rc=$?
        fi

        if [ "$rc" -ne 0 ]; then
            log "    ERROR: conversion/copy failed (rc=$rc)"
            rm -f "$out_file"
            continue
        fi

        log "    compressing with zstd -${ZSTD_LEVEL}..."
        zstd -T0 $ULTRA_FLAG "-${ZSTD_LEVEL}" --rm -f "$out_file"

        if [ $? -eq 0 ]; then
            new_size=$(du -sh "${out_file}.zst" | cut -f1)
            log "    $orig_size → $new_size"
        else
            log "    ERROR: zstd compression failed"
            rm -f "$out_file" "${out_file}.zst"
        fi
    done
done

# ========================
# Step 5: Summary
# ========================
log ""
log "=== DONE ==="
log ""
log "Output: $OUT/"
echo ""
echo "Files:"
ls -lhS "$OUT"/*.qcow2.zst 2>/dev/null | awk '{print "  " $5 "\t" $NF}'
echo ""
echo "Configs:"
ls -1 "$OUT/configs/"
echo ""

total=$(du -sh "$OUT" | cut -f1)
echo "Total size: $total"

echo ""
echo "To import on another Proxmox host:"
echo "  bash import-vms.sh $OUT   # auto-decompresses, restores configs, sets up network"
echo ""
echo "Or manually:"
echo "  1. Copy configs to /etc/pve/qemu-server/"
echo "  2. zstd -d <vmid>-<name>.qcow2.zst -o /var/lib/vz/images/<vmid>/<disk>.qcow2"
echo "  3. Adjust network in configs if needed"
echo "  4. qm start <vmid>"