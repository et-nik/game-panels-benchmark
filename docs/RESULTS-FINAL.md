# Final results of the game panel load tests

> Phase 1: HTTP/API performance.
> 100 game servers (clock-mock), 3 endpoints (list, details, status).
> All numbers are the **average of two runs**. Run-to-run deviation ≤5.5%.

## Panels under test

| Panel | Version | Language | Database | Daemon |
|---|---|---|---|---|
| **GameAP 4.x** | 4.x | Go | PostgreSQL | gameap-daemon |
| **PufferPanel** | 3.x | Go | PostgreSQL | PufferPanel (built-in) |
| **GameAP 3.x** | 3.x | PHP 8.4 / Laravel | MySQL 8.0 + Redis | gameap-daemon |
| **Pterodactyl** | 1.11.x | PHP 8.4 / Laravel | MySQL 8.0 + Redis | Wings (Docker) |
| **Pelican** | 1.0.x | PHP 8.4 / Laravel (Pterodactyl fork) | MySQL 8.0 + Redis | Wings (Docker) |

## Infrastructure

### Server (bare-metal, Selectel)

- **CPU:** Intel Xeon E-2456 (Raptor Lake, 6C/12T, 3.3 GHz base / 5.1 GHz turbo, 18 MB L3)
- **RAM:** 32 GB DDR5 ECC (2× 16 GB, 4400 MT/s)
- **Storage:** 2× Samsung 990 PRO 1TB NVMe in mdadm RAID1
- **Hypervisor:** Proxmox VE 9.1.5 on Debian 13, kernel 6.17.9-1-pve

### VMs

- Panel VM: 4 vCPU, 8 GB RAM, 40 GB disk, Ubuntu 24.04 LTS
- Daemon VM: 6 vCPU, 12 GB RAM, 80 GB disk, Ubuntu 24.04 LTS
- k6-runner: 4 vCPU, 4 GB RAM
- Monitoring: 2 vCPU, 4 GB RAM (Prometheus + Grafana)

### Host tuning

- CPU governor: performance
- C-states: limited to C1
- Turbo Boost: enabled
- Swap: disabled on every VM

### PHP tuning (identical on GameAP 3.x, Pterodactyl, Pelican)

```ini
# PHP-FPM
pm = dynamic, pm.max_children = 50, pm.start_servers = 10

# OPcache
opcache.enable = 1, opcache.memory_consumption = 256
opcache.jit_buffer_size = 128M, opcache.jit = tracing

# MySQL
innodb_buffer_pool_size = 2G, max_connections = 200
innodb_flush_log_at_trx_commit = 2
```

### Methodology

- Tests run sequentially, one panel at a time, all other VMs powered off
- 60s warmup, services restarted before each profile, 60s cooldown
- 100 game servers (clock-mock) on every panel
- Two full runs, results averaged
- Tool: k6 v1.7.1
- Monitoring: Prometheus + node_exporter 1.8.2 + process_exporter 0.8.7

### Test scenario api-read

Each iteration consists of 3 API requests:
1. **list_servers** — list of servers (100 items)
2. **server_details** — details of a random server
3. **server_status** — server status

Think-time 0.3–3 seconds between requests.

### Authentication

| Panel | Method |
|---|---|
| GameAP 3.x | API key (Bearer token) |
| GameAP 4.x | API key (Bearer token) |
| Pterodactyl | API key (Bearer token) |
| Pelican | API key (Bearer token) |
| PufferPanel | OAuth2 Client Credentials → Bearer token (once in setup, TTL=3600s) |

---

## k6 results

### Smoke (1 VU, 30 seconds)

| Panel | Stack | Avg ms | Med ms | p95 ms | Errors |
|---|---|---|---|---|---|
| **GameAP 4.x** | Go | **1.18** | **1.08** | **1.93** | 0% |
| **PufferPanel** | Go | 4.12 | 2.01 | 8.39 | 0% |
| **GameAP 3.x** | PHP | 20.23 | 20.37 | 30.00 | 0% |
| **Pterodactyl** | PHP | 53.33 | 26.98 | 85.98 | 0% |
| **Pelican** | PHP | 67.69 | 31.30 | 108.45 | 0% |

