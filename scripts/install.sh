#!/usr/bin/env bash
# install.sh — App server installer
# Installs: Node Exporter, OTel Collector, nginx, and the FastAPI app

set -euo pipefail

APP_USER="appuser"
APP_DIR="/opt/demo-app/app"
OTEL_DIR="/opt/demo-app/otel"
LOG_FILE="/var/log/app-install.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "Starting app server installation"

# ── Kill anything holding apt locks ──────────────────────────────────────────
log "Preparing apt..."
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
killall apt apt-get unattended-upgrade 2>/dev/null || true
sleep 3
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/cache/apt/archives/lock /var/lib/apt/lists/lock
dpkg --configure -a 2>/dev/null || true

log "Installing dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget unzip tar git python3 python3-pip python3-venv \
    jq net-tools netcat-openbsd nginx

# ── Create users ──────────────────────────────────────────────────────────────
id "$APP_USER" &>/dev/null || useradd --create-home --shell /bin/bash "$APP_USER"
log "User ready: $APP_USER"

id node_exporter &>/dev/null || useradd --no-create-home --shell /bin/false node_exporter
log "User ready: node_exporter"

id otel &>/dev/null || useradd --no-create-home --shell /bin/false otel
log "User ready: otel"

# ── Helper: download with retry ───────────────────────────────────────────────
download() {
    local url=$1 dest=$2
    for attempt in 1 2 3; do
        wget -q --timeout=60 --tries=3 -O "$dest" "$url" && return 0
        log "Download attempt $attempt failed for $url, retrying..."
        sleep 5
    done
    log "ERROR: Failed to download $url after 3 attempts"
    exit 1
}

install_binary() {
    local name="$1"
    if [ -x "/usr/local/bin/${name}" ]; then
        log "$name already installed, skipping download"
        return 0
    fi
    return 1
}

wait_for_port() {
    local svc=$1 port=$2
    local retries=15
    log "Waiting for $svc to bind port $port..."
    while ! nc -z localhost "$port" 2>/dev/null; do
        retries=$(( retries - 1 ))
        if (( retries <= 0 )); then
            log "WARNING: $svc did not bind port $port in time"
            return 1
        fi
        sleep 1
    done
    log "  ✓ $svc is listening on :$port"
}

# ── Node Exporter ─────────────────────────────────────────────────────────────
NODE_VERSION="1.7.0"
if ! install_binary node_exporter; then
    log "Installing Node Exporter ${NODE_VERSION}..."
    (
        cd /tmp
        download "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/node_exporter-${NODE_VERSION}.linux-amd64.tar.gz" \
            "node_exporter.tar.gz"
        tar -xzf node_exporter.tar.gz
        cp "node_exporter-${NODE_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
        chmod 755 /usr/local/bin/node_exporter
        chown node_exporter:node_exporter /usr/local/bin/node_exporter
    )
fi

cat > /etc/systemd/system/node_exporter.service << 'UNIT'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:9100

[Install]
WantedBy=multi-user.target
UNIT
log "Node Exporter configured"

# ── OTel Collector ────────────────────────────────────────────────────────────
OTEL_VERSION="0.154.0"
if ! install_binary otelcol; then
    log "Installing OTel Collector ${OTEL_VERSION}..."
    (
        cd /tmp
        download "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_amd64.tar.gz" \
            "otelcol.tar.gz"
        tar -xzf otelcol.tar.gz
        cp otelcol-contrib /usr/local/bin/otelcol
        chmod +x /usr/local/bin/otelcol
        chown otel:otel /usr/local/bin/otelcol
    )
fi

mkdir -p "$OTEL_DIR"
cp "${OTEL_DIR}/otel-collector-config.yml" /etc/otel/otel-collector-config.yml 2>/dev/null || {
    log "WARNING: otel-collector-config.yml not found in ${OTEL_DIR} — skipping copy"
}
mkdir -p /etc/otel
chown -R otel:otel /etc/otel

