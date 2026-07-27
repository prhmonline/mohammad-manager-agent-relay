#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/root/discover-agent-assets-${STAMP}.log"
exec > >(tee -a "$LOG") 2>&1

section(){ printf '\n===== %s =====\n' "$*"; }

section "TARGET"
hostname
ip -br addr

section "REMOVE FAILED SELFHEAL"
systemctl disable --now prhm-agent-selfheal.timer 2>/dev/null || true
rm -f /etc/systemd/system/prhm-agent-selfheal.timer \
      /etc/systemd/system/prhm-agent-selfheal.service \
      /usr/local/sbin/prhm-agent-selfheal
rm -rf /etc/systemd/system/prhm-agent-api.service.d \
       /etc/systemd/system/prhm-agent-mcp.service.d
systemctl daemon-reload
systemctl reset-failed || true

section "EXPECTED DIRECTORIES"
for p in /home/agent /home/agent/ssh-agent-api /home/agent/ssh-mcp-server; do
  if [[ -e "$p" ]]; then
    ls -lad "$p"
    find "$p" -maxdepth 2 -type f \( -name server.js -o -name package.json -o -name .env -o -name '*.service' \) -printf '%p\n' 2>/dev/null | sort
  else
    echo "MISSING $p"
  fi
done

section "LIKELY DIRECTORIES"
find /root /home /opt /srv /var/backups /var/lib \
  -xdev \
  -path '*/node_modules' -prune -o \
  -path '*/overlay2/*/diff/usr' -prune -o \
  -type d \( -iname '*ssh-agent-api*' -o -iname '*ssh-mcp-server*' -o -iname '*agent-migration*' -o -iname '*sshagent*' \) \
  -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -r | head -n 300 || true

section "LIKELY FILES"
find /root /home /opt /srv /var/backups /var/lib \
  -xdev \
  -path '*/node_modules' -prune -o \
  -type f \( \
      -iname '*agent*migration*' -o \
      -iname '*sshagent*' -o \
      -iname '*ssh-agent-api*' -o \
      -iname '*ssh-mcp-server*' -o \
      -iname '*agent*.tar' -o \
      -iname '*agent*.tar.gz' -o \
      -iname '*agent*.tgz' -o \
      -iname '*agent*.zip' \
  \) -printf '%s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -nr | head -n 300 || true

section "ARCHIVES CONTAINING AGENT SOURCE"
while IFS= read -r archive; do
  [[ -f "$archive" ]] || continue
  case "$archive" in
    *.tar.gz|*.tgz)
      members="$(timeout 20 tar -tzf "$archive" 2>/dev/null | grep -E '(^|/)(ssh-agent-api|ssh-mcp-server)/(server\.js|package\.json|\.env)$' | head -n 20 || true)"
      ;;
    *.tar)
      members="$(timeout 20 tar -tf "$archive" 2>/dev/null | grep -E '(^|/)(ssh-agent-api|ssh-mcp-server)/(server\.js|package\.json|\.env)$' | head -n 20 || true)"
      ;;
    *.zip)
      members="$(timeout 20 unzip -Z1 "$archive" 2>/dev/null | grep -E '(^|/)(ssh-agent-api|ssh-mcp-server)/(server\.js|package\.json|\.env)$' | head -n 20 || true)"
      ;;
    *) members="" ;;
  esac
  if [[ -n "$members" ]]; then
    echo "ARCHIVE=$archive"
    echo "$members"
  fi
done < <(find /root /home /opt /srv /var/backups -xdev -type f \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar' -o -name '*.zip' \) 2>/dev/null | sort)

section "SOURCE SIGNATURE SEARCH"
find /root /home /opt /srv /var/backups /var/lib/docker/volumes /var/lib/docker/overlay2 \
  -xdev \
  -path '*/node_modules' -prune -o \
  -type f -name package.json -size -2M -print0 2>/dev/null \
| xargs -0 -r grep -IlE '"name"[[:space:]]*:[[:space:]]*"(ssh-agent-api|ssh-mcp-server)"' 2>/dev/null \
| sort -u | head -n 200 || true

section "ENV SIGNATURE SEARCH"
find /root /home /opt /srv /var/backups /var/lib/docker/volumes /var/lib/docker/overlay2 \
  -xdev \
  -path '*/node_modules' -prune -o \
  -type f \( -name '.env' -o -name '*.env' \) -size -2M -print0 2>/dev/null \
| xargs -0 -r grep -IlE 'ACTION_API_KEY|SSH_PRIVATE_KEY_PATH|SSH_HOST|SSH_AGENT_BASE_URL' 2>/dev/null \
| sort -u | head -n 200 || true

section "DOCKER CONTAINERS"
if command -v docker >/dev/null 2>&1; then
  docker ps -a --format 'name={{.Names}} image={{.Image}} status={{.Status}} ports={{.Ports}}'
  echo
  echo "--- likely agent containers ---"
  docker ps -a --format '{{.Names}} {{.Image}}' | grep -Ei 'agent|mcp|ssh' || true
  echo
  echo "--- mounts for all containers ---"
  for c in $(docker ps -aq); do
    name="$(docker inspect -f '{{.Name}}' "$c" 2>/dev/null | sed 's#^/##')"
    echo "[$name]"
    docker inspect -f '{{range .Mounts}}{{println .Type .Source "->" .Destination}}{{end}}' "$c" 2>/dev/null || true
  done
else
  echo "docker not installed"
fi

section "NGINX AGENT CONFIG"
if command -v nginx >/dev/null 2>&1; then
  nginx -T 2>&1 | grep -nE -B5 -A20 'agent\.prhm\.ir|127\.0\.0\.1:(8099|8123)|proxy_pass' | head -n 500 || true
else
  grep -RInE -B3 -A15 'agent\.prhm\.ir|127\.0\.0\.1:(8099|8123)|proxy_pass' /etc/nginx /usr/local/directadmin 2>/dev/null | head -n 500 || true
fi

section "SHELL HISTORY CLUES"
grep -RInE 'ssh-agent-api|ssh-mcp-server|agent-migration|prhm-agent-(api|mcp)' /root/.*history /home/*/.*history 2>/dev/null | tail -n 300 || true

section "RESULT"
echo "DISCOVERY_COMPLETE"
echo "LOG=$LOG"