*PufferPanel avg (4.12) vs med (2.01) — the gap is explained by one OAuth2 request (~58ms) during setup that is included in the metrics. On tests with >100 requests the impact is negligible (<0.05%).*

### Baseline (10 VUs, 4.5 minutes)

| Panel | Avg ms | Med ms | p95 ms | Reqs | Errors |
|---|---|---|---|---|---|
| **GameAP 4.x** | **0.86** | **0.83** | **1.46** | 2204 | 0% |
| **PufferPanel** | 1.50 | 1.54 | 2.09 | 2200 | 0% |
| **GameAP 3.x** | 11.20 | 9.25 | 22.16 | 2167 | 0% |
| **Pterodactyl** | 32.58 | 12.75 | 79.48 | 2146 | 0% |
| **Pelican** | 40.17 | 16.00 | 97.81 | 2134 | 0% |

### Load (100 VUs, 11 minutes)

| Panel | Avg ms | Med ms | p95 ms | Reqs | Errors |
|---|---|---|---|---|---|
| **GameAP 4.x** | **0.66** | **0.59** | **1.21** | 40873 | 0% |
| **PufferPanel** | 1.27 | 1.37 | 1.85 | 40841 | 0% |
| **GameAP 3.x** | 9.67 | 8.78 | 12.99 | 40522 | 0% |
| **Pterodactyl** | 48.59 | 20.80 | 154.82 | 38958 | 0% |
| **Pelican** | 107.12 | 53.30 | 458.32 | 37082 | 0% |

### Stress (800 VUs, 10 minutes)

| Panel | Avg ms | Med ms | p95 ms | Reqs | RPS | Errors |
|---|---|---|---|---|---|---|
| **GameAP 4.x** | **0.89** | **0.57** | **2.90** | 156086 | 259 | **0%** |
| **PufferPanel** | 10.70 | 1.44 | 63.33 | 154758 | 257 | 0.10% |
| **GameAP 3.x** | 246 | 27.93 | 905 | 126280 | 210 | **0%** |
| **Pterodactyl** | 2346 | 1130 | 9125 | 49153 | 82 | **0%** |
| **Pelican** | 3007 | 1528 | 11180 | 41426 | 69 | **0%** |

### Stress-1000 (1000 VUs, 9 minutes)

| Panel | Avg ms | Med ms | p95 ms | Reqs | RPS | Errors |
|---|---|---|---|---|---|---|
| **GameAP 4.x** | **3.55** | **0.76** | **15.65** | 388980 | 716 | **0.01%** |
| **PufferPanel** | 129 | 114 | 318 | 333835 | 615 | 21.25% |
| **GameAP 3.x** | 1151 | 1484 | 1586 | 185089 | 341 | **0%** |
| **Pterodactyl** | 7375 | 7887 | 13338 | 48808 | 90 | **0%** |
| **Pelican** | 9279 | 10217 | 15634 | 39936 | 74 | **0%** |

### Stress-1200 (1200 VUs, 10 minutes)

| Panel | Avg ms | Med ms | p95 ms | Reqs | RPS | Errors |
|---|---|---|---|---|---|---|
| **GameAP 4.x** | 75.48 | 24.17 | 279.96 | 461548 | 765 | 14.76% |
| **PufferPanel** | 126 | 97.20 | 330.92 | 421179 | 699 | 34.69% |
| **GameAP 3.x** | 1460 | 1959 | 2079 | 210596 | 349 | **0%** |
| **Pterodactyl** | 8811 | 10575 | 13709 | 54276 | 90 | **0%** |
| **Pelican** | 11031 | 12839 | 17444 | 44568 | 74 | **0%** |

### Max Throughput (100 VUs, no think-time, 2.5 minutes)

| Panel | RPS | Avg ms | Med ms | p95 ms | Errors |
|---|---|---|---|---|---|
| **GameAP 4.x** | **1127** | 77.5 | 68.9 | 178.8 | 0% |
| **PufferPanel** | **698** | 125.4 | 121.1 | 256.3 | 0% |
| **GameAP 3.x** | **394** | 222.3 | 241.3 | 302.4 | 0% |
| **Pterodactyl** | **93** | 942.7 | 766.0 | 1827.6 | 0% |
| **Pelican** | **76** | 1162.1 | 946.6 | 2281.5 | 0% |