cat > /etc/systemd/system/otelcol.service << 'UNIT'
[Unit]
Description=OpenTelemetry Collector
Wants=network-online.target
After=network-online.target

[Service]
User=otel
Group=otel
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/otelcol --config=/etc/otel/otel-collector-config.yml

[Install]
WantedBy=multi-user.target
UNIT
log "OTel Collector configured"

# ── App ───────────────────────────────────────────────────────────────────────
if [ ! -d "$APP_DIR" ]; then
    log "WARNING: ${APP_DIR} not found — app may not be deployed yet"
else
    REQ_HASH_FILE="${APP_DIR}/.req_hash"
    NEW_HASH=$(md5sum "${APP_DIR}/requirements.txt" | cut -d' ' -f1)
    OLD_HASH=$(cat "$REQ_HASH_FILE" 2>/dev/null || echo "")

    if [ "$OLD_HASH" != "$NEW_HASH" ] || [ ! -d "${APP_DIR}/venv" ]; then
        log "requirements.txt changed or venv missing — rebuilding venv..."
        rm -rf "${APP_DIR}/venv"
        python3 -m venv --system-site-packages "${APP_DIR}/venv"
        "${APP_DIR}/venv/bin/python" -m pip install --quiet --upgrade pip
        "${APP_DIR}/venv/bin/python" -m pip install --quiet -r "${APP_DIR}/requirements.txt"
        echo "$NEW_HASH" > "$REQ_HASH_FILE"
    else
        log "requirements.txt unchanged — reusing existing venv"
    fi

    chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
fi

cat > /etc/systemd/system/app.service << UNIT
[Unit]
Description=FastAPI App
Wants=network-online.target otelcol.service
After=network-online.target otelcol.service

[Service]
User=${APP_USER}
Group=${APP_USER}
Type=simple
Restart=always
RestartSec=5s
WorkingDirectory=${APP_DIR}
Environment=OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
ExecStart=${APP_DIR}/venv/bin/python -m uvicorn main:app --host 0.0.0.0 --port 8080

[Install]
WantedBy=multi-user.target
UNIT
log "App service configured"

# ── Nginx ─────────────────────────────────────────────────────────────────────

cat > /etc/nginx/sites-available/app << 'CONFIG'
server {
    listen 80;

    # App
    location / {
        proxy_pass         http://localhost:8080;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # OTel HTTP receiver — restricted to observability server
    # TODO: replace with your observability server IP
    location /otlp {
        allow  100.54.109.191;
        deny   all;
        proxy_pass http://localhost:4318;
    }

    # OTel Collector metrics — restricted to observability server
    # TODO: replace with your observability server IP
    location /metrics {
        allow  100.54.109.191;
        deny   all;
        proxy_pass http://localhost:4317;
    }
}
CONFIG

ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app
rm -f /etc/nginx/sites-enabled/default
nginx -t
log "Nginx configured"

# ── Enable and start all services ─────────────────────────────────────────────
log "Starting all services..."
systemctl daemon-reload

SERVICES=(
    node_exporter
    otelcol
    nginx
    app
)

declare -A SVC_PORT=(
    [node_exporter]=9100
    [otelcol]=4317
    [nginx]=80
    [app]=8080
)

for svc in "${SERVICES[@]}"; do
    systemctl enable "$svc"
    systemctl restart "$svc"
    port="${SVC_PORT[$svc]:-}"
    if [ -n "$port" ]; then
        wait_for_port "$svc" "$port" || true
    fi
    if systemctl is-active --quiet "$svc"; then
        log "✓ $svc running"
    else
        log "✗ $svc FAILED"
        journalctl -u "$svc" -n 20 --no-pager | tee -a "$LOG_FILE"
    fi
done

log "======================================"
log "Installation complete"
log "App:          http://localhost:8080"
log "Node Exporter: http://localhost:9100"
log "OTel Collector: http://localhost:4317"
log "======================================"

