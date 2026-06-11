#!/usr/bin/env bash
# kali-firstlogon.sh — converted from bootstrap.txt cloud-init
# Runs once on first boot/logon; sentinel: /var/lib/kali-firstlogon.done
# Credentials are injected by Terraform (replace __ADMIN_PW_B64__ / __ADMIN_USERNAME__)

SENTINEL="/var/lib/kali-firstlogon.done"
LOG_FILE="/var/log/kali-firstlogon.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log(){ echo "[$(date -Is)] $*"; }

if [ -f "$SENTINEL" ]; then
  log "First-logon setup already completed — exiting"; exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

ADMIN_PW_B64='__ADMIN_PW_B64__'
ADMIN_USER='__ADMIN_USERNAME__'
NEW_PASS=$(printf '%s' "$ADMIN_PW_B64" | base64 -d)

log "=== Kali first-logon setup (user: ${ADMIN_USER}) ==="

STEPS_OK=(); STEPS_FAIL=()
run_step() {
  local name="$1"; shift
  log ">>> STEP START: ${name}"
  local rc=0; "$@" || rc=$?
  if   [ $rc -eq 0 ]; then log ">>> STEP OK:   ${name}"; STEPS_OK+=("${name}")
  else                     log ">>> STEP FAIL: ${name} (rc=${rc})"; STEPS_FAIL+=("${name}")
  fi
}
print_summary() {
  log ""; log "========================================"
  log "FIRST-LOGON SUMMARY"; log "========================================"
  log "Steps: $(( ${#STEPS_OK[@]} + ${#STEPS_FAIL[@]} )) total  |  ${#STEPS_OK[@]} OK  |  ${#STEPS_FAIL[@]} FAIL"
  log "----------------------------------------"
  for s in "${STEPS_OK[@]}";   do log "  [OK]   ${s}"; done
  for s in "${STEPS_FAIL[@]}"; do log "  [FAIL] ${s}"; done
  log "========================================"
  log "Full log: ${LOG_FILE}"
  if [ "${#STEPS_FAIL[@]}" -eq 0 ]; then
    touch "$SENTINEL"
    log "Sentinel created: $SENTINEL"
  else
    log "Some steps FAILED — sentinel not created (will retry on next run)"
  fi
}
trap print_summary EXIT

# ── 1. System update ──────────────────────────────────────────────────────────
step_apt_update() {
  apt-get update -y
  dpkg --configure -a
  apt-get -f install -y
}
run_step "apt-get update + dpkg fix" step_apt_update

# ── 2. Plymouth / initramfs ───────────────────────────────────────────────────
step_plymouth() {
  if ! dpkg -s plymouth >/dev/null 2>&1; then
    apt-get install -y plymouth initramfs-tools
  fi
  update-initramfs -u
}
run_step "plymouth/initramfs" step_plymouth

# ── 3. Core packages ──────────────────────────────────────────────────────────
step_packages() {
  apt-get install -y \
    docker.io curl git jq netcat-openbsd \
    python3 python3-dev python3-pip python3-venv \
    wireshark wireshark-common burpsuite \
    kali-desktop-xfce xrdp xorgxrdp xfce4 xfce4-goodies
}
run_step "install core packages" step_packages

# ── 4. Postman (non-fatal on download failure) ────────────────────────────────
step_postman() {
  if ! curl -fsSL "https://dl.pstmn.io/download/latest/linux64" -o /tmp/postman.tar.gz; then
    log "Postman download failed — skipping (non-fatal)"; return 0
  fi
  tar -xzf /tmp/postman.tar.gz -C /opt/
  ln -sf /opt/Postman/Postman /usr/local/bin/postman
  log "Postman installed"
}
run_step "install postman" step_postman