---

## Latency by profile — summary table (median ms)

| Profile | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| **smoke** (1 VU) | **1.08** | 2.01 | 20.37 | 26.98 | 31.30 |
| **baseline** (10 VUs) | **0.83** | 1.54 | 9.25 | 12.75 | 16.00 |
| **load** (100 VUs) | **0.59** | 1.37 | 8.78 | 20.80 | 53.30 |
| **stress** (800 VUs) | **0.57** | 1.44 | 27.93 | 1130 | 1528 |
| **stress-1000** | **0.76** | 114 | 1484 | 7887 | 10217 |
| **stress-1200** | 24.17 | 97.20 | 1959 | 10575 | 12839 |

---

## Per-endpoint (avg ms)

### Baseline (10 VUs)

| Endpoint | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| list_servers | **1.18** | 1.66 | 12.88 | 70.29 | 87.87 |
| server_details | **0.83** | 0.95 | 10.25 | 13.68 | 17.05 |
| server_status | **0.58** | 1.82 | 10.42 | 13.21 | 14.88 |

### Load (100 VUs)

| Endpoint | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| list_servers | **0.95** | 1.48 | 11.55 | 109.89 | 234.74 |
| server_details | **0.63** | 0.78 | 8.73 | 18.86 | 47.59 |
| server_status | **0.41** | 1.55 | 8.74 | 17.00 | 39.00 |

### Stress (800 VUs)

| Endpoint | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| list_servers | **1.18** | 11.01 | 258 | 3110 | 3952 |
| server_details | **0.89** | 9.12 | 240 | 2632 | 3318 |
| server_status | **0.61** | 11.96 | 240 | 1295 | 1751 |

---

## Resources — peak CPU by profile

| Profile | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| smoke | 0.3% | 0.6% | 3.4% | 2.3% | 3.3% |
| baseline | 0.7% | 0.8% | 4.8% | 9.3% | 10.9% |
| load | 2.4% | 3.8% | 25.7% | 81.2% | 96.8% |
| stress 800 | **20.7%** | **65.3%** | **100%** | **100%** | **100%** |
| stress-1000 | **40.5%** | **95.6%** | **100%** | **100%** | **100%** |
| stress-1200 | **87.7%** | **96.3%** | **100%** | **100%** | **100%** |
| max-throughput | 96.1% | 95.4% | 100% | 100% | 100% |

---

## Resources — peak RAM (node_exporter, MB)

| Profile | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| smoke (idle) | 447 | 462 | 1049 | 1096 | 1177 |
| stress 800 | **479** | **644** | **1288** | **1463** | **1577** |
| stress-1000 | 516 | 721 | 1324 | 1474 | 1576 |
| stress-1200 | 697 | 742 | 1354 | 1469 | 1592 |
| max-throughput | 643 | 673 | 1343 | 1445 | 1524 |

---

## Resources — peak network TX (MB/s)

| Profile | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| stress 800 | 9.25 | 1.70 | 5.60 | 1.56 | 1.21 |
| max-throughput | 14.72 | 1.78 | 5.59 | 1.50 | 1.14 |

---

## Resources — peak disk write IOPS

| Profile | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| stress 800 | **4** | **119** | **21** | **21** | **24** |
| max-throughput | 4 | 144 | 24 | 22 | 22 |

---

## Processes at stress (800 VUs) — CPU

*CPU > 100% = multiple cores used. 4 vCPU = 400% max.*

| Process | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| **App (Go / php-fpm)** | gameap **31.5%** | pufferpanel **71.0%** | php-fpm **320.1%** | php-fpm **241.3%** | php-fpm **260.8%** |
| **DB (PostgreSQL / MySQL)** | postgresql **3.1%** | postgresql **9.0%** | mysql **31.2%** | mysql **108.8%** | mysql **93.3%** |
| **Redis** | — | — | **5.0%** | **1.9%** | — |
| **Nginx** | — | — | **3.2%** | **0.8%** | **0.7%** |
| **Total App+DB** | **~35%** | **~80%** | **~356%** | **~352%** | **~358%** |

