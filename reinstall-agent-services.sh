#!/usr/bin/env bash
set -Eeuo pipefail

API_DIR=/home/agent/ssh-agent-api
MCP_DIR=/home/agent/ssh-mcp-server
API_UNIT=/etc/systemd/system/prhm-agent-api.service
MCP_UNIT=/etc/systemd/system/prhm-agent-mcp.service
SELFHEAL=/usr/local/sbin/prhm-agent-selfheal
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/root/reinstall-agent-services-${STAMP}.log"

exec > >(tee -a "$LOG") 2>&1

log() { printf '\n===== %s =====\n' "$*"; }
die() { echo "ERROR: $*"; echo "LOG=$LOG"; exit 1; }

[[ "$(id -u)" == 0 ]] || die "Run as root"

log "VERIFY TARGET VM"
hostname
ip -br addr
ip -br addr | grep -q '10\.71\.0\.117/24' || die "This script must run inside the VM with IP 10.71.0.117"

log "REMOVE FAILED SELF-HEAL INSTALLATION"
systemctl disable --now prhm-agent-selfheal.timer 2>/dev/null || true
rm -f /etc/systemd/system/prhm-agent-selfheal.timer \
      /etc/systemd/system/prhm-agent-selfheal.service \
      "$SELFHEAL"
rm -rf /etc/systemd/system/prhm-agent-api.service.d \
       /etc/systemd/system/prhm-agent-mcp.service.d
systemctl daemon-reload
systemctl reset-failed || true

latest_dir() {
  local suffix="$1"
  find /root /home /opt /var/backups \
    -path '*/node_modules' -prune -o \
    -type f -path "*/${suffix}/server.js" -printf '%T@ %h\n' 2>/dev/null \
    | sort -nr | awk 'NR==1{sub(/^[^ ]+ /,""); print; exit}'
}

find_env() {
  local suffix="$1"
  find /root /home /opt /var/backups \
    -path '*/node_modules' -prune -o \
    -type f -path "*/${suffix}/.env" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | awk 'NR==1{sub(/^[^ ]+ /,""); print; exit}'
}

log "DISCOVER EXISTING SOURCE AND BACKUPS"
API_SOURCE=""
MCP_SOURCE=""

if [[ -f "$API_DIR/server.js" && -f "$API_DIR/package.json" ]]; then
  API_SOURCE="$API_DIR"
else
  API_SOURCE="$(latest_dir ssh-agent-api || true)"
fi

if [[ -f "$MCP_DIR/server.js" && -f "$MCP_DIR/package.json" ]]; then
  MCP_SOURCE="$MCP_DIR"
else
  MCP_SOURCE="$(latest_dir ssh-mcp-server || true)"
fi

echo "API_SOURCE=${API_SOURCE:-missing}"
echo "MCP_SOURCE=${MCP_SOURCE:-missing}"

if [[ -z "$API_SOURCE" || -z "$MCP_SOURCE" ]]; then
  log "TRY EXISTING GITHUB CREDENTIALS"
  RECOVERY_REPO=/root/sshagent-recovery
  rm -rf "$RECOVERY_REPO"
  if timeout 90 env GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10' \
      git clone --depth 1 git@github.com:prhmonline/sshagent.git "$RECOVERY_REPO"; then
    [[ -z "$API_SOURCE" && -f "$RECOVERY_REPO/api/server.js" ]] && API_SOURCE="$RECOVERY_REPO/api"
    [[ -z "$MCP_SOURCE" && -f "$RECOVERY_REPO/mcp-server/server.js" ]] && MCP_SOURCE="$RECOVERY_REPO/mcp-server"
  else
    echo "Private Git clone was unavailable; continuing with local backups only."
  fi
fi

[[ -n "$API_SOURCE" && -f "$API_SOURCE/server.js" && -f "$API_SOURCE/package.json" ]] \
  || die "API source not found. Expected an existing or backed-up ssh-agent-api directory."
[[ -n "$MCP_SOURCE" && -f "$MCP_SOURCE/server.js" && -f "$MCP_SOURCE/package.json" ]] \
  || die "MCP source not found. Expected an existing or backed-up ssh-mcp-server directory."

log "RESTORE PRODUCTION DIRECTORIES"
mkdir -p /home/agent

if [[ "$API_SOURCE" != "$API_DIR" ]]; then
  mkdir -p "$API_DIR"
  rsync -a --delete --exclude node_modules/ --exclude .git/ "$API_SOURCE/" "$API_DIR/"
fi
if [[ "$MCP_SOURCE" != "$MCP_DIR" ]]; then
  mkdir -p "$MCP_DIR"
  rsync -a --delete --exclude node_modules/ --exclude .git/ "$MCP_SOURCE/" "$MCP_DIR/"
fi

if [[ ! -s "$API_DIR/.env" ]]; then
  API_ENV="$(find_env ssh-agent-api || true)"
  [[ -n "$API_ENV" ]] && install -m 600 "$API_ENV" "$API_DIR/.env"
fi
if [[ ! -s "$MCP_DIR/.env" ]]; then
  MCP_ENV="$(find_env ssh-mcp-server || true)"
  [[ -n "$MCP_ENV" ]] && install -m 600 "$MCP_ENV" "$MCP_DIR/.env"
fi

[[ -s "$API_DIR/.env" ]] || die "API .env was not found; refusing to start with missing credentials."
[[ -s "$MCP_DIR/.env" ]] || die "MCP .env was not found; refusing to start with missing credentials."

chmod 700 "$API_DIR/.env" "$MCP_DIR/.env"