# ── 5. xrdp / xfce ───────────────────────────────────────────────────────────
step_xrdp() {
  adduser xrdp ssl-cert || true
  echo "allowed_users=anybody" > /etc/X11/Xwrapper.config
  sed -i.bak \
    '/^test -r \/etc\/X11\/Xsession/d;/^exec \/bin\/sh \/etc\/X11\/Xsession/d' \
    /etc/xrdp/startwm.sh
  grep -q '^startxfce4' /etc/xrdp/startwm.sh || echo "startxfce4" >> /etc/xrdp/startwm.sh
  install -d -o "${ADMIN_USER}" -g "${ADMIN_USER}" "/home/${ADMIN_USER}"
  echo "startxfce4" > "/home/${ADMIN_USER}/.xsession"
  chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.xsession"
  systemctl enable --now xrdp xrdp-sesman
}
run_step "xrdp/xfce setup" step_xrdp

# ── 6. docker-compose ─────────────────────────────────────────────────────────
step_docker_compose() {
  if command -v docker-compose >/dev/null 2>&1; then
    log "docker-compose already in PATH: $(command -v docker-compose)"; return 0
  fi
  curl -fsSL \
    https://github.com/docker/compose/releases/download/v2.29.1/docker-compose-linux-x86_64 \
    -o /usr/local/bin/docker-compose
  chmod 755 /usr/local/bin/docker-compose
  ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
  log "docker-compose v2.29.1 installed"
}
run_step "docker-compose install" step_docker_compose

# ── 7. Docker daemon ──────────────────────────────────────────────────────────
step_docker() {
  systemctl enable --now docker
  usermod -aG docker "${ADMIN_USER}"
  for i in $(seq 1 60); do
    systemctl is-active --quiet docker && docker info >/dev/null 2>&1 && return 0
    sleep 2
  done
  log "Docker daemon not ready after 120s"; return 1
}
run_step "docker daemon" step_docker

# ── 8. Go install ─────────────────────────────────────────────────────────────
step_go() {
  if /usr/local/go/bin/go version >/dev/null 2>&1; then
    log "Go already installed: $(/usr/local/go/bin/go version)"; return 0
  fi
  log "Installing Go 1.22.2..."
  cd /tmp
  rm -rf /usr/local/go
  wget -q https://go.dev/dl/go1.22.2.linux-amd64.tar.gz
  [ -f go1.22.2.linux-amd64.tar.gz ] || { log "Go tarball download failed"; return 1; }
  tar -C /usr/local -xzf go1.22.2.linux-amd64.tar.gz
  [ -f /usr/local/go/bin/go ] || { log "Go extraction failed"; return 1; }
  grep -q '/usr/local/go/bin' /etc/profile     || echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
  grep -q '^export GOPATH='   /etc/profile     || echo 'export GOPATH=/home/labuser/go'       >> /etc/profile
  grep -q '/usr/local/go/bin' "/home/${ADMIN_USER}/.bashrc" \
    || echo 'export PATH=$PATH:/usr/local/go/bin' >> "/home/${ADMIN_USER}/.bashrc"
  grep -q '^export GOPATH='   "/home/${ADMIN_USER}/.bashrc" \
    || echo "export GOPATH=/home/${ADMIN_USER}/go"  >> "/home/${ADMIN_USER}/.bashrc"
  chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.bashrc"
  grep -q '/usr/local/go/bin' /root/.bashrc  || echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.bashrc
  grep -q '/usr/local/go/bin' /root/.profile || echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.profile
  ln -sf /usr/local/go/bin/go    /usr/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/bin/gofmt
  export PATH="/usr/local/go/bin:$PATH"
  /usr/local/go/bin/go version >/dev/null 2>&1 || { log "Go post-install verify failed"; return 1; }
  log "Go installed: $(/usr/local/go/bin/go version)"
}
run_step "go install" step_go

