#!/usr/bin/env bash
#
# kong-install.sh - Install Kong Gateway OSS 3.9.x on Ubuntu 24.04
#
# Modes:
#   cp  Hybrid control plane  (Postgres, Admin API, Kong Manager, cluster listener)
#   dp  Hybrid data plane     (DB-less, receives config from the CP)
#   st  Standalone            (Postgres, proxy + Admin API on one node)
#
# Usage:
#   sudo ./kong-install.sh -m cp [-v 3.9.4] [-c ./kong-install.conf]
#   sudo ./kong-install.sh -m dp [-v 3.9.4] [-c ./kong-install.conf]
#   sudo ./kong-install.sh                  # prompts for the mode
#
# Safe to re-run: existing cluster certs, DB role/database and the stored DB
# password are reused; kong.conf is backed up before being rewritten.
#
# Change freeze (cp / st): with LOCK_AFTER_DAYS > 0 the Admin API and Kong
# Manager are switched off N days after the first install. Helper commands:
#   kong-lock.sh --status | --now        kong-unlock.sh [DAYS]
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Defaults (can be overridden in the config file or on the command line)
# ---------------------------------------------------------------------------
KONG_PACKAGE_NAME=kong
DEFAULT_KONG_VERSION=3.9.4
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF_FILE=$SCRIPT_DIR/kong-install.conf
MODE=""

KONG_DIR=/etc/kong
KONG_CONFIG=$KONG_DIR/kong.conf
KONG_PREFIX=/usr/local/kong
PG_PASS_FILE=$KONG_DIR/pg_password
LOG=/var/log/kong-install.log
NOFILE_LIMIT=65536

SBIN_DIR=/usr/local/sbin
LOCK_FILE=$KONG_DIR/LOCKED
LOCK_DATE_FILE=$KONG_DIR/lock-date
LOCK_AT=""

KONG_PG_PASSWORD=""
KONG_BIN=""
OPT_VERSION=""
OPT_PACKAGE=""

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a          # stop Ubuntu 24.04 needrestart from prompting
export DEBCONF_NOWARNINGS=yes
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
warn() { echo "[$(date '+%F %T')] WARN: $*" | tee -a "$LOG" >&2; }
die()  { echo "[$(date '+%F %T')] ERROR: $*" | tee -a "$LOG" >&2; exit 1; }
run()  { echo "+ $*" >>"$LOG"; "$@" >>"$LOG" 2>&1; }

on_error() {
    local rc=$? line=$1
    echo "ERROR: command failed at line $line (exit $rc). Last lines of $LOG:" >&2
    tail -n 20 "$LOG" >&2 || true
    exit "$rc"
}
trap 'on_error $LINENO' ERR

usage() {
    cat <<EOF
Usage: sudo $0 [-m cp|dp|st] [-v version] [-p package] [-c config_file]

  -m  Install mode: cp (control plane), dp (data plane), st (standalone)
  -v  Kong version (default: ${DEFAULT_KONG_VERSION})
  -p  Package name (only 'kong' / OSS is supported by this script)
  -c  Config file (default: ${CONF_FILE})
EOF
}

parse_args() {
    local o
    while getopts "m:p:v:c:h" o; do
        case "$o" in
            m) MODE=$OPTARG ;;
            p) OPT_PACKAGE=$OPTARG ;;
            v) OPT_VERSION=$OPTARG ;;
            c) CONF_FILE=$OPTARG ;;
            h) usage; exit 0 ;;
            *) usage; exit 1 ;;
        esac
    done
}

require_root() {
    [[ $EUID -eq 0 ]] || { echo "Please run as root: sudo $0" >&2; exit 1; }
}

init_log() {
    touch "$LOG"
    chmod 600 "$LOG"
    echo "===== kong-install run $(date '+%F %T') =====" >>"$LOG"
}

load_config() {
    if [[ -f $CONF_FILE ]]; then
        # shellcheck source=/dev/null
        . "$CONF_FILE"
        log "Loaded config from $CONF_FILE"
    else
        warn "Config file $CONF_FILE not found, using defaults (local PostgreSQL)"
    fi

    # Command line wins over the config file
    KONG_PACKAGE_NAME=${OPT_PACKAGE:-$KONG_PACKAGE_NAME}
    KONG_PACKAGE_VERSION=${OPT_VERSION:-${KONG_PACKAGE_VERSION:-$DEFAULT_KONG_VERSION}}

    HOST_CP=${HOST_CP:-}
    CONF_AUTHOR=${CONF_AUTHOR:-${SUDO_USER:-root}}
    TIMEZONE=${TIMEZONE:-Asia/Bangkok}
    POSTGRES_HOST=${POSTGRES_HOST:-}
    POSTGRES_PORT=${POSTGRES_PORT:-5432}
    POSTGRES_ADMIN_USER=${POSTGRES_ADMIN_USER:-postgres}
    POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-}
    POSTGRES_SSL=${POSTGRES_SSL:-on}
    CLUSTER_CERT_DIR=${CLUSTER_CERT_DIR:-./}
    LOCK_AFTER_DAYS=${LOCK_AFTER_DAYS:-0}
    LOCK_ADMIN_MODE=${LOCK_ADMIN_MODE:-off}
}

