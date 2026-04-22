# Scripts

All scripts run **on the Proxmox host (Hertz)** as root unless stated otherwise. They reach into VMs over SSH (`ubuntu@10.10.10.x`).

## Overview

| Script                                  | Purpose | Where to run |
|-----------------------------------------|---|---|
| [run.sh](#runsh)                        | Full load-test run | Host |
| [collect-metrics.sh](#collect-metricssh) | Pull metrics from Prometheus | Host |
| [create-servers.sh](#create-serverssh)  | Create game servers on the panels | Host |
| [dump-vm-state.sh](#dump-vm-statesh)    | Collect all-VM data for reproducibility | Host |
| [restore-vm.sh](#restore-vmsh)          | Restore a VM from a snapshot | Target VM |
| [export-vms.sh](#export-vmssh)          | Export VMs (compressed qcow2 + configs) | Host |
| [import-vms.sh](#import-vmssh)          | Import VMs onto a new Proxmox host | New host |
| [clock.sh](#clocksh)                    | Clock with interactive stdin | Any machine |

---

## run.sh

Automates the full load-test run. For every panel, in sequence: stops all VMs → starts the ones for that panel → warms up → runs every profile → collects results.

```bash
# Single panel (~1.5 hours)
./run.sh gameap-4

# Single profile
./run.sh gameap-4 baseline

# All panels (~8 hours)
./run.sh all

# Overnight
nohup ./run.sh all > /tmp/final.log 2>&1 &
```

**Profiles:** smoke (1 VU) → baseline (10) → load (100) → stress (800) → stress-1000 → stress-1200 → max-throughput (100 VUs, no think-time).

**Results:**
```
/root/loadtest/results/<panel>/
├── api-read_smoke.json
├── api-read_baseline.json
├── api-read_load.json
├── api-read_stress.json
├── api-read_stress-1000.json
├── api-read_stress-1200.json
├── max-throughput_max-100vus.json
├── start_time.txt / end_time.txt
└── run.log
```

---

## collect-metrics.sh

Pulls metrics from Prometheus for the test window: CPU, RAM, network, disk, per-process metrics.

```bash
# Single panel
./collect-metrics.sh gameap-4

# All
./collect-metrics.sh all
```

**Requires:** `start_time.txt` and `end_time.txt` in the panel's results directory (produced by `run-final.sh`).

**Results:**
```
/root/loadtest/results/<panel>/metrics/
├── cpu_percent.csv
├── ram_mb.csv
├── network_rx_mbps.csv / network_tx_mbps.csv
├── disk_read_iops.csv / disk_write_iops.csv
├── process_cpu.csv / process_ram.csv
└── peak_summary.csv
```

---

## create-servers.sh

Creates game servers (clock-mock) on the panels via their APIs. Supports all 5 panels with their API quirks.

```bash
# 100 servers on every panel
./create-servers.sh all 100

# 900 servers starting from #101 (added on top of the existing 100)
./create-servers.sh all 900 101

# Single panel
./create-servers.sh gameap-4 100
./create-servers.sh pterodactyl 100
./create-servers.sh pufferpanel 100
```

**Per-panel notes:**

| Panel | Method | Notes |
|---|---|---|
| GameAP 3.x / 4.x | POST `/api/servers` | `game_mod_id`: 75 (3.x), 33 (4.x) |
| Pterodactyl | Batch allocations → POST `/api/application/servers` | Clock Mock egg auto-discovered |
| Pelican | Batch allocations → POST `/api/application/servers` | Clock Mock egg auto-discovered |
| PufferPanel | PUT `/api/servers/{random_hex}` | OAuth2 token, full JSON with `run`/`install` |

---

## dump-vm-state.sh

Collects everything needed to reproduce the test bench from every VM: configs, applications, SQL dumps, package lists, systemd units.

```bash
./dump-vm-state.sh [output_dir]
# Default: /root/loadtest/vm-snapshots/
```

**Per-VM, it collects:**
- `/etc` (without ssh keys, shadow, ssl/private)
- `/var/www` (without vendor, node_modules, .git)
- MySQL dump (`mysqldump --all-databases`)
- PostgreSQL dump (`pg_dumpall`)
- Home directories (`/root`, `/home/ubuntu`, `/home/gameap`)
- Package lists (`dpkg --get-selections`, APT sources)
- Systemd overrides
- Docker info, Prometheus/Grafana configs
- Binary versions

**Output:** `/root/loadtest/vm-data-YYYYMMDD_HHMMSS.tar.gz`

---

## restore-vm.sh

Restores a VM from a snapshot created by `dump-vm-state.sh`. Runs **on the target machine** (fresh Ubuntu 24.04).

```bash
# On the target VM, as root:
./restore-vm.sh /path/to/snapshot.tar.gz
# or from an already-extracted directory:
./restore-vm.sh /path/to/extracted/
```

**Restore order:**
1. APT sources → package install
2. `/etc` — selective (nginx, php, mysql, postgresql, redis, systemd, sysctl)
3. `/var/www` + `composer install` + fix permissions
4. `/srv`
5. Databases (MySQL or PostgreSQL from the SQL dump)
6. Home directories
7. Systemd overrides + `daemon-reload`
8. Service restart
9. Verification

**After restore, check:** IP addresses in `.env`, `php artisan config:cache`, Wings `config.yml`.

---

## export-vms.sh

Exports every Proxmox VM as zstd-compressed qcow2 images for moving to another host.

```bash
./export-vms.sh [output_dir]
# Default: /root/loadtest/vm-export/
# ~1-2 hours for 12 VMs

# Faster export (less compression, same format):
ZSTD_LEVEL=3 ./export-vms.sh
```

**What it does:**
1. `fstrim` inside each VM (zeroes free space for better compression)
2. Stops every VM
3. Saves configs from `/etc/pve/qemu-server/`
4. `qemu-img convert -O qcow2` → uncompressed qcow2 → `zstd -T0 -19 --rm` → `<vmid>-<name>.qcow2.zst`

Compared to qcow2's internal zlib, zstd yields smaller artifacts on sparse/zeroed
disks and leaves imported VMs uncompressed — no read amplification at runtime.

**Snapshots:** if a qcow2 image has internal snapshots (from `qm snapshot`),
the script detects them and switches to `cp --sparse=always` for that image
(preserves snapshots, but no compaction). To export snapshot-less images, run
`qm delsnapshot <vmid> <name>` for each snapshot before exporting.

**Multi-disk VMs:** every qcow2 file under `/var/lib/vz/images/<vmid>/` is
exported. Extra disks are named `<vmid>-<name>-<disk-file>.qcow2.zst`
(`import-vms.sh` currently restores only the primary disk — additional disks
must be placed manually).

**Storage:** assumes Proxmox `local` (directory) storage. LVM-thin / ZFS /
Ceph volumes are not supported.

**Env:**
- `ZSTD_LEVEL` (default `19`). Range `1-22`; `--ultra` is added automatically when > 19.

---

## import-vms.sh

Imports VMs onto a new Proxmox host from an export produced by `export-vms.sh`.

```bash
# On the new Proxmox host:
./import-vms.sh /root/loadtest/vm-export/
```

**What it does:**
1. Applies sysctl, sets CPU governor to `performance`, disables swap
2. Creates the internal bridge `vmbr1` (10.10.10.1/24) + NAT
3. Restores configs and installs disks from the export dir. Accepts
   `.qcow2.zst` (current default — decompressed via `zstd -d`) and plain
   `.qcow2` (legacy exports — copied as-is). If both exist for the same VMID,
   the `.zst` is preferred.
4. Prints a table of imported VMs
5. Optionally starts every VM and checks connectivity

**Snapshots:** pass-through — `zstd -d` gives a byte-identical qcow2, so
internal snapshots come back as-is; the copied `.conf` keeps its
`[snap_name]` sections. After each disk is placed, the script runs
`qemu-img snapshot -l` and compares the count against the snapshot sections
in the restored `.conf`, warning on mismatch (which would break `qm rollback`).

---

## clock.sh

Utility script: prints the current date/time every second and reads stdin.

```bash
./clock.sh
# [2026-04-19 15:30:45]> 
# [2026-04-19 15:30:46]> hello
# Command from user: hello
```

Used as the clock-mock game server for testing.

---

## Typical workflow

```bash
# 1. Setup (one-off)
./create-servers.sh all 100

# 2. Testing
./run-final.sh all                    # or one at a time: ./run-final.sh gameap-4
./collect-metrics.sh all

# 3. Archiving
./dump-vm-state.sh                    # VM data
./export-vms.sh                       # full images

# 4. Move to another host
rsync -avP /root/loadtest/vm-export/ new-host:/root/loadtest/vm-export/
ssh new-host './import-vms.sh /root/loadtest/vm-export/'
```

## Dependencies

| Script | Required on host | Required on VM |
|---|---|---|
| run-final.sh | qm, ssh | k6 (on k6-runner) |
| collect-metrics.sh | curl, python3 | Prometheus (on monitoring) |
| create-servers.sh | curl, python3 | — |
| dump-vm-state.sh | ssh, scp | tar, mysqldump / pg_dumpall |
| restore-vm.sh | — | apt, tar, mysql / psql, composer |
| export-vms.sh | qemu-img, ssh, zstd | fstrim |
| import-vms.sh | qm, ip, iptables, zstd | — |