# ── 9. Create helper scripts ──────────────────────────────────────────────────
step_create_scripts() {
  mkdir -p /opt/mltool
  chmod 755 /opt/mltool
  chown "${ADMIN_USER}:${ADMIN_USER}" /opt/mltool

  cat > /opt/mltool/profiles.json << 'PROFILES'
{
  "juice-mixed": {
    "mode": "mixed", "duration": "120s", "rps": 35, "concurrency": 40,
    "progress": "10s", "timeout": "10s", "same_ip": false,
    "juice_optimized": true, "log_csv": "logs/juice-mixed.csv"
  },
  "juice-scrape-burst": {
    "mode": "scrape", "duration": "60s", "burst_requests": 180, "burst_window": "30s",
    "same_ip": true, "progress": "5s", "timeout": "8s",
    "juice_optimized": true, "log_csv": "logs/juice-burst.csv"
  },
  "juice-slow-7-in-100s": {
    "mode": "slow", "duration": "120s", "slow_count": 7, "slow_window": "100s",
    "slow_bytes": 4096, "slow_interval": "1500ms", "same_ip": true,
    "progress": "10s", "timeout": "15s",
    "juice_optimized": true, "log_csv": "logs/juice-slow.csv"
  }
}
PROFILES

  cat > /usr/local/bin/build-ml2.sh << 'BUILDSCRIPT'
#!/usr/bin/env bash
LOG_FILE="/var/log/build-ml2.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
log(){ echo "[build-ml2] [$(date -Is)] $*"; }

export PATH="/usr/local/go/bin:$PATH"
export GOCACHE="/tmp/go-build"
export GOPATH="/tmp/go"
export HOME="/root"

STEPS_OK=(); STEPS_FAIL=()
run_step() {
  local name="$1"; shift
  log ">>> STEP START: ${name}"
  local rc=0; "$@" || rc=$?
  if   [ $rc -eq 0 ]; then log ">>> STEP OK:   ${name}"; STEPS_OK+=("${name}")
  else                     log ">>> STEP FAIL: ${name} (rc=${rc})"; STEPS_FAIL+=("${name}")
  fi
}
print_summary() {
  log ""; log "========================================"
  log "BUILD SUMMARY"; log "========================================"
  log "Steps: $(( ${#STEPS_OK[@]} + ${#STEPS_FAIL[@]} )) total  |  ${#STEPS_OK[@]} OK  |  ${#STEPS_FAIL[@]} FAIL"
  log "----------------------------------------"
  for s in "${STEPS_OK[@]}";   do log "  [OK]   ${s}"; done
  for s in "${STEPS_FAIL[@]}"; do log "  [FAIL] ${s}"; done
  log "========================================"; log "Full log: ${LOG_FILE}"
}
trap print_summary EXIT

LOCKFILE=/tmp/build-ml2.lock
exec 200>"${LOCKFILE}"
flock -w 120 200 || { log "Could not acquire build lock after 120s"; exit 1; }

log "Starting build-ml2.sh"
mkdir -p /opt/mltool && chmod 755 /opt/mltool

build_tool() {
  (
    set -e
    local name="$1" src="$2" bin="$3" mod="$4"
    log "Building ${name}: ${src} -> ${bin}"
    [ -f "${src}" ] || { log "ERROR: source ${src} not found"; exit 1; }
    local dir="/opt/mltool/${mod}"
    rm -rf "${dir}"; mkdir -p "${dir}"
    cp "${src}" "${dir}/"
    cd "${dir}"
    go mod init "${mod}"
    go mod tidy
    go build -trimpath -ldflags "-s -w" -o "${bin}" .
    chmod +x "${bin}"
    log "${name} built OK -> ${bin}"
  )
}

run_step "build ml2"    build_tool "ML-2"   /opt/mltool/ml2.go    /usr/local/bin/ml-2   ml2
run_step "build bots"   build_tool "Bots"   /opt/mltool/bots.go   /usr/local/bin/bots   bots
run_step "build ml-mix" build_tool "ML-Mix" /opt/mltool/ml-mix.go /usr/local/bin/ml-mix ml-mix

install -d -m 0755 /opt/mltool/logs
log "All builds complete"
BUILDSCRIPT
  chmod 755 /usr/local/bin/build-ml2.sh
}
run_step "create helper scripts" step_create_scripts