choose_mode() {
    if [[ -z $MODE ]]; then
        echo "This script installs Kong Gateway OSS ${KONG_PACKAGE_VERSION}."
        echo "Choose what to deploy: [cp] Control Plane, [dp] Data Plane, [st] Standalone"
        while true; do
            read -rp "Install mode (cp/dp/st): " MODE || die "No input received"
            case $MODE in
                cp|dp|st) break ;;
                *) echo "Please answer cp, dp or st." ;;
            esac
        done
    fi
}

validate() {
    case $MODE in
        cp|dp|st) ;;
        *) die "Invalid mode '$MODE' (use cp, dp or st)" ;;
    esac

    [[ $KONG_PACKAGE_NAME == kong ]] \
        || die "This script targets Kong OSS only (-p kong), got '$KONG_PACKAGE_NAME'"

    [[ $KONG_PACKAGE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Version '$KONG_PACKAGE_VERSION' is not in OSS format X.Y.Z (e.g. 3.9.4)"

    if [[ $MODE == dp ]]; then
        [[ -n $HOST_CP ]] || die "HOST_CP must be set in $CONF_FILE for dp mode"
        [[ $HOST_CP != *://* && $HOST_CP != *:* ]] \
            || die "HOST_CP must be a bare hostname or IP (no scheme, no port), got '$HOST_CP'"
    fi

    if [[ $MODE != dp && -n $POSTGRES_HOST ]]; then
        [[ -n $POSTGRES_PASSWORD ]] \
            || die "POSTGRES_PASSWORD is required when POSTGRES_HOST is set"
        [[ $POSTGRES_SSL == on || $POSTGRES_SSL == off ]] \
            || die "POSTGRES_SSL must be 'on' or 'off'"
        [[ $POSTGRES_ADMIN_USER != kong ]] \
            || die "POSTGRES_ADMIN_USER must not be 'kong': the installer creates the 'kong' role itself. Use the Postgres superuser (usually 'postgres')"
    fi

    [[ $LOCK_AFTER_DAYS =~ ^[0-9]+$ ]] \
        || die "LOCK_AFTER_DAYS must be a whole number of days (0 = disabled)"
    [[ $LOCK_ADMIN_MODE == off || $LOCK_ADMIN_MODE == local ]] \
        || die "LOCK_ADMIN_MODE must be 'off' or 'local'"
}

check_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found"
    local os_id os_ver
    os_id=$(. /etc/os-release && echo "${ID:-}")
    os_ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
    [[ $os_id == ubuntu ]] || die "Unsupported OS: $os_id (Ubuntu only)"
    if [[ $os_ver != "24.04" ]]; then
        warn "This script is written for Ubuntu 24.04, found $os_ver"
    fi
    log "OS: Ubuntu $os_ver"
}

set_timezone() {
    if command -v timedatectl >/dev/null 2>&1 \
        && timedatectl set-timezone "$TIMEZONE" >>"$LOG" 2>&1; then
        log "Timezone set to $TIMEZONE"
    else
        warn "Could not set timezone with timedatectl (container?), continuing"
    fi
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
install_prereqs() {
    log "Installing prerequisites"
    run apt-get update
    run apt-get install "${APT_OPTS[@]}" curl ca-certificates gnupg tzdata openssl
}

add_kong_repo() {
    local tag url
    tag=$(awk -F. '{print $1 $2}' <<<"$KONG_PACKAGE_VERSION")
    url="https://packages.konghq.com/public/gateway-${tag}/setup.deb.sh"
    log "Adding Kong repository gateway-${tag}"
    run curl -1sLf "$url" -o /tmp/kong-repo-setup.sh
    run bash /tmp/kong-repo-setup.sh
    rm -f /tmp/kong-repo-setup.sh
    run apt-get update
}

check_version_available() {
    local available
    available=$(apt-cache madison "$KONG_PACKAGE_NAME" | awk '{print $3}')
    if ! grep -qx "$KONG_PACKAGE_VERSION" <<<"$available"; then
        echo "Versions of '$KONG_PACKAGE_NAME' available in the repo:" >&2
        echo "${available:-  (none)}" >&2
        die "Version $KONG_PACKAGE_VERSION not found for this Ubuntu release"
    fi
    log "Found $KONG_PACKAGE_NAME $KONG_PACKAGE_VERSION in repository"
}

install_kong() {
    local installed
    installed=$(dpkg-query -W -f='${Version}' "$KONG_PACKAGE_NAME" 2>/dev/null || true)

    if [[ $installed == "$KONG_PACKAGE_VERSION" ]]; then
        log "$KONG_PACKAGE_NAME $KONG_PACKAGE_VERSION already installed"
    else
        if [[ -n $installed ]]; then
            warn "Changing installed version $installed -> $KONG_PACKAGE_VERSION"
        fi
        run apt-mark unhold "$KONG_PACKAGE_NAME" || true
        log "Installing $KONG_PACKAGE_NAME=$KONG_PACKAGE_VERSION"
        run apt-get install "${APT_OPTS[@]}" --allow-downgrades \
            "${KONG_PACKAGE_NAME}=${KONG_PACKAGE_VERSION}"
    fi

    # Prevent unattended upgrades from moving Kong to another version
    run apt-mark hold "$KONG_PACKAGE_NAME"

    KONG_BIN=$(command -v kong) || die "kong binary not found after install"
    install -d -m 755 "$KONG_DIR"
    log "Kong binary: $KONG_BIN ($(kong version 2>/dev/null || echo unknown))"
}

# ---------------------------------------------------------------------------
# Database (cp / st)
# ---------------------------------------------------------------------------
pg_local() {
    (cd / && runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -qAt "$@")
}

pg_remote() {
    local sslmode=prefer
    if [[ $POSTGRES_SSL == on ]]; then sslmode=require; fi
    PGPASSWORD="$POSTGRES_PASSWORD" PGSSLMODE="$sslmode" \
        psql -X -v ON_ERROR_STOP=1 -qAt \
        -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_ADMIN_USER" "$@"
}

setup_local_postgres() {
    # Nothing else (e.g. a Docker container) may hold the Postgres port
    if ss -ltnpH 'sport = :5432' 2>/dev/null | grep -qv postgres; then
        ss -ltnp 'sport = :5432' >&2 || true
        die "Port 5432 is already used by another process (a Docker container?). Stop it or set POSTGRES_HOST to use it"
    fi

    if ! dpkg-query -W -f='${Status}' postgresql 2>/dev/null | grep -q "ok installed"; then
        log "Installing PostgreSQL"
        run apt-get install "${APT_OPTS[@]}" postgresql
    else
        log "PostgreSQL already installed"
    fi
    run systemctl enable postgresql

    # Make sure a cluster exists (it is missing if /etc/postgresql was deleted)
    if [[ -z $(pg_lsclusters -h 2>/dev/null) ]]; then
        local pgver
        pgver=$(find /usr/lib/postgresql -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -V | tail -n 1)
        [[ -n $pgver ]] || die "No PostgreSQL server binaries found in /usr/lib/postgresql"
        log "No PostgreSQL cluster found, creating ${pgver}/main"
        run pg_createcluster "$pgver" main
    fi

    # Start each cluster's own unit explicitly; on LXC the postgresql
    # wrapper service does not always start postgresql@VER-NAME by itself
    local ver name
    while read -r ver name _; do
        log "Starting PostgreSQL cluster ${ver}/${name}"
        if ! run systemctl enable --now "postgresql@${ver}-${name}"; then
            die "Could not start postgresql@${ver}-${name}. Check: journalctl -u postgresql@${ver}-${name} -n 50"
        fi
    done < <(pg_lsclusters -h)

    log "Waiting for PostgreSQL to accept connections"
    local up=0
    for _ in $(seq 1 30); do
        if (cd / && runuser -u postgres -- pg_isready -q) >>"$LOG" 2>&1; then up=1; break; fi
        sleep 1
    done
    if (( ! up )); then
        pg_lsclusters >>"$LOG" 2>&1 || true
        die "Local PostgreSQL did not become ready. Check: pg_lsclusters and journalctl -u 'postgresql@*' -n 50"
    fi
    log "PostgreSQL is ready"
}

ensure_pg_password() {
    if [[ ! -s $PG_PASS_FILE ]]; then
        (umask 077 && openssl rand -hex 16 >"$PG_PASS_FILE")
        log "Generated new Kong DB password (stored in $PG_PASS_FILE)"
    else
        log "Reusing Kong DB password from $PG_PASS_FILE"
    fi
    chmod 600 "$PG_PASS_FILE"
    KONG_PG_PASSWORD=$(<"$PG_PASS_FILE")
}

setup_database() {
    local psql_fn role_exists db_exists

    if [[ -n $POSTGRES_HOST ]]; then
        log "Using external PostgreSQL at $POSTGRES_HOST:$POSTGRES_PORT"
        run apt-get install "${APT_OPTS[@]}" postgresql-client
        psql_fn=pg_remote
    else
        setup_local_postgres
        psql_fn=pg_local
    fi

    ensure_pg_password

    log "Testing database connection"
    if ! "$psql_fn" -d postgres -c "SELECT 1" >>"$LOG" 2>&1; then
        if [[ -n $POSTGRES_HOST ]]; then
            die "Cannot connect to ${POSTGRES_HOST}:${POSTGRES_PORT} as ${POSTGRES_ADMIN_USER} (ssl=${POSTGRES_SSL}). See the psql error above in $LOG"
        else
            die "Cannot connect to local PostgreSQL. See the psql error above in $LOG"
        fi
    fi

    # Commands below contain the password, so they are not echoed to the log
    role_exists=$("$psql_fn" -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname='kong'" 2>>"$LOG")
    if [[ $role_exists == 1 ]]; then
        log "DB role 'kong' exists, syncing its password"
        "$psql_fn" -d postgres -c "ALTER ROLE kong WITH LOGIN PASSWORD '${KONG_PG_PASSWORD}'" >>"$LOG" 2>&1
    else
        log "Creating DB role 'kong'"
        "$psql_fn" -d postgres -c "CREATE ROLE kong WITH LOGIN PASSWORD '${KONG_PG_PASSWORD}'" >>"$LOG" 2>&1
    fi

    # Managed Postgres (RDS, Cloud SQL...) needs this to create a DB owned by kong
    if [[ -n $POSTGRES_HOST ]]; then
        "$psql_fn" -d postgres -c "GRANT kong TO \"${POSTGRES_ADMIN_USER}\"" >>"$LOG" 2>&1
    fi

    db_exists=$("$psql_fn" -d postgres -c "SELECT 1 FROM pg_database WHERE datname='kong'" 2>>"$LOG")
    if [[ $db_exists == 1 ]]; then
        log "Database 'kong' already exists"
    else
        log "Creating database 'kong'"
        "$psql_fn" -d postgres -c "CREATE DATABASE kong OWNER kong" >>"$LOG" 2>&1
    fi

    "$psql_fn" -d kong -c "GRANT ALL ON SCHEMA public TO kong" >>"$LOG" 2>&1
}

run_migrations() {
    local rc
    if kong migrations list -c "$KONG_CONFIG" >>"$LOG" 2>&1; then rc=0; else rc=$?; fi

    case $rc in
        0) log "Database schema is up to date" ;;
        3) log "Bootstrapping database"
           run kong migrations bootstrap -c "$KONG_CONFIG" ;;
        4) log "Finishing pending migrations"
           run kong migrations finish -c "$KONG_CONFIG" ;;
        5) log "Running new migrations"
           run kong migrations up -c "$KONG_CONFIG"
           run kong migrations finish -c "$KONG_CONFIG" ;;
        *) die "'kong migrations list' failed (exit $rc), check DB connectivity in $LOG" ;;
    esac
}

