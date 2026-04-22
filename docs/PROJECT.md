## Project goal

Run a **fair comparative load test** of five game server control panels.

**Panels under test:**
- **GameAP 3.x** (PHP/Laravel + MySQL + Redis) — legacy version
- **GameAP 4.x** (Go + PostgreSQL) — rewritten version
- **Pterodactyl** (PHP/Laravel + MySQL + Redis)
- **Pelican** (PHP/Laravel + MySQL + Redis, Pterodactyl fork)
- **PufferPanel** (Go + PostgreSQL) — for the Go vs Go comparison

**Principles:**
- Identical conditions for every panel
- Reproducible methodology
- Open scripts, configs, and raw data
- Acknowledgement of each panel's strengths and weaknesses

## Target audience of the publication

Game hosting administrators, DevOps engineers, developers.

## Methodology

### Approach — sequential testing

Tests are run **one panel at a time**, not in parallel. All other VMs are completely powered off via `qm stop`. This:
- Eliminates contention for CPU cache and memory bandwidth
- Guarantees identical thermal conditions and Turbo Boost behavior
- Yields stable, reproducible numbers
- Makes results fairly comparable

### Testing phases

**Phase 1: HTTP/API performance (✅ DONE — 3 runs, 100 servers)**
- API reads: list servers, details, status (3 endpoints)
- Profiles: smoke (1 VU), baseline (10 VUs), load (100 VUs), stress (800 VUs), stress-1000 (1000 VUs), stress-1200 (1200 VUs)
- Max throughput (100 VUs without think-time)
- 3 full runs, results reported as the median of the three
- 100 game servers (clock-mock) on every panel

**Phase 2: Game server management (PLANNED)**
- Time to mass start/stop of N servers (10, 50, 100, 200)
- Steady-state with N servers (resource consumption by panel and daemon)
- Simultaneous console viewing for N servers via WebSocket
- Mass command dispatch
- Server creation via API

Phase 2 uses a **Go fake-game-server** — a compiled binary that emulates the behavior of a real game server.

## Infrastructure

### Server (bare-metal, Selectel)

- **CPU:** Intel Xeon E-2456 (Raptor Lake, 6C/12T, 3.3 GHz base / 5.1 GHz turbo, 18 MB L3, AVX2)
- **RAM:** 32 GB DDR5 ECC (2× 16 GB Kingston, 4400 MT/s)
- **Storage:** 2× Samsung 990 PRO 1TB NVMe in **mdadm RAID1**
- **Network:** single public network
- **Hypervisor:** Proxmox VE 9.1.5 on Debian 13 (Trixie), kernel 6.17.9-1-pve
- **Storage backend:** directory storage `local` on the root filesystem (qcow2 VM disks)
- **Host hostname:** Hertz

### Host tuning

- ✅ CPU governor `performance` via the `cpu-performance.service` systemd unit
- ✅ C-states limited to C1 via `intel_idle.max_cstate=1 processor.max_cstate=1` in GRUB
- ✅ Turbo Boost enabled
- ✅ Swap disabled
- ✅ sysctl tuning in `/etc/sysctl.d/99-loadtest.conf`
- ✅ File limits in `/etc/security/limits.d/99-loadtest.conf`
- ✅ Chrony for time sync
- ✅ Internal network `vmbr1` (10.10.10.1/24), NAT via iptables MASQUERADE
- ✅ APT mirror: mirror.yandex.ru

## VM layout

| ID | Name | IP | vCPU | RAM | Disk | Purpose | Status |
|---|---|---|---|---|---|---|---|
| 9000 | ubuntu-template | — | 2 | 2GB | 20GB | cloud-init template | ✅ |
| 100 | gameap-3 | 10.10.10.10 | 4 | 8 GB | 40 GB | GameAP 3.x panel | ✅ |
| 101 | gameap-4 | 10.10.10.11 | 4 | 8 GB | 40 GB | GameAP 4.x panel | ✅ |
| 102 | pterodactyl | 10.10.10.12 | 4 | 8 GB | 40 GB | Pterodactyl panel | ✅ |
| 103 | pelican | 10.10.10.13 | 4 | 8 GB | 40 GB | Pelican panel | ✅ |
| 104 | pufferpanel | 10.10.10.14 | 4 | 8 GB | 40 GB | PufferPanel panel | ✅ |
| 110 | gameap-3-daemon | 10.10.10.20 | 6 | 12 GB | 80 GB | gameap-daemon for 3.x | ✅ |
| 111 | pterodactyl-wings | 10.10.10.21 | 6 | 12 GB | 80 GB | Wings for Pterodactyl | ✅ |
| 112 | gameap-4-daemon | 10.10.10.22 | 6 | 12 GB | 80 GB | gameap-daemon for 4.x | ✅ |
| 113 | pelican-wings | 10.10.10.23 | 6 | 12 GB | 80 GB | Wings for Pelican | ✅ |
| 114 | pufferpanel-daemon | 10.10.10.24 | 6 | 12 GB | 80 GB | PufferPanel daemon | ✅ |
| 120 | k6-runner | 10.10.10.30 | 4 | 4 GB | 20 GB | Load generator | ✅ |
| 130 | monitoring | 10.10.10.40 | 2 | 4 GB | 60 GB | Prometheus + Grafana | ✅ |