# ── 10. Guacamole clone + override ───────────────────────────────────────────
step_guacamole_clone() {
  if [ ! -d /opt/guacamole ]; then
    git clone --depth=1 \
      https://github.com/boschkundendienst/guacamole-docker-compose \
      /opt/guacamole
  fi
  [ -d /opt/guacamole ]                    || { log "Guacamole clone failed"; return 1; }
  [ -f /opt/guacamole/docker-compose.yml ] || { log "docker-compose.yml not found after clone"; return 1; }
  cat > /opt/guacamole/docker-compose.override.yml << 'GUAC_OVERRIDE'
services:
  guacd:
    extra_hosts:
      - "host.docker.internal:host-gateway"
GUAC_OVERRIDE
  log "Wrote docker-compose.override.yml (guacd -> host.docker.internal)"
}
run_step "guacamole clone+override" step_guacamole_clone

# ── 11. Guacamole start ───────────────────────────────────────────────────────
step_guacamole_start() {
  [ -f /opt/guacamole/prepare.sh ] || { log "prepare.sh not found in /opt/guacamole"; return 1; }
  bash -lc 'cd /opt/guacamole && bash ./prepare.sh && docker-compose up -d'
}
run_step "guacamole start" step_guacamole_start

# ── 12. Guacamole API: wait + configure ──────────────────────────────────────
wait_tcp() {
  local h="$1" p="$2" t="${3:-90}"
  for i in $(seq 1 "$t"); do nc -z "$h" "$p" 2>/dev/null && return 0; sleep 1; done
  return 1
}
wait_http_tokens() {
  local u="$1" t="${2:-120}" code
  for i in $(seq 1 "$t"); do
    code=$(curl -ksS -o /dev/null -w '%{http_code}' -X POST "$u" \
           -H "Content-Type: application/x-www-form-urlencoded" \
           --data 'username=guacadmin&password=guacadmin' || true)
    case "$code" in 200|401|403) return 0;; esac
    sleep 2
  done
  return 1
}