# ---------------------------------------------------------------------------
# Cluster certificate (cp / dp)
# ---------------------------------------------------------------------------
fix_cert_perms() {
    chmod 644 "$KONG_DIR/cluster.crt"
    chmod 640 "$KONG_DIR/cluster.key"
    if getent group kong >/dev/null 2>&1; then
        chown root:kong "$KONG_DIR/cluster.crt" "$KONG_DIR/cluster.key"
    fi
}

setup_cluster_cert_cp() {
    if [[ -s $KONG_DIR/cluster.crt && -s $KONG_DIR/cluster.key ]]; then
        log "Reusing existing cluster certificate in $KONG_DIR"
    else
        log "Generating cluster certificate"
        run kong hybrid gen_cert "$KONG_DIR/cluster.crt" "$KONG_DIR/cluster.key"
    fi
    fix_cert_perms
}

setup_cluster_cert_dp() {
    local src
    src=$(realpath -m "${CLUSTER_CERT_DIR%/}")

    if [[ $src != "$KONG_DIR" && -s $src/cluster.crt && -s $src/cluster.key ]]; then
        log "Installing cluster certificate from $src"
        install -m 644 "$src/cluster.crt" "$KONG_DIR/cluster.crt"
        install -m 640 "$src/cluster.key" "$KONG_DIR/cluster.key"
    elif [[ -s $KONG_DIR/cluster.crt && -s $KONG_DIR/cluster.key ]]; then
        log "Reusing existing cluster certificate in $KONG_DIR"
    else
        die "cluster.crt/cluster.key not found. Copy them from the CP ($KONG_DIR/) into $src and re-run"
    fi
    fix_cert_perms
}

