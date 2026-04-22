# Load Testing of Game Server Control Panels

Comparative load testing of five game server control panels: **GameAP 4.x**, **PufferPanel**, **GameAP 3.x**, **Pterodactyl**, and **Pelican**.

## Results (100 servers, median of 3 runs)

### Max throughput (RPS, 0% errors)

| Panel | Stack | RPS |
|---|---|---|---|
| **GameAP 4.x** | Go + PostgreSQL | **1126** |
| **PufferPanel** | Go + PostgreSQL | **696** |
| **GameAP 3.x** | PHP + MySQL + Redis | **394** |
| **Pterodactyl** | PHP + MySQL + Redis | **94** | 
| **Pelican** | PHP + MySQL + Redis | **76** |

### Median latency (ms) by load

| Profile | GameAP 4.x | PufferPanel | GameAP 3.x | Pterodactyl | Pelican |
|---|---|---|---|---|---|
| 1 VU | **1.08** | 2.01 | 20.37 | 26.98 | 31.30 |
| 10 VUs | **0.83** | 1.54 | 9.25 | 12.75 | 16.00 |
| 100 VUs | **0.59** | 1.37 | 8.78 | 20.80 | 53.30 |
| 800 VUs | **0.57** | 1.44 | 27.93 | 1130 | 1528 |
| 1000 VUs | **0.76** | 114 | 1484 | 7887 | 10217 |
| 1200 VUs | 24.17 | 97.20 | 1959 | 10575 | 12839 |

> Detailed results: [docs/RESULTS-FINAL.md](docs/RESULTS-FINAL.md)

## Methodology

- **Sequential testing** — one panel at a time, all other VMs powered off
- **Identical conditions** — same PHP/MySQL/OPcache settings for PHP panels
- **100 game servers** (clock-mock) on every panel
- **3 full runs** — results averaged, reproducibility ≤5.5%
- **7 load profiles** — from 1 VU up to 1200 VUs + max throughput
- **3 API endpoints** — list_servers, server_details, server_status

### Infrastructure

| Component | Specification |
|---|---|
| Server | Intel Xeon E-2456, 32 GB DDR5 ECC, 2× Samsung 990 PRO NVMe RAID1 |
| Hypervisor | Proxmox VE 9.1.5, Debian 13 |
| Panel VM | 4 vCPU, 8 GB RAM, Ubuntu 24.04 |
| Daemon VM | 6 vCPU, 12 GB RAM, Ubuntu 24.04 |
| Load testing tool | k6 v1.7.1 |
| Monitoring | Prometheus + Grafana + node_exporter + process_exporter |

### Tuning

- CPU governor: performance, C-states: C1, Turbo Boost: on, Swap: off
- PHP-FPM: pm.max_children=50, OPcache JIT tracing, opcache.memory=256MB
- MySQL: innodb_buffer_pool_size=2G, max_connections=200
- Rate limits: disabled on Pterodactyl/Pelican (APP_API_CLIENT_RATELIMIT=10000)

## Repository structure

