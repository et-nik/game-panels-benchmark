#!/bin/bash
# =============================================================
# Restore VM from snapshot created by collect-all-data.sh
# =============================================================
# Usage: ./restore-vm.sh <snapshot_dir_or_tar>
#
# Example:
#   ./restore-vm.sh /path/to/gameap-4/snapshot.tar.gz
#   ./restore-vm.sh /path/to/gameap-4/   (extracted directory)
#
# Prerequisites:
#   - Fresh Ubuntu 24.04 LTS
#   - Run as root
#   - Internet access (for apt install)
#
# What it does:
#   1. Restores apt sources and installs packages
#   2. Restores /etc (configs)
#   3. Restores /var/www (web apps) + composer install
#   4. Restores databases (MySQL / PostgreSQL)
#   5. Restores home directories
#   6. Restores systemd overrides
#   7. Restarts all services
# =============================================================

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*"; }

if [ "$(id -u)" != "0" ]; then
    err "Run as root"
    exit 1
fi

INPUT="${1:?Usage: $0 <snapshot_dir_or_tar.gz>}"

# ========================
# Extract if tar.gz
# ========================
if [ -f "$INPUT" ]; then
    SNAP=$(mktemp -d /tmp/vm-restore.XXXXXX)
    log "Extracting $INPUT → $SNAP"
    tar xzf "$INPUT" -C "$SNAP"
elif [ -d "$INPUT" ]; then
    SNAP="$INPUT"
else
    err "Not found: $INPUT"
    exit 1
fi

log "Snapshot dir: $SNAP"
log "Hostname was: $(cat $SNAP/hostname.txt 2>/dev/null || echo 'unknown')"
echo ""

# ========================
# Helper: check if file exists in snapshot
# ========================
has() { [ -f "$SNAP/$1" ] || [ -d "$SNAP/$1" ]; }

# ========================
# Step 1: APT sources and packages
# ========================
log "=== Step 1: APT sources and packages ==="

if has "sources.list.d"; then
    log "Restoring apt sources..."
    cp -f "$SNAP/sources.list" /etc/apt/sources.list 2>/dev/null || true
    # Restore additional repos but skip the base ubuntu.sources
    for f in "$SNAP/sources.list.d/"*; do
        fname=$(basename "$f")
        if [ "$fname" != "ubuntu.sources" ] && [ "$fname" != "ubuntu.sources.backup" ]; then
            cp -f "$f" /etc/apt/sources.list.d/ 2>/dev/null || true
            log "  Added repo: $fname"
        fi
    done
fi

log "Running apt update..."
apt-get update -qq 2>/dev/null

if has "dpkg-selections.txt"; then
    log "Installing packages from dpkg-selections.txt..."
    # Filter to only 'install' selections
    grep -P '\tinstall$' "$SNAP/dpkg-selections.txt" | dpkg --set-selections 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get dselect-upgrade -y -qq 2>&1 | tail -5

    # Fix any broken deps
    apt-get -f install -y -qq 2>/dev/null
    log "  Packages installed"
else
    warn "No dpkg-selections.txt found, skipping package install"
fi

echo ""

# ========================
# Step 2: Restore /etc
# ========================
log "=== Step 2: Restore /etc configs ==="

if has "etc.tar.gz"; then
    log "Restoring /etc..."
    # Extract to temp, then selectively copy (don't overwrite critical system files)
    ETCTMP=$(mktemp -d /tmp/etc-restore.XXXXXX)
    tar xzf "$SNAP/etc.tar.gz" -C "$ETCTMP" 2>/dev/null

    # Selective restore — config dirs that matter
    for dir in nginx php mysql postgresql redis pufferpanel \
               process-exporter systemd/system sysctl.d security/limits.d \
               default apt/sources.list.d; do
        if [ -d "$ETCTMP/etc/$dir" ]; then
            mkdir -p "/etc/$dir"
            cp -a "$ETCTMP/etc/$dir/." "/etc/$dir/" 2>/dev/null
            log "  Restored /etc/$dir"
        fi
    done

    # Individual config files
    for f in hostname hosts environment; do
        if [ -f "$ETCTMP/etc/$f" ]; then
            cp -f "$ETCTMP/etc/$f" "/etc/$f" 2>/dev/null
            log "  Restored /etc/$f"
        fi
    done

    rm -rf "$ETCTMP"
else
    warn "No etc.tar.gz found"
fi

# Restore standalone config files
for f in 99-loadtest.conf mysqldump.cnf mysql.cnf process-exporter-config.yml; do
    if has "$f"; then
        case "$f" in
            99-loadtest.conf)
                cp -f "$SNAP/$f" /etc/sysctl.d/ 2>/dev/null && log "  Restored sysctl: $f"
                ;;
            process-exporter-config.yml)
                mkdir -p /etc/process-exporter
                cp -f "$SNAP/$f" /etc/process-exporter/config.yml 2>/dev/null && log "  Restored process-exporter config"
                ;;
        esac
    fi
done

sysctl --system > /dev/null 2>&1 && log "  Applied sysctl"
echo ""

# ========================
# Step 3: Restore /var/www
# ========================
log "=== Step 3: Restore /var/www ==="