# ---------------------------------------------------------------------------
# kong.conf
# ---------------------------------------------------------------------------
conf_header() {
    cat <<EOF
#============================================
#===|          Kong Configured           |===
# File: kong.conf
# Configurator: ${CONF_AUTHOR}
# Date: $(date '+%Y-%m-%d %H:%M %Z')
# Description: Non-default configuration only.
#              All other values use defaults, see ${KONG_DIR}/kong.conf.default
# Package: ${KONG_PACKAGE_NAME} ${KONG_PACKAGE_VERSION}
# Mode: ${MODE}
#
# Change History:
# YYYY-MM-DD: Description of the change and who made it.
#
# Version: 1.0
#============================================
EOF
}

conf_postgres() {
    local host=127.0.0.1 port=5432 ssl=off
    if [[ -n $POSTGRES_HOST ]]; then
        host=$POSTGRES_HOST
        port=$POSTGRES_PORT
        ssl=$POSTGRES_SSL
    fi
    cat <<EOF

## Database
database = postgres
pg_host = ${host}
pg_port = ${port}
pg_user = kong
pg_password = ${KONG_PG_PASSWORD}
pg_database = kong
pg_ssl = ${ssl}
pg_ssl_required = ${ssl}
EOF
}

conf_cp() {
    cat <<EOF

## Hybrid: control plane
role = control_plane
cluster_cert = ${KONG_DIR}/cluster.crt
cluster_cert_key = ${KONG_DIR}/cluster.key
cluster_listen = 0.0.0.0:8005
EOF
    conf_postgres
    cat <<EOF

## Listeners
proxy_listen = off
admin_listen = 0.0.0.0:8001 reuseport backlog=16384, 0.0.0.0:8444 http2 ssl reuseport backlog=16384
admin_gui_listen = 0.0.0.0:8002, 0.0.0.0:8445 ssl
status_listen = 0.0.0.0:8100
EOF
}