```
├── README.md                        # This file
├── docs/
│   ├── RESULTS-FINAL.md             # Detailed results
│   └── PROJECT.md                   # Project documentation
├── k6-project/                      # k6 load testing scenarios
│   ├── config/
│   │   ├── panels.js                # Panel configuration (tokens replaced)
│   │   ├── stages.js                # Load profiles
│   │   ├── thresholds.js            # SLO thresholds
│   │   └── endpoints.js             # API adapters for each panel
│   ├── lib/
│   │   ├── auth.js                  # API key, OAuth2, CSRF
│   │   ├── metrics.js               # Custom metrics
│   │   └── utils.js                 # Think-time, randomItem
│   ├── scenarios/
│   │   ├── api-read.js              # list → details → status
│   │   ├── max-throughput.js        # No think-time, RPS ceiling
│   │   ├── auth-test.js             # Authentication loop
│   │   └── hello.js                 # Smoke: GET /login
│   └── Makefile
├── scripts/
│   ├── run-final.sh                 # Full run automation
│   ├── collect-metrics.sh           # Collect metrics from Prometheus
│   ├── create-servers.sh            # Create game servers on all panels
│   ├── fix-all-process-exporters.sh # process_exporter config for all VMs
│   ├── add-redis-gameap3.sh         # Install Redis on GameAP 3.x
│   ├── collect-all-data.sh          # Collect data from all VMs
│   └── restore-vm.sh               # Restore a VM from snapshot
├── configs/
│   ├── egg-clock-mock.json          # Pterodactyl/Pelican egg for clock-mock
│   ├── php/
│   │   ├── www.conf                 # PHP-FPM pool config
│   │   └── opcache.ini              # OPcache + JIT
│   ├── mysql/
│   │   └── 99-loadtest.cnf          # MySQL InnoDB tuning
│   ├── sysctl/
│   │   └── 99-loadtest.conf         # Kernel tuning
│   └── process-exporter/
│       └── config.yml               # Tracked processes
└── results/                         # Raw data from 3 runs
    ├── run1/
    │   ├── gameap-4/                # k6 JSON + Prometheus CSV
    │   ├── pufferpanel/
    │   ├── gameap-3/
    │   ├── pterodactyl/
    │   └── pelican/
    ├── run2/
    └── run3/
```

## How to reproduce

### 1. Infrastructure preparation

A bare-metal server with Proxmox VE is required. Create VMs according to the table in [docs/PROJECT.md](docs/PROJECT.md).

Apply host tuning:
```bash
cp configs/sysctl/99-loadtest.conf /etc/sysctl.d/
sysctl --system
```

### 2. Installing the panels

Each panel is installed in its own VM following the official documentation:

| Panel | Installation |
|---|---|
| GameAP 3.x | `gameapctl --version=3` |
| GameAP 4.x | `gameapctl --version=4 --database=postgres` |
| Pterodactyl | [pterodactyl.io/docs](https://pterodactyl.io) |
| Pelican | [pelican.dev/docs](https://pelican.dev) |
| PufferPanel | [docs.pufferpanel.com](https://docs.pufferpanel.com) |

### 3. PHP panel tuning

```bash
# On each PHP panel (gameap-3, pterodactyl, pelican):
cp configs/php/www.conf /etc/php/8.4/fpm/pool.d/www.conf
cp configs/php/opcache.ini /etc/php/8.4/mods-available/opcache.ini
cp configs/mysql/99-loadtest.cnf /etc/mysql/conf.d/
systemctl restart php8.4-fpm mysql
```

### 4. Creating game servers

Import the egg for Pterodactyl/Pelican:
```bash
# In Admin → Nests → Import Egg
# File: configs/egg-clock-mock.json
```

Create 100 servers on every panel:
```bash
bash scripts/create-servers.sh all 100
```

### 5. Monitoring setup

Install on every VM:
- `node_exporter` (port 9100)
- `process_exporter` with the config from `configs/process-exporter/config.yml` (port 9256)

### 6. Running k6

```bash
# On the k6-runner:
scp -r k6-project/ k6-runner:/home/ubuntu/

# Edit the tokens:
nano k6-project/config/panels.js

# Single profile:
cd k6-project && PANEL=gameap-4 PROFILE=baseline k6 run scenarios/api-read.js

# Full run (from the host):
bash scripts/run-final.sh gameap-4        # single panel
bash scripts/run-final.sh all             # all panels sequentially
```

### 7. Collecting metrics

```bash
bash scripts/collect-metrics.sh gameap-4
bash scripts/collect-metrics.sh all
```

## Key takeaways

1. **Go vs PHP** — an order-of-magnitude performance difference (13–267× by latency)
2. **Architecture matters more than language** — GameAP 4.x is 1.6× more efficient than PufferPanel even though both use Go
3. **MySQL is the bottleneck** for Pterodactyl/Pelican (93–109% CPU vs 31% on GameAP 3.x)
4. **PHP doesn't fail, Go fails fast** — different behavior under overload
5. **GameAP 3.x is the best PHP stack** (394 RPS vs 76–93 for Pterodactyl/Pelican)

## License

MIT
