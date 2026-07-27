#!/usr/bin/env bash
set -Eeuo pipefail

VM="${VM:-server1-production}"
IP="${IP:-10.71.0.117}"
PY="${PY:-/usr/libexec/platform-python}"
KEY="${KEY:-/root/server1-production-agent-rescue}"
KNOWN="${KNOWN:-/root/server1-production-agent-rescue.known_hosts}"
MARKER="${MARKER:-node1-agent-rescue-20260727}"
REPAIR_URL="https://raw.githubusercontent.com/prhmonline/mohammad-manager-agent-relay/main/repair-agent-502.sh"
REPAIR_SHA256="474eb3bbaa91e6128062358f311525682d2e3f09b2e2c5a8d221a889e59d5f0a"

ADDED_BY_QGA=0
REMOVE_ENABLED=0
FOUND_EXISTING_KEY=""
PUBKEY=""

log() { printf '\n===== %s =====\n' "$*"; }

qga_command_enabled() {
  local name="$1"
  "$PY" - "$INFO" "$name" <<'PYCODE'
import json
import sys
info = json.loads(sys.argv[1])
name = sys.argv[2]
for item in info.get("return", {}).get("supported_commands", []):
    if item.get("name") == name:
        print("yes" if item.get("enabled", False) else "no")
        raise SystemExit(0)
print("no")
PYCODE
}

qga_add_key() {
  local req
  req="$("$PY" - "$PUBKEY" <<'PYCODE'
import json
import sys
print(json.dumps({
    "execute": "guest-ssh-add-authorized-keys",
    "arguments": {
        "username": "root",
        "keys": [sys.argv[1]],
        "reset": False
    }
}))
PYCODE
)"
  virsh qemu-agent-command "$VM" "$req"
}

qga_remove_key() {
  local req
  req="$("$PY" - "$PUBKEY" <<'PYCODE'
import json
import sys
print(json.dumps({
    "execute": "guest-ssh-remove-authorized-keys",
    "arguments": {
        "username": "root",
        "keys": [sys.argv[1]]
    }
}))
PYCODE
)"
  virsh qemu-agent-command "$VM" "$req"
}

ssh_opts() {
  SSH_OPTS=(
    -i "$ACTIVE_KEY"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o PreferredAuthentications=publickey
    -o PasswordAuthentication=no
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile="$KNOWN"
    -o ConnectTimeout=10
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2
  )
}

cleanup() {
  set +e
  if [[ "$ADDED_BY_QGA" == "1" && -n "$PUBKEY" ]]; then
    log "REMOVE TEMPORARY RESCUE KEY"
    if [[ "$REMOVE_ENABLED" == "1" ]]; then
      qga_remove_key >/dev/null 2>&1 && echo "Temporary key removed through QGA." || true
    elif [[ -n "${ACTIVE_KEY:-}" && -f "${ACTIVE_KEY:-}" ]]; then
      ssh "${SSH_OPTS[@]}" root@"$IP" "sed -i '\|${MARKER}|d' /root/.ssh/authorized_keys" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$KEY" "$KEY.pub" "$KNOWN"
}
trap cleanup EXIT

log "PRECHECK"
[[ -x "$PY" ]] || { echo "Missing $PY"; exit 10; }
virsh domstate "$VM"
virsh qemu-agent-command "$VM" '{"execute":"guest-ping"}'

INFO="$(virsh qemu-agent-command "$VM" '{"execute":"guest-info"}')"
ADD_ENABLED="$(qga_command_enabled guest-ssh-add-authorized-keys)"
REMOVE_ENABLED_RAW="$(qga_command_enabled guest-ssh-remove-authorized-keys)"
SET_PASSWORD_ENABLED="$(qga_command_enabled guest-set-user-password)"

[[ "$REMOVE_ENABLED_RAW" == "yes" ]] && REMOVE_ENABLED=1

echo "guest-ssh-add-authorized-keys=$ADD_ENABLED"
echo "guest-ssh-remove-authorized-keys=$REMOVE_ENABLED_RAW"
echo "guest-set-user-password=$SET_PASSWORD_ENABLED"