conf_dp() {
    cat <<EOF

## Hybrid: data plane
role = data_plane
database = off
cluster_cert = ${KONG_DIR}/cluster.crt
cluster_cert_key = ${KONG_DIR}/cluster.key
cluster_control_plane = ${HOST_CP}:8005

## Listeners
proxy_listen = 0.0.0.0:80 reuseport backlog=16384, 0.0.0.0:443 http2 ssl reuseport backlog=16384
admin_listen = off
admin_gui_listen = off
status_listen = 0.0.0.0:8100
EOF
}

conf_st() {
    conf_postgres
    cat <<EOF

## Listeners
proxy_listen = 0.0.0.0:8000 reuseport backlog=16384, 0.0.0.0:8443 http2 ssl reuseport backlog=16384
admin_listen = 0.0.0.0:8001 reuseport backlog=16384, 0.0.0.0:8444 http2 ssl reuseport backlog=16384
admin_gui_listen = 0.0.0.0:8002, 0.0.0.0:8445 ssl
status_listen = 0.0.0.0:8100
EOF
}

write_kong_conf() {
    local tmp backup
    tmp=$(mktemp)
    {
        conf_header
        case $MODE in
            cp) conf_cp ;;
            dp) conf_dp ;;
            st) conf_st ;;
        esac
    } >"$tmp"

    if [[ -f $KONG_CONFIG ]]; then
        backup="$KONG_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$KONG_CONFIG" "$backup"
        chmod 600 "$backup"
        log "Backed up existing config to $backup"
    fi

    install -m 640 "$tmp" "$KONG_CONFIG"
    rm -f "$tmp"
    if getent group kong >/dev/null 2>&1; then
        chown root:kong "$KONG_CONFIG"
    fi
    log "Wrote $KONG_CONFIG"

    log "Validating configuration"
    run kong check "$KONG_CONFIG"
}

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------
install_systemd_unit() {
    local after="network-online.target"
    if [[ $MODE != dp && -z $POSTGRES_HOST ]]; then
        after="$after postgresql.service"
    fi

    cat >/etc/systemd/system/kong.service <<EOF
[Unit]
Description=Kong Gateway OSS (${MODE})
Documentation=https://docs.konghq.com/gateway/
After=${after}
Wants=network-online.target

[Service]
Type=forking
PIDFile=${KONG_PREFIX}/pids/nginx.pid
ExecStartPre=${KONG_BIN} check ${KONG_CONFIG}
ExecStart=${KONG_BIN} start -c ${KONG_CONFIG} -p ${KONG_PREFIX}
ExecReload=${KONG_BIN} reload -c ${KONG_CONFIG} -p ${KONG_PREFIX}
ExecStop=${KONG_BIN} stop -p ${KONG_PREFIX}
Restart=on-failure
RestartSec=5
TimeoutStartSec=120
LimitNOFILE=${NOFILE_LIMIT}

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable kong
    log "Installed systemd unit kong.service (LimitNOFILE=${NOFILE_LIMIT})"
}