**OS:** Ubuntu 24.04 LTS (kernel 6.8.0-110) on every VM.

## Installed panels

### GameAP 3.x (VM 100)
- **Stack:** PHP 8.4, MySQL 8.0, Nginx, Redis (phpredis, CACHE_DRIVER=redis, SESSION_DRIVER=redis)
- **Daemon:** gameap-daemon on VM 110
- **Auth:** API key `1|n38ZgfkmkIzFvmkRmXloNsvQBT8JnRgIlHTTBtnz`
- **game_mod_id:** 75 (clock-mock)

### GameAP 4.x (VM 101)
- **Stack:** Go + PostgreSQL
- **Daemon:** gameap-daemon on VM 112
- **Auth:** API key `2|JlSKKrSNDU7jYLdvQw86kWNabqnp0Ayfgxl9K56lXeT8AT4V`
- **game_mod_id:** 33 (clock-mock)

### Pterodactyl (VM 102)
- **Stack:** PHP 8.4, MySQL 8.0, Nginx, Redis, Wings (Docker) on VM 111
- **Auth:** Client API key `ptlc_CMnVpS17utremKIboJhm0rl2AKi8cmZ0zTX1CuYMzwh`
- **Rate limit:** APP_API_CLIENT_RATELIMIT=10000

### Pelican (VM 103)
- **Stack:** PHP 8.4, MySQL 8.0, Nginx, Redis, Wings (Docker) on VM 113
- **Auth:** Client `pacc_bm6PW6wk45eEdUbLlZB8FPo5MnPYOdbgGCb6zwgwdTR`, App `papp_9n5NSc9iMIlkMIlc2M87KX1F8CwAsinUvPW6Ae9W3QF`
- **Rate limit:** APP_API_CLIENT_RATELIMIT=10000, APP_API_APPLICATION_RATELIMIT=10000

### PufferPanel (VM 104)
- **Stack:** Go + PostgreSQL, port 8080
- **Daemon:** VM 114
- **OAuth2:** client_id=`7f7aa0c8-f484-4425-ad83-5a206e77c502`, client_secret=`jO7q-s8fFJXU1HZlHGhNjCh7Hcu1zDhgG1mF9L5DzAXJMmtM`
- **systemd override:** After=postgresql.service, Requires=postgresql.service

## PHP tuning (identical on gameap-3, pterodactyl, pelican)

```ini
pm = dynamic, pm.max_children = 50, pm.start_servers = 10
opcache.enable = 1, opcache.jit = tracing, opcache.jit_buffer_size = 128M
innodb_buffer_pool_size = 2G, max_connections = 200, innodb_flush_log_at_trx_commit = 2
```

## Monitoring

- node_exporter 1.8.2 on every VM (port 9100)
- process_exporter 0.8.7 on every panel/daemon VM (port 9256)
- Prometheus + Grafana in Docker on VM 130

### process_exporter — tracked processes
gameap-daemon, gameap (comm), pufferpanel (comm), php-fpm, postgresql, mysqld, nginx, redis-server, dockerd, containerd, wings, other

## Phase 1 results — median of 3 runs (100 servers)

### Max Throughput (RPS, 0% errors)

| GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|
| **1126** | **696** | **394** | **94** | **76** |

### Median Latency (ms) by profile

| Profile | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| smoke (1 VU) | **1.08** | 2.01 | 20.37 | 26.98 | 31.30 |
| baseline (10) | **0.83** | 1.54 | 9.25 | 12.75 | 16.00 |
| load (100) | **0.59** | 1.37 | 8.78 | 20.80 | 53.30 |
| stress (800) | **0.57** | 1.44 | 27.93 | 1130 | 1528 |
| stress-1000 | **0.76** | 114 | 1484 | 7887 | 10217 |
| stress-1200 | 24.17 | 97.20 | 1959 | 10575 | 12839 |

### Processes at stress 800 VUs

| Process | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| App (Go/php-fpm) | 31.5% | 71% | 320% | 241% | 261% |
| DB (PG/MySQL) | 3.1% | 9% | 31% | 109% | 93% |
