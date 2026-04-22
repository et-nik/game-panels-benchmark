# Load Testing — Game Server Panels

Comparative load testing: GameAP 3.x (PHP) vs GameAP 4.x (Go) vs Pterodactyl (PHP) vs Pelican (PHP).

## Quick start

```bash
# Smoke test
make smoke PANEL=gameap-3

# Auth performance test
make smoke PANEL=gameap-3 SCENARIO=auth-test

# API read test (list, details, status, console)
make baseline PANEL=gameap-3 SCENARIO=api-read

# Compare GameAP 3.x vs 4.x
make compare-gameap SCENARIO=api-read PROFILE=load

# Compare all 4 panels
make compare SCENARIO=api-read PROFILE=load
```

## Panels

| Panel | Stack | VM | IP |
|---|---|---|---|
| `gameap-3` | PHP/Laravel + MariaDB | gameap-3 | 10.10.10.10 |
| `gameap-4` | Go + PostgreSQL | gameap-4 | 10.10.10.11 |
| `pterodactyl` | PHP/Laravel + MariaDB | pterodactyl | 10.10.10.12 |
| `pelican` | PHP/Laravel + MariaDB | pelican | 10.10.10.13 |

## Scenarios

| Scenario | File | Description |
|---|---|---|
| `hello` | scenarios/hello.js | GET /login page (smoke) |
| `auth-test` | scenarios/auth-test.js | Full login cycle (bcrypt + session/token) |
| `api-read` | scenarios/api-read.js | List → details → status → console |
| `api-write` | scenarios/api-write.js | Start/stop server cycle |

## Profiles

| Profile | VUs | Duration | Purpose |
|---|---|---|---|
| `smoke` | 1 | 30s | Verify everything works |
| `baseline` | 10 | 4.5m | Baseline metrics |
| `load` | 100 | 11m | Normal load |
| `stress` | 800 | 10m | Find breaking point |
| `soak` | 50 | 4h | Check for memory leaks |

## Metrics

k6 sends metrics to Prometheus via remote-write. Tags:
- `panel` — gameap-3 / gameap-4 / pterodactyl / pelican
- `stack` — PHP / Go
- `scenario` — which scenario
- `profile` — which profile
- `endpoint` — specific API endpoint
- `run_id` — unique timestamp

Custom metrics: `login_duration`, `list_servers_duration`, `server_details_duration`,
`server_status_duration`, `server_console_duration`, `server_start_duration`, `server_stop_duration`.