step_guacamole_api() {
  PRIMARY_IP=$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
  [ -n "${PRIMARY_IP}" ] || PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  log "Primary IP: ${PRIMARY_IP:-unset}"

  NGINX_PORT="$(docker port nginx_guacamole_compose 443/tcp 2>/dev/null \
    | awk -F: '{print $2}' | head -n1 || true)"
  GUAC_PORT="$(docker port guacamole_compose 8080/tcp 2>/dev/null \
    | awk -F: '{print $2}' | head -n1 || true)"
  API_BASE=""

  if [ -n "${NGINX_PORT}" ]; then
    wait_tcp "${PRIMARY_IP}" "${NGINX_PORT}" 90 || true
    wait_http_tokens "https://${PRIMARY_IP}:${NGINX_PORT}/guacamole/api/tokens" 90 \
      && API_BASE="https://${PRIMARY_IP}:${NGINX_PORT}/guacamole"
  fi
  if [ -z "${API_BASE}" ] && [ -n "${GUAC_PORT}" ]; then
    wait_tcp 127.0.0.1 "${GUAC_PORT}" 90 || true
    wait_http_tokens "http://127.0.0.1:${GUAC_PORT}/guacamole/api/tokens" 120 \
      && API_BASE="http://127.0.0.1:${GUAC_PORT}/guacamole"
  fi
  [ -n "${API_BASE}" ] || { log "Guacamole API unreachable after retries"; docker ps -a; return 1; }
  log "Guacamole API base: ${API_BASE}"

  TOKEN_JSON=$(curl -ksS -X POST "${API_BASE}/api/tokens" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data 'username=guacadmin&password=guacadmin' || true)
  TOKEN_DEF=$(echo "${TOKEN_JSON}" | jq -r .authToken)
  DS=$(echo "${TOKEN_JSON}"        | jq -r '.availableDataSources[0]')

  if [ -n "${TOKEN_DEF}" ] && [ "${TOKEN_DEF}" != "null" ]; then
    log "Default login OK; changing admin password"
    curl -ksS -X PUT "${API_BASE}/api/session/data/${DS}/users/guacadmin/password" \
      -H "Guacamole-Token: ${TOKEN_DEF}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg old 'guacadmin' --arg new "${NEW_PASS}" \
            '{oldPassword:$old,newPassword:$new}')" >/dev/null || true
  else
    log "Default login failed — password may already be changed"
  fi

  TOKEN_JSON=$(curl -ksS -X POST "${API_BASE}/api/tokens" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "username=guacadmin&password=${NEW_PASS}" || true)
  TOKEN=$(echo "${TOKEN_JSON}" | jq -r .authToken)
  DS=$(echo "${TOKEN_JSON}"    | jq -r '.availableDataSources[0]')
  [ -n "${TOKEN}" ] && [ "${TOKEN}" != "null" ] \
    || { log "Auth with new password failed — cannot create RDP connection"; return 1; }
  log "Authenticated to Guacamole API"

  for i in {1..60}; do
    ss -ltn | grep -q ':3389 ' && break
    systemctl restart xrdp || true
    sleep 5
  done

  DS=${DS:-postgresql}
  PAYLOAD=$(jq -n \
    --arg host "host.docker.internal" \
    --arg pass "${NEW_PASS}" \
    --arg user "${ADMIN_USER}" \
    '{name:"Lab Desktop",parentIdentifier:"ROOT",protocol:"rdp",
      parameters:{hostname:$host,port:"3389",username:$user,password:$pass,
        "ignore-cert":"true",security:"rdp","disable-nla":"true",
        "enable-wallpaper":"false","resize-method":"display-update",
        "color-depth":"24","enable-font-smoothing":"true"},
      attributes:{}}')

  curl_json() {
    local m="$1" u="$2" d="${3:-}"
    if [ -n "$d" ]; then
      curl -ksS -H "Guacamole-Token: ${TOKEN}" -H "Content-Type: application/json" \
           -X "$m" -d "$d" "$u" -w $'\n%{http_code}'
    else
      curl -ksS -H "Guacamole-Token: ${TOKEN}" -X "$m" "$u" -w $'\n%{http_code}'
    fi
  }

  BAC=$(curl_json GET "${API_BASE}/api/session/data/${DS}/connections?contains=Lab%20Desktop")
  CODE="${BAC##*$'\n'}"; BODY="${BAC%$'\n'*}"; CID=""
  [ "${CODE}" = "200" ] && \
    CID=$(echo "${BODY}" | jq -r \
      'if (type=="array" and length>0 and .[0]|has("identifier")) then .[0].identifier else empty end' \
      2>/dev/null || true)

  if [ -n "${CID}" ]; then
    log "Updating existing 'Lab Desktop' connection (${CID})"
    BAC=$(curl_json PUT "${API_BASE}/api/session/data/${DS}/connections/${CID}" "${PAYLOAD}")
    CODE="${BAC##*$'\n'}"
    [ "${CODE}" = "204" ] || log "WARN: PUT connection returned HTTP ${CODE}"
  else
    log "Creating 'Lab Desktop' connection"
    BAC=$(curl_json POST "${API_BASE}/api/session/data/${DS}/connections" "${PAYLOAD}")
    CODE="${BAC##*$'\n'}"
    [ "${CODE}" = "200" ] || [ "${CODE}" = "201" ] || log "WARN: POST connection returned HTTP ${CODE}"
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx guacd_compose; then
    if H=$(docker exec guacd_compose getent hosts host.docker.internal 2>/dev/null); then
      log "guacd resolves host.docker.internal: ${H}"
    else
      log "WARN: host.docker.internal missing inside guacd — check override file"
    fi
    if docker exec guacd_compose sh -c \
         'command -v nc >/dev/null 2>&1 && nc -z -w 3 host.docker.internal 3389' 2>/dev/null; then
      log "guacd -> host.docker.internal:3389 reachable OK"
    else
      log "WARN: guacd tcp:3389 check failed (nc missing, xrdp down, or override not applied)"
    fi
  fi
}
run_step "guacamole API configure" step_guacamole_api

# ── 13. Install systemd service for idempotent re-runs ───────────────────────
step_install_service() {
  cat > /etc/systemd/system/kali-firstlogon.service << 'UNIT'
[Unit]
Description=Kali First-Logon Provisioning
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/kali-firstlogon.done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kali-firstlogon.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=3600

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable kali-firstlogon
}
run_step "install systemd service" step_install_service

log "=== First-logon setup finished ==="