probe() { curl -fsS -o /dev/null --max-time 3 "$1"; }

start_kong() {
    # Stop a Kong started outside systemd (e.g. by the old script)
    if ! systemctl is-active --quiet kong \
        && kong health -p "$KONG_PREFIX" >/dev/null 2>&1; then
        log "Stopping Kong instance not managed by systemd"
        run kong stop -p "$KONG_PREFIX"
    fi

    log "Starting Kong"
    run systemctl restart kong

    local up=0
    for _ in $(seq 1 30); do
        if kong health -p "$KONG_PREFIX" >>"$LOG" 2>&1; then up=1; break; fi
        sleep 1
    done
    ((up)) || die "Kong did not start. Check: journalctl -u kong and $KONG_PREFIX/logs/error.log"
    log "Kong is running"

    case $MODE in
        cp|st)
            if probe http://127.0.0.1:8001/status; then
                log "Admin API responding on :8001"
            else
                warn "Admin API not responding on :8001"
            fi ;;
        dp)
            local ready=0
            for _ in $(seq 1 15); do
                if probe http://127.0.0.1:8100/status/ready; then ready=1; break; fi
                sleep 2
            done
            if ((ready)); then
                log "Data plane is ready (config received from ${HOST_CP})"
            else
                warn "Data plane is running but not ready. Check connectivity to ${HOST_CP}:8005 and that cluster certs match the CP"
            fi ;;
    esac
}

print_summary() {
    echo
    echo "==================================================="
    case $MODE in
        cp)
            echo "Kong OSS ${KONG_PACKAGE_VERSION} CONTROL PLANE is running"
            echo "  Admin API     : :8001 (http)  :8444 (https)"
            echo "  Kong Manager  : :8002 (http)  :8445 (https)"
            echo "  Cluster       : :8005"
            echo "  Status        : :8100/status"
            echo
            echo "Next: copy ${KONG_DIR}/cluster.crt and ${KONG_DIR}/cluster.key"
            echo "to each data plane (into its CLUSTER_CERT_DIR) before running -m dp."
            ;;
        dp)
            echo "Kong OSS ${KONG_PACKAGE_VERSION} DATA PLANE is running"
            echo "  Proxy         : :80 (http)  :443 (https)"
            echo "  Status        : :8100/status  :8100/status/ready"
            echo "  Control plane : ${HOST_CP}:8005"
            ;;
        st)
            echo "Kong OSS ${KONG_PACKAGE_VERSION} STANDALONE is running"
            echo "  Proxy         : :8000 (http)  :8443 (https)"
            echo "  Admin API     : :8001 (http)  :8444 (https)"
            echo "  Kong Manager  : :8002 (http)  :8445 (https)"
            echo "  Status        : :8100/status"
            ;;
    esac
    if [[ $MODE != dp ]]; then
        echo
        echo "DB password: ${PG_PASS_FILE} (root only)"
        echo "Note: OSS Admin API / Kong Manager have no authentication."
        if [[ -n $LOCK_AT ]]; then
            echo
            echo "Change freeze: Admin API locks at ${LOCK_AT} (mode: ${LOCK_ADMIN_MODE})"
            echo "  Status  : sudo kong-lock.sh --status"
            echo "  Lock now: sudo kong-lock.sh --now"
            echo "  Unlock  : sudo kong-unlock.sh [DAYS]"
        fi
    fi
    echo
    echo "Service: systemctl status kong | Logs: ${KONG_PREFIX}/logs/ | Install log: ${LOG}"
    echo "==================================================="
}

# ---------------------------------------------------------------------------
# Change freeze: lock the Admin API after LOCK_AFTER_DAYS (cp / st only)
# ---------------------------------------------------------------------------
check_not_locked() {
    if [[ -f $LOCK_FILE ]]; then
        die "Kong is locked since $(sed -n 's/^locked_at=//p' "$LOCK_FILE"). Run 'sudo kong-unlock.sh' before re-running the installer"
    fi
}