### Processes at stress (800 VUs) — RAM (RSS)

⚠️ RSS double-counts shared memory for php-fpm. Real VM consumption is in the RAM table above.

| Process | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| **App** | gameap **66 MB** | pufferpanel **99 MB** | php-fpm **2744 MB** | php-fpm **3236 MB** | php-fpm **4183 MB** |
| **DB** | postgresql **108 MB** | postgresql **721 MB** | mysql **612 MB** | mysql **640 MB** | mysql **641 MB** |

---

## Max RPS — summary table

| Panel | Stack | RPS | vs best | Errors |
|---|---|---|---|---|
| **GameAP 4.x** | Go + PostgreSQL | **1127** | 1× | 0% |
| **PufferPanel** | Go + PostgreSQL | **698** | 1.6× slower | 0% |
| **GameAP 3.x** | PHP + MySQL + Redis | **394** | 2.9× slower | 0% |
| **Pterodactyl** | PHP + MySQL + Redis | **93** | 12× slower | 0% |
| **Pelican** | PHP + MySQL + Redis | **76** | 15× slower | 0% |

---

## Breaking point / resilience

| Panel | Stack | Max VUs without errors | Errors at 1200 VUs | Behavior |
|---|---|---|---|---|
| **GameAP 4.x** | Go | **1000 VUs** | 14.8% | Fails fast under overload |
| **PufferPanel** | Go | **800 VUs** | 34.7% | Fails fast under overload |
| **GameAP 3.x** | PHP | **1200+ VUs** | **0%** | Queues in PHP-FPM, latency climbs |
| **Pterodactyl** | PHP | **1200+ VUs** | **0%** | Queues in PHP-FPM, latency climbs |
| **Pelican** | PHP | **1200+ VUs** | **0%** | Queues in PHP-FPM, latency climbs |

**Go panels:** return errors under overload but do so quickly — the user knows the server is overloaded.

**PHP panels:** never refuse, but latency balloons to 10+ seconds — the user waits without knowing whether a response will arrive.

---

## Reproducibility (Run 1 vs Run 2)

| Metric | Max deviation | Example |
|---|---|---|
| Baseline avg | ≤5.4% | GameAP 3.x: 11.51 → 10.89 ms |
| Load avg | ≤4.0% | Pelican: 109.30 → 104.95 ms |
| Stress median | ≤4.5% | GameAP 3.x: 27.30 → 28.54 ms |
| Max RPS | ≤1.1% | Pterodactyl: 94 → 93 RPS |

All metrics within ±5.5% — confirms the methodology.

---

## Reader context

### What is a VU and how many clients does it represent

| VUs (concurrent) | Approximate number of hosting clients |
|---|---|
| 1–5 | 50–200 (small hosting) |
| 10–20 | 200–1000 (medium hosting) |
| 100 | 2000–5000 (large hosting) |
| 800 | 8000–25000 (very large) |

For a server control panel the concurrency factor is ~1–5%.

### Think-time and RPS

In scenarios with think-time, RPS ≈ 60–70 for every panel (limited by the pauses). The difference shows up in latency and in the max-throughput test (without think-time).

### RSS vs real RAM

process_exporter reports RSS. For 50 php-fpm workers, the shared memory is counted against each worker. Real consumption from node_exporter (MemTotal - MemAvailable) is 2–3× smaller than the RSS total.

### Impact of 100 servers

With 1 server the smoke latency was ~0.4 ms (Go) and ~6 ms (GameAP 3.x). With 100 servers: ~1.1 ms and ~20 ms. list_servers returns more data from the database.

### Database differences

Go panels (GameAP 4.x, PufferPanel) — PostgreSQL (developer recommendation).
PHP panels (GameAP 3.x, Pterodactyl, Pelican) — MySQL 8.0 (standard configuration).
Each group uses the same database for a fair within-group comparison.

### PufferPanel OAuth2

PufferPanel uses OAuth2 Client Credentials. The token is fetched once during the setup phase (TTL=3600s) and then used as an ordinary Bearer token. A single OAuth2 request (~58ms) is included in the smoke test metrics, which explains the avg vs med gap. On tests with 2000+ requests the impact is <0.05%.