rm -f "$KNOWN"

if [[ "$ADD_ENABLED" == "yes" ]]; then
  log "CREATE AND ADD TEMPORARY SSH KEY"
  rm -f "$KEY" "$KEY.pub"
  ssh-keygen -q -t ed25519 -N '' -C "$MARKER" -f "$KEY"
  chmod 600 "$KEY"
  PUBKEY="$(cat "$KEY.pub")"
  qga_add_key
  ADDED_BY_QGA=1
  ACTIVE_KEY="$KEY"
else
  log "QGA SSH ADD DISABLED - SEARCH EXISTING HOST KEYS"
  while IFS= read -r candidate; do
    case "$candidate" in
      *.pub|*/authorized_keys|*/known_hosts|*/config) continue ;;
    esac
    if timeout 3 ssh-keygen -y -f "$candidate" </dev/null >/dev/null 2>&1; then
      echo "Trying $candidate"
      if timeout 12 ssh \
        -i "$candidate" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$KNOWN" \
        -o ConnectTimeout=6 \
        root@"$IP" 'echo EXISTING_KEY_OK' 2>/dev/null | grep -q EXISTING_KEY_OK; then
        FOUND_EXISTING_KEY="$candidate"
        break
      fi
    fi
  done < <(find /root/.ssh /root -maxdepth 3 -type f -size -64k 2>/dev/null | sort -u)

  if [[ -z "$FOUND_EXISTING_KEY" ]]; then
    echo
    echo "No usable existing SSH private key was found on node1."
    echo "QGA cannot add keys on this guest."
    if [[ "$SET_PASSWORD_ENABLED" == "yes" ]]; then
      echo "Fallback available: set a temporary root password through QGA and use virsh console."
      exit 21
    fi
    echo "Fallback required: VM console or offline disk maintenance."
    exit 22
  fi

  echo "Using existing key: $FOUND_EXISTING_KEY"
  ACTIVE_KEY="$FOUND_EXISTING_KEY"
fi

ssh_opts

log "VERIFY SSH ACCESS TO VM"
ssh "${SSH_OPTS[@]}" root@"$IP" '
set -e
printf "HOSTNAME=%s\n" "$(hostname)"
printf "DATE=%s\n" "$(date -Is)"
id
ip -br addr
systemctl list-unit-files | grep -E "prhm-agent-(api|mcp)" || true
ss -lntp | grep -E ":8099|:8123" || true
'

log "RUN AGENT RECOVERY INSIDE VM"
ssh "${SSH_OPTS[@]}" root@"$IP" 'bash -s' <<REMOTE
set -Eeuo pipefail
curl -fsSL '$REPAIR_URL' -o /root/repair-agent-502.sh
echo '$REPAIR_SHA256  /root/repair-agent-502.sh' | sha256sum -c -
bash /root/repair-agent-502.sh
REMOTE

log "VERIFY INSIDE VM"
ssh "${SSH_OPTS[@]}" root@"$IP" '
echo "--- services ---"
systemctl --no-pager --full status prhm-agent-api.service prhm-agent-mcp.service prhm-agent-selfheal.timer || true
echo "--- ports ---"
ss -lntp | grep -E ":8099|:8123" || true
echo "--- API ---"
curl -i --max-time 10 http://127.0.0.1:8099/health || true
echo "--- MCP ---"
curl -i --max-time 10 http://127.0.0.1:8123/health || true
echo "--- recent logs ---"
journalctl -u prhm-agent-api.service -u prhm-agent-mcp.service --since "-15 minutes" --no-pager -n 150
'

log "VERIFY NGINX FROM NODE1"
curl -skS \
  --resolve agent.prhm.ir:443:"$IP" \
  --connect-timeout 5 \
  --max-time 20 \
  -D - \
  https://agent.prhm.ir/health

echo
log "RECOVERY COMPLETE"
echo "AGENT_QGA_SSH_RECOVERY_COMPLETE"