lock_script_header() {
    cat <<EOF
#!/usr/bin/env bash
# Generated by kong-install.sh on $(date '+%F %T'). Re-run the installer to regenerate.
set -Eeuo pipefail
KONG_CONFIG=${KONG_CONFIG}
KONG_BIN=${KONG_BIN}
LOCK_FILE=${LOCK_FILE}
LOCK_DATE_FILE=${LOCK_DATE_FILE}
# shellcheck disable=SC2034  # used by kong-lock.sh only
LOCK_ADMIN_MODE=${LOCK_ADMIN_MODE}
LOG=/var/log/kong-lock.log
EOF
}

write_lock_script() {
    {
        lock_script_header
        cat <<'LOCKEOF'

# kong-lock.sh - switch off the Kong Admin API once the lock date is reached.
# Run hourly by kong-lock.timer.
#   kong-lock.sh            lock if the date in LOCK_DATE_FILE has passed
#   kong-lock.sh --now      lock immediately
#   kong-lock.sh --status   show lock state

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

status() {
    if [[ -f $LOCK_FILE ]]; then
        echo "LOCKED"
        cat "$LOCK_FILE"
    elif [[ -f $LOCK_DATE_FILE ]]; then
        echo "UNLOCKED - lock scheduled at: $(sed -n 's/^LOCK_AT=//p' "$LOCK_DATE_FILE")"
    else
        echo "UNLOCKED - no lock scheduled"
    fi
}

force=0
case ${1:-} in
    --status) status; exit 0 ;;
    --now)    force=1 ;;
    "")       ;;
    *)        echo "Usage: $0 [--now|--status]" >&2; exit 1 ;;
esac

[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }

# Already locked: nothing to do
if [[ -f $LOCK_FILE ]]; then exit 0; fi

if (( ! force )); then
    if [[ ! -f $LOCK_DATE_FILE ]]; then exit 0; fi
    lock_at=$(sed -n 's/^LOCK_AT=//p' "$LOCK_DATE_FILE")
    lock_epoch=$(date -d "$lock_at" +%s) || die "Invalid LOCK_AT '$lock_at' in $LOCK_DATE_FILE"
    if (( $(date +%s) < lock_epoch )); then exit 0; fi
fi

log "Locking Kong Admin API (mode: $LOCK_ADMIN_MODE)"
if [[ $LOCK_ADMIN_MODE == local ]]; then
    admin="127.0.0.1:8001 reuseport backlog=16384, 127.0.0.1:8444 http2 ssl reuseport backlog=16384"
else
    admin="off"
fi

backup="$KONG_CONFIG.prelock.$(date +%Y%m%d%H%M%S)"
cp -p "$KONG_CONFIG" "$backup"
chmod 600 "$backup"

tmp=$(mktemp)
grep -vE '^[[:space:]]*(admin_listen|admin_gui_listen)[[:space:]]*=' "$KONG_CONFIG" >"$tmp" || true
cat >>"$tmp" <<EOF

## Change freeze applied by kong-lock.sh on $(date '+%F %T %Z')
admin_listen = ${admin}
admin_gui_listen = off
EOF

if ! "$KONG_BIN" check "$tmp" >>"$LOG" 2>&1; then
    rm -f "$tmp"
    die "kong check failed on the locked config, nothing changed"
fi

install -m 640 "$tmp" "$KONG_CONFIG"
rm -f "$tmp"
if getent group kong >/dev/null 2>&1; then chown root:kong "$KONG_CONFIG"; fi

if ! systemctl reload kong >>"$LOG" 2>&1; then
    log "Reload failed, restoring previous config"
    install -m 640 "$backup" "$KONG_CONFIG"
    systemctl reload kong >>"$LOG" 2>&1 || true
    die "Lock aborted, Kong left on its previous config"
fi

printf 'locked_at=%s\nmode=%s\nprevious_config=%s\n' \
    "$(date '+%F %T %Z')" "$LOCK_ADMIN_MODE" "$backup" >"$LOCK_FILE"
chmod 644 "$LOCK_FILE"

if chattr +i "$KONG_CONFIG" 2>>"$LOG"; then
    log "kong.conf made immutable (chattr +i)"
else
    log "WARN: chattr +i not supported on this filesystem, kong.conf left writable"
fi

sleep 3
if [[ $LOCK_ADMIN_MODE == off ]] \
    && curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:8001/status 2>/dev/null; then
    log "WARN: Admin API still answering after reload, run: systemctl restart kong"
fi

log "Kong Admin API locked"
LOCKEOF
    } >"$SBIN_DIR/kong-lock.sh"
    chmod 750 "$SBIN_DIR/kong-lock.sh"
}

