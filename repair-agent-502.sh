#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/root/repair-agent-502-${STAMP}.log"
exec > >(tee -a "$LOG") 2>&1

API_UNIT="prhm-agent-api.service"
MCP_UNIT="prhm-agent-mcp.service"
API_URL="http://127.0.0.1:8099/health"
MCP_URL="http://127.0.0.1:8123/health"
AGENT_HOST="agent.prhm.ir"
SELFHEAL="/usr/local/sbin/prhm-agent-selfheal"

say() { printf '\n===== %s =====\n' "$*"; }
health() { curl -fsS --connect-timeout 2 --max-time 6 "$1" >/dev/null 2>&1; }
wait_health() {
  local url="$1" attempts="${2:-40}"
  local i
  for i in $(seq 1 "$attempts"); do
    if health "$url"; then return 0; fi
    sleep 1
  done
  return 1
}
proxy_unit() {
  if systemctl cat httpd.service >/dev/null 2>&1; then echo httpd.service; return; fi
  if systemctl cat apache2.service >/dev/null 2>&1; then echo apache2.service; return; fi
  if systemctl cat nginx.service >/dev/null 2>&1; then echo nginx.service; return; fi
  echo ""
}

say "BASIC DIAGNOSTICS"
hostname || true
date -Is || true
uptime || true
free -h || true
df -hT / /home /tmp 2>/dev/null || true
df -ih / /home /tmp 2>/dev/null || true
systemctl --failed --no-pager || true
ps -eo state,pid,ppid,pcpu,pmem,etime,comm,args --sort=-pcpu | head -35 || true

say "NETWORK PRESSURE"
if [[ -r /proc/sys/net/netfilter/nf_conntrack_count && -r /proc/sys/net/netfilter/nf_conntrack_max ]]; then
  CT_COUNT="$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
  CT_MAX="$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
  echo "nf_conntrack_count=$CT_COUNT nf_conntrack_max=$CT_MAX"
  if (( CT_COUNT * 100 / CT_MAX >= 80 )); then
    NEW_MAX=$(( CT_MAX * 2 ))
    (( NEW_MAX < 262144 )) && NEW_MAX=262144
    (( NEW_MAX > 1048576 )) && NEW_MAX=1048576
    sysctl -w "net.netfilter.nf_conntrack_max=$NEW_MAX"
    cat >/etc/sysctl.d/99-prhm-agent-network.conf <<EOF
net.netfilter.nf_conntrack_max=$NEW_MAX
net.core.somaxconn=4096
fs.file-max=1048576
EOF
    sysctl --system >/dev/null 2>&1 || true
  fi
fi
ss -s || true

say "SYSTEMD HARDENING"
mkdir -p "/etc/systemd/system/${API_UNIT}.d" "/etc/systemd/system/${MCP_UNIT}.d"
cat >"/etc/systemd/system/${API_UNIT}.d/zz-selfheal.conf" <<'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=2
TimeoutStartSec=75
TimeoutStopSec=35
Nice=-5
OOMScoreAdjust=-500
LimitNOFILE=65535
Environment=NODE_COMPILE_CACHE=/home/agent/.cache/node-compile-api
Environment=AGENT_HISTORY_MAX_BYTES=5242880
Environment=AGENT_HISTORY_TAIL_BYTES=1048576
Environment=AGENT_JOB_LOG_TAIL_BYTES=2097152
Environment=AGENT_STDOUT_MAX_BYTES=2097152
Environment=AGENT_STDERR_MAX_BYTES=524288
Environment=AGENT_MAX_CONCURRENT_SSH_REQUESTS=3
EOF

cat >"/etc/systemd/system/${MCP_UNIT}.d/zz-selfheal.conf" <<'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=2
TimeoutStartSec=75
TimeoutStopSec=35
Nice=-5
OOMScoreAdjust=-500
LimitNOFILE=65535
Environment=NODE_COMPILE_CACHE=/home/agent/.cache/node-compile-mcp
Environment=MCP_REQUEST_TIMEOUT_MS=55000
Environment=MCP_MAX_CONCURRENT_REQUESTS=8
Environment=AGENT_HTTP_TIMEOUT_MS=15000
Environment=AGENT_SYNC_COMMAND_TIMEOUT_MS=45000
EOF

mkdir -p /home/agent/.cache/node-compile-api /home/agent/.cache/node-compile-mcp
chown -R agent:agent /home/agent/.cache 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed "$API_UNIT" "$MCP_UNIT" || true
systemctl enable "$API_UNIT" "$MCP_UNIT" >/dev/null 2>&1 || true

say "INSTALL INDEPENDENT SELF-HEAL"
cat >"$SELFHEAL" <<'EOF'
#!/usr/bin/env bash
set +e
exec 9>/run/prhm-agent-selfheal.lock
flock -n 9 || exit 0

API_UNIT=prhm-agent-api.service
MCP_UNIT=prhm-agent-mcp.service
API_URL=http://127.0.0.1:8099/health
MCP_URL=http://127.0.0.1:8123/health
STATE=/run/prhm-agent-selfheal.failures
LOG=/var/log/prhm-agent-selfheal.log