if has "var-www.tar.gz"; then
    log "Restoring /var/www..."
    tar xzf "$SNAP/var-www.tar.gz" -C / 2>/dev/null
    log "  Extracted"

    # Run composer install for Laravel apps
    for app_dir in /var/www/gameap /var/www/pterodactyl /var/www/pelican /var/www/html; do
        if [ -f "$app_dir/composer.json" ]; then
            log "  Running composer install in $app_dir..."
            cd "$app_dir"
            if command -v composer &>/dev/null; then
                sudo -u www-data composer install --no-dev --optimize-autoloader --no-interaction 2>&1 | tail -3
            else
                warn "  composer not found, install it: apt install composer"
            fi
        fi
    done

    # Fix permissions
    for app_dir in /var/www/gameap /var/www/pterodactyl /var/www/pelican /var/www/html; do
        if [ -d "$app_dir" ]; then
            chown -R www-data:www-data "$app_dir" 2>/dev/null
            chmod -R 755 "$app_dir" 2>/dev/null
            [ -d "$app_dir/storage" ] && chmod -R 775 "$app_dir/storage" 2>/dev/null
            [ -d "$app_dir/bootstrap/cache" ] && chmod -R 775 "$app_dir/bootstrap/cache" 2>/dev/null
        fi
    done
    log "  Permissions fixed"
else
    warn "No var-www.tar.gz found"
fi

echo ""

# ========================
# Step 4: Restore /srv
# ========================
if has "srv.tar.gz"; then
    log "=== Step 4: Restore /srv ==="
    tar xzf "$SNAP/srv.tar.gz" -C / 2>/dev/null
    log "  Restored /srv"
    echo ""
fi

# ========================
# Step 5: Restore databases
# ========================
log "=== Step 5: Restore databases ==="

if has "mysql-all.sql.gz"; then
    log "Restoring MySQL..."
    if systemctl is-active mysql &>/dev/null || systemctl start mysql 2>/dev/null; then
        gunzip -c "$SNAP/mysql-all.sql.gz" | mysql 2>/dev/null
        if [ $? -eq 0 ]; then
            log "  MySQL restored"
        else
            err "  MySQL restore failed — check if mysql is running and accessible"
        fi
    else
        warn "  MySQL not running, trying to start..."
        systemctl start mysql 2>/dev/null
        if systemctl is-active mysql &>/dev/null; then
            gunzip -c "$SNAP/mysql-all.sql.gz" | mysql 2>/dev/null
            log "  MySQL restored"
        else
            err "  Cannot start MySQL — restore manually: gunzip -c mysql-all.sql.gz | mysql"
        fi
    fi
fi

if has "postgresql-all.sql.gz"; then
    log "Restoring PostgreSQL..."
    if systemctl is-active postgresql &>/dev/null || systemctl start postgresql 2>/dev/null; then
        gunzip -c "$SNAP/postgresql-all.sql.gz" | sudo -u postgres psql 2>/dev/null
        if [ $? -eq 0 ]; then
            log "  PostgreSQL restored"
        else
            err "  PostgreSQL restore failed — check if postgresql is running"
        fi
    else
        warn "  PostgreSQL not running, trying to start..."
        systemctl start postgresql 2>/dev/null
        if systemctl is-active postgresql &>/dev/null; then
            gunzip -c "$SNAP/postgresql-all.sql.gz" | sudo -u postgres psql 2>/dev/null
            log "  PostgreSQL restored"
        else
            err "  Cannot start PostgreSQL — restore manually: gunzip -c postgresql-all.sql.gz | sudo -u postgres psql"
        fi
    fi
fi

echo ""

# ========================
# Step 6: Restore home directories
# ========================
log "=== Step 6: Restore home directories ==="

for home_tar in "$SNAP"/home-*.tar.gz; do
    [ -f "$home_tar" ] || continue
    fname=$(basename "$home_tar")
    log "  Restoring $fname..."
    tar xzf "$home_tar" -C / 2>/dev/null
done

echo ""

# ========================
# Step 7: Restore systemd overrides
# ========================
log "=== Step 7: Restore systemd overrides ==="

if has "systemd-overrides.tar.gz"; then
    tar xzf "$SNAP/systemd-overrides.tar.gz" -C / 2>/dev/null
    systemctl daemon-reload
    log "  Systemd overrides restored and reloaded"
fi

echo ""

# ========================
# Step 8: Restart services
# ========================
log "=== Step 8: Restart services ==="

# Detect which services exist and restart them
for svc in nginx php8.4-fpm php8.3-fpm mysql postgresql redis-server \
           gameap pufferpanel wings gameap-daemon \
           process-exporter node_exporter chronyd; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null | grep -q "$svc"; then
        systemctl restart "$svc" 2>/dev/null && log "  Restarted $svc" || warn "  Failed to restart $svc"
    fi
done

echo ""

# ========================
# Step 9: Verify
# ========================
log "=== Step 9: Verify ==="

log "Running services:"
systemctl list-units --type=service --state=running --no-pager 2>/dev/null | \
    grep -E "nginx|php|mysql|postgres|redis|gameap|pufferpanel|wings|process-expo|node_expo" | \
    sed 's/^/  /'

echo ""

# Check if web apps respond
for url in "http://localhost" "http://localhost:80" "http://localhost:8080"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" --max-time 3 2>/dev/null)
    if [ "$code" != "000" ] && [ "$code" != "" ]; then
        log "  $url → HTTP $code"
    fi
done

echo ""
log "=== RESTORE COMPLETE ==="
echo ""
echo "Notes:"
echo "  - Check /etc configs match your new IP addresses"
echo "  - Update .env files if IP changed"
echo "  - If Laravel: php artisan config:cache && php artisan route:cache"
echo "  - If Wings: update config.yml with new FQDN/IP"
echo "  - Verify database connectivity"

# Cleanup temp dir if we extracted
if [ -f "$INPUT" ]; then
    rm -rf "$SNAP"
fi