log "VERIFY NODE RUNTIME"
NODE_BIN="$(command -v node || true)"
NPM_BIN="$(command -v npm || true)"
[[ -n "$NODE_BIN" ]] || die "node is not installed"
[[ -n "$NPM_BIN" ]] || die "npm is not installed"
"$NODE_BIN" --version
"$NPM_BIN" --version

if [[ ! -x /usr/local/bin/prhm-node ]]; then
  cat >/usr/local/bin/prhm-node <<EOF
#!/usr/bin/env bash
exec "$NODE_BIN" "\$@"
EOF
  chmod 755 /usr/local/bin/prhm-node
fi

install_deps() {
  local dir="$1" test_module="$2"
  cd "$dir"
  if ! "$NODE_BIN" -e "require.resolve('$test_module')" >/dev/null 2>&1; then
    if [[ -f package-lock.json ]]; then
      "$NPM_BIN" ci --omit=dev
    else
      "$NPM_BIN" install --omit=dev
    fi
  else
    echo "Dependencies already available in $dir"
  fi
}

log "INSTALL OR VERIFY DEPENDENCIES"
install_deps "$API_DIR" express
install_deps "$MCP_DIR" express

log "INSTALL SYSTEMD UNITS"
cat >"$API_UNIT" <<'UNIT'
[Unit]
Description=PRHM SSH Agent API
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=20

[Service]
Type=simple
WorkingDirectory=/home/agent/ssh-agent-api
Environment=NODE_ENV=production
Environment=PORT=8099
ExecStart=/usr/local/bin/prhm-node /home/agent/ssh-agent-api/server.js
Restart=always
RestartSec=2
TimeoutStartSec=30
TimeoutStopSec=30
KillSignal=SIGTERM
Nice=-5
OOMScoreAdjust=-500
MemoryHigh=640M
MemoryMax=768M
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=prhm-agent-api

[Install]
WantedBy=multi-user.target
UNIT

cat >"$MCP_UNIT" <<'UNIT'
[Unit]
Description=PRHM SSH Agent MCP
Wants=network-online.target prhm-agent-api.service
After=network-online.target prhm-agent-api.service
StartLimitIntervalSec=300
StartLimitBurst=20

[Service]
Type=simple
WorkingDirectory=/home/agent/ssh-mcp-server
Environment=NODE_ENV=production
Environment=PORT=8123
ExecStart=/usr/local/bin/prhm-node /home/agent/ssh-mcp-server/server.js
Restart=always
RestartSec=2
TimeoutStartSec=30
TimeoutStopSec=45
KillSignal=SIGTERM
Nice=-5
OOMScoreAdjust=-450
MemoryHigh=640M
MemoryMax=768M
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=prhm-agent-mcp

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable prhm-agent-api.service prhm-agent-mcp.service

wait_health() {
  local url="$1" attempts="${2:-60}"
  local i body
  for i in $(seq 1 "$attempts"); do
    body="$(curl -fsS --connect-timeout 2 --max-time 6 "$url" 2>/dev/null || true)"
    if [[ -n "$body" ]]; then
      echo "$body"
      return 0
    fi
    sleep 1
  done
  return 1
}

log "START API"
systemctl restart prhm-agent-api.service
if ! wait_health http://127.0.0.1:8099/health 90; then
  systemctl --no-pager --full status prhm-agent-api.service || true
  journalctl -u prhm-agent-api.service -n 160 --no-pager || true
  die "API did not become healthy"
fi

log "START MCP"
systemctl restart prhm-agent-mcp.service
if ! wait_health http://127.0.0.1:8123/health 90; then
  systemctl --no-pager --full status prhm-agent-mcp.service || true
  journalctl -u prhm-agent-mcp.service -n 160 --no-pager || true
  die "MCP did not become healthy"
fi

log "INSTALL LOCAL SELF-HEAL"
cat >"$SELFHEAL" <<'SH'
#!/usr/bin/env bash
set -u
check() { curl -fsS --connect-timeout 2 --max-time 6 "$1" >/dev/null 2>&1; }
check http://127.0.0.1:8099/health || systemctl restart prhm-agent-api.service
sleep 2
check http://127.0.0.1:8123/health || systemctl restart prhm-agent-mcp.service
if ! curl -kfsS --resolve agent.prhm.ir:443:127.0.0.1 --connect-timeout 3 --max-time 8 https://agent.prhm.ir/health >/dev/null 2>&1; then
  systemctl restart nginx.service 2>/dev/null || systemctl restart httpd.service 2>/dev/null || true
fi
SH
chmod 755 "$SELFHEAL"

cat >/etc/systemd/system/prhm-agent-selfheal.service <<'UNIT'
[Unit]
Description=PRHM Agent local health recovery
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/prhm-agent-selfheal
UNIT

cat >/etc/systemd/system/prhm-agent-selfheal.timer <<'UNIT'
[Unit]
Description=Check PRHM Agent every 30 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=prhm-agent-selfheal.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now prhm-agent-selfheal.timer

log "FINAL VERIFICATION"
systemctl --no-pager --full status prhm-agent-api.service prhm-agent-mcp.service prhm-agent-selfheal.timer || true
ss -lntp | grep -E ':8099|:8123' || true
curl -fsS http://127.0.0.1:8099/health
echo
curl -fsS http://127.0.0.1:8123/health
echo
curl -skS --resolve agent.prhm.ir:443:127.0.0.1 --connect-timeout 5 --max-time 20 -D - https://agent.prhm.ir/health

echo
log "SUCCESS"
echo "AGENT_SERVICES_REINSTALLED"
echo "LOG=$LOG"