log() {
  logger -t prhm-agent-selfheal -- "$*"
  printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"
}
health() { curl -fsS --connect-timeout 2 --max-time 6 "$1" >/dev/null 2>&1; }
wait_health() {
  local url="$1"
  for _ in $(seq 1 35); do health "$url" && return 0; sleep 1; done
  return 1
}
proxy_unit() {
  systemctl cat httpd.service >/dev/null 2>&1 && { echo httpd.service; return; }
  systemctl cat apache2.service >/dev/null 2>&1 && { echo apache2.service; return; }
  systemctl cat nginx.service >/dev/null 2>&1 && { echo nginx.service; return; }
  echo ''
}

failed=0
if ! health "$API_URL"; then
  failed=1
  log "API unhealthy; restarting $API_UNIT"
  systemctl reset-failed "$API_UNIT"
  systemctl restart "$API_UNIT"
  wait_health "$API_URL" || log "API did not recover"
fi

if ! health "$MCP_URL"; then
  failed=1
  log "MCP unhealthy; restarting $MCP_UNIT"
  systemctl reset-failed "$MCP_UNIT"
  systemctl restart "$MCP_UNIT"
  wait_health "$MCP_URL" || log "MCP did not recover"
fi

proxy="$(proxy_unit)"
if [[ -n "$proxy" ]] && health "$MCP_URL"; then
  if ! curl -kfsS --resolve agent.prhm.ir:443:127.0.0.1 --connect-timeout 2 --max-time 8 https://agent.prhm.ir/health >/dev/null 2>&1; then
    failed=1
    log "Local HTTPS proxy unhealthy; restarting $proxy"
    systemctl reset-failed "$proxy"
    systemctl restart "$proxy"
  fi
fi

count=0
[[ -r "$STATE" ]] && read -r count <"$STATE"
if (( failed )); then
  count=$((count + 1))
else
  count=0
fi
printf '%s\n' "$count" >"$STATE"

if (( count >= 4 )); then
  log "Repeated failures=$count; ordered full Agent stack restart"
  systemctl restart "$API_UNIT"
  wait_health "$API_URL"
  systemctl restart "$MCP_UNIT"
  wait_health "$MCP_URL"
  [[ -n "$proxy" ]] && systemctl restart "$proxy"
  printf '0\n' >"$STATE"
fi

if [[ -f "$LOG" ]] && (( $(stat -c %s "$LOG" 2>/dev/null || echo 0) > 20971520 )); then
  tail -n 2000 "$LOG" >"${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
EOF
chmod 0755 "$SELFHEAL"

cat >/etc/systemd/system/prhm-agent-selfheal.service <<EOF
[Unit]
Description=PRHM Agent independent HTTP self-heal
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SELFHEAL
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
EOF

cat >/etc/systemd/system/prhm-agent-selfheal.timer <<'EOF'
[Unit]
Description=Check PRHM Agent every 30 seconds

[Timer]
OnBootSec=40s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now prhm-agent-selfheal.timer

say "CONTROLLED RECOVERY"
PROXY_UNIT="$(proxy_unit)"
systemctl restart "$API_UNIT"
if ! wait_health "$API_URL" 60; then
  echo "ERROR: API failed to recover"
  journalctl -u "$API_UNIT" -n 150 --no-pager || true
  exit 21
fi
curl -fsS "$API_URL" || true

systemctl restart "$MCP_UNIT"
if ! wait_health "$MCP_URL" 90; then
  echo "ERROR: MCP failed to recover"
  journalctl -u "$MCP_UNIT" -n 200 --no-pager || true
  exit 22
fi
curl -fsS "$MCP_URL" || true

if [[ -n "$PROXY_UNIT" ]]; then
  systemctl restart "$PROXY_UNIT"
  sleep 3
fi

say "VERIFICATION"
systemctl --no-pager --full status "$API_UNIT" "$MCP_UNIT" prhm-agent-selfheal.timer "$PROXY_UNIT" 2>/dev/null || true
printf '\nAPI: '; curl -fsS --max-time 8 "$API_URL" || true
printf '\nMCP: '; curl -fsS --max-time 8 "$MCP_URL" || true
printf '\nLOCAL HTTPS: '; curl -kfsS --resolve "${AGENT_HOST}:443:127.0.0.1" --max-time 12 "https://${AGENT_HOST}/health" || true
printf '\nPUBLIC HTTPS: '; curl -kfsS --max-time 15 "https://${AGENT_HOST}/health" || true
printf '\n\nTimers:\n'; systemctl list-timers --all --no-pager | grep -E 'prhm-(agent-selfheal|core-watchdog)' || true

say "RESULT"
if health "$API_URL" && health "$MCP_URL"; then
  echo "AGENT_LOCAL_RECOVERY_SUCCESS"
  echo "log=$LOG"
  exit 0
fi

echo "AGENT_RECOVERY_INCOMPLETE"
echo "log=$LOG"
exit 30