write_unlock_script() {
    {
        lock_script_header
        cat <<'LOCKEOF'

# kong-unlock.sh - restore the pre-lock kong.conf and re-open the Admin API.
#   kong-unlock.sh          unlock, no new lock scheduled
#   kong-unlock.sh DAYS     unlock and schedule a new lock DAYS from today

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

days=${1:-}
if [[ -n $days && ! $days =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 [DAYS]" >&2
    exit 1
fi
[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }

if [[ -f $LOCK_FILE ]]; then
    prev=$(sed -n 's/^previous_config=//p' "$LOCK_FILE")
    [[ -f $prev ]] || die "Pre-lock backup '$prev' not found. Run 'chattr -i $KONG_CONFIG' and edit it manually"
    "$KONG_BIN" check "$prev" >>"$LOG" 2>&1 || die "Pre-lock config '$prev' fails kong check"

    chattr -i "$KONG_CONFIG" 2>/dev/null || true
    locked_copy="$KONG_CONFIG.locked.$(date +%Y%m%d%H%M%S)"
    cp -p "$KONG_CONFIG" "$locked_copy"
    chmod 600 "$locked_copy"

    install -m 640 "$prev" "$KONG_CONFIG"
    if getent group kong >/dev/null 2>&1; then chown root:kong "$KONG_CONFIG"; fi

    systemctl reload kong >>"$LOG" 2>&1 || die "Reload failed, check: journalctl -u kong"
    rm -f "$LOCK_FILE"
    log "Kong Admin API unlocked (pre-lock config restored from $prev)"
else
    log "Kong is not locked"
fi

if [[ -n $days ]]; then
    lock_at=$(date -d "+${days} days" '+%Y-%m-%d 00:00:00')
    echo "LOCK_AT=${lock_at}" >"$LOCK_DATE_FILE"
    chmod 644 "$LOCK_DATE_FILE"
    log "New lock scheduled at ${lock_at}"
else
    rm -f "$LOCK_DATE_FILE"
    log "No lock scheduled. Re-arm with: kong-unlock.sh DAYS"
fi
LOCKEOF
    } >"$SBIN_DIR/kong-unlock.sh"
    chmod 750 "$SBIN_DIR/kong-unlock.sh"
}

install_lock() {
    local timer=/etc/systemd/system/kong-lock.timer

    if [[ $MODE == dp ]]; then
        if (( LOCK_AFTER_DAYS > 0 )); then
            log "Change freeze skipped on data plane (its config comes from the CP)"
        fi
        return 0
    fi

    if (( LOCK_AFTER_DAYS == 0 )); then
        if [[ -f $timer ]]; then
            run systemctl disable --now kong-lock.timer
        fi
        rm -f "$LOCK_DATE_FILE"
        log "Change freeze disabled (LOCK_AFTER_DAYS=0)"
        return 0
    fi

    write_lock_script
    write_unlock_script

    if [[ -f $LOCK_DATE_FILE ]]; then
        LOCK_AT=$(sed -n 's/^LOCK_AT=//p' "$LOCK_DATE_FILE")
        log "Keeping existing lock date ${LOCK_AT} (change it with: kong-unlock.sh DAYS)"
    else
        LOCK_AT=$(date -d "+${LOCK_AFTER_DAYS} days" '+%Y-%m-%d 00:00:00')
        echo "LOCK_AT=${LOCK_AT}" >"$LOCK_DATE_FILE"
        chmod 644 "$LOCK_DATE_FILE"
        log "Change freeze scheduled at ${LOCK_AT}"
    fi

    cat >/etc/systemd/system/kong-lock.service <<EOF
[Unit]
Description=Kong change freeze (locks Admin API once the lock date is reached)
After=kong.service

[Service]
Type=oneshot
ExecStart=${SBIN_DIR}/kong-lock.sh
EOF

    # Hourly check against the stored date, so a server that was down on the
    # lock date still locks shortly after it boots.
    cat >"$timer" <<EOF
[Unit]
Description=Hourly check for the Kong change freeze

[Timer]
OnBootSec=2min
OnCalendar=hourly
Persistent=true
Unit=kong-lock.service

[Install]
WantedBy=timers.target
EOF
    run systemctl daemon-reload
    run systemctl enable --now kong-lock.timer
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    require_root
    init_log
    load_config
    choose_mode
    validate
    check_not_locked

    log "Installing ${KONG_PACKAGE_NAME} ${KONG_PACKAGE_VERSION} in '${MODE}' mode"
    check_os
    set_timezone
    install_prereqs
    add_kong_repo
    check_version_available
    install_kong

    case $MODE in
        cp)
            setup_database
            setup_cluster_cert_cp
            write_kong_conf
            run_migrations ;;
        dp)
            setup_cluster_cert_dp
            write_kong_conf ;;
        st)
            setup_database
            write_kong_conf
            run_migrations ;;
    esac

    install_systemd_unit
    start_kong
    install_lock
    print_summary
}

main "$@"
