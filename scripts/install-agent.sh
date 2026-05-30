#!/bin/sh
set -eu

INSTALLER_NAME="Thermo agent installer"
SOURCE_TARBALL_URL="https://github.com/zalaghi/thermo/archive/refs/heads/main.tar.gz"
LINUX_INSTALL_DIR="/opt/thermo-agent"
FREEBSD_INSTALL_DIR="/usr/local/thermo-agent"
LINUX_ENV_FILE="/etc/thermo-agent.env"
FREEBSD_ENV_FILE="/usr/local/etc/thermo-agent.env"
DEFAULT_PORT="8090"

THERMO_URL=""
PAIRING_TOKEN=""
PLATFORM="auto"
BIND_HOST=""
AGENT_PORT="$DEFAULT_PORT"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  install-agent.sh --thermo-url URL --pairing-token TOKEN --bind-host HOST [--port PORT] [--platform NAME]

Example:
  curl -fsSL https://raw.githubusercontent.com/zalaghi/thermo/main/scripts/install-agent.sh | sudo sh -s -- \
    --thermo-url http://192.168.1.50:8088 \
    --pairing-token abc123 \
    --bind-host 192.168.1.10 \
    --port 8090 \
    --platform proxmox
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --thermo-url)
      THERMO_URL="${2:-}"
      shift 2
      ;;
    --pairing-token)
      PAIRING_TOKEN="${2:-}"
      shift 2
      ;;
    --platform)
      PLATFORM="${2:-auto}"
      shift 2
      ;;
    --bind-host)
      BIND_HOST="${2:-}"
      shift 2
      ;;
    --port)
      AGENT_PORT="${2:-$DEFAULT_PORT}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

[ -n "$THERMO_URL" ] || fail "--thermo-url is required"
[ -n "$PAIRING_TOKEN" ] || fail "--pairing-token is required"
[ -n "$BIND_HOST" ] || fail "--bind-host is required"

case "$AGENT_PORT" in
  *[!0-9]*|"") fail "--port must be numeric" ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  fail "Run the installer as root, for example with: curl -fsSL ... | sudo sh -s -- ..."
fi

OS_NAME="$(uname -s)"
case "$OS_NAME" in
  Linux)
    INSTALL_DIR="$LINUX_INSTALL_DIR"
    ENV_FILE="$LINUX_ENV_FILE"
    SERVICE_STYLE="systemd"
    DEFAULT_TEMP_COMMAND="sensors | awk '/Package id 0|Tctl|CPU/ {print \$0; exit}' | grep -oE '[+-]?[0-9]+(\\.[0-9]+)?°C' | head -n1 | tr -d '+°C'"
    ;;
  FreeBSD)
    INSTALL_DIR="$FREEBSD_INSTALL_DIR"
    ENV_FILE="$FREEBSD_ENV_FILE"
    SERVICE_STYLE="rcd"
    DEFAULT_TEMP_COMMAND="sysctl -n dev.cpu.0.temperature | sed 's/C//'"
    ;;
  *)
    INSTALL_DIR="$LINUX_INSTALL_DIR"
    ENV_FILE="$LINUX_ENV_FILE"
    SERVICE_STYLE="manual"
    DEFAULT_TEMP_COMMAND="echo 42.5"
    ;;
esac

LOCAL_TEST_HOST="$BIND_HOST"
if [ "$LOCAL_TEST_HOST" = "0.0.0.0" ]; then
  LOCAL_TEST_HOST="127.0.0.1"
fi

download() {
  url="$1"
  output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
    return
  fi
  if command -v fetch >/dev/null 2>&1; then
    fetch -q -o "$output" "$url"
    return
  fi
  fail "curl or fetch is required to download Thermo."
}

shell_quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

install_dependencies() {
  if [ "$OS_NAME" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
    log "Installing Linux dependencies with apt..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv curl tar lm-sensors
    return
  fi

  if [ "$OS_NAME" = "FreeBSD" ] && command -v pkg >/dev/null 2>&1; then
    log "Installing FreeBSD dependencies with pkg..."
    pkg install -y python3 py311-sqlite3 curl gtar || pkg install -y python3 curl gtar
    return
  fi

  log "Skipping OS dependency installation; install python3, venv support, curl/fetch, and tar manually if needed."
}

register_with_thermo() {
  log "Registering with Thermo..."
  RESPONSE="$(
    THERMO_URL="$THERMO_URL" PAIRING_TOKEN="$PAIRING_TOKEN" PLATFORM="$PLATFORM" BIND_HOST="$BIND_HOST" AGENT_PORT="$AGENT_PORT" python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

payload = {
    "pairing_token": os.environ["PAIRING_TOKEN"],
    "platform": os.environ.get("PLATFORM", "auto"),
    "bind_host": os.environ.get("BIND_HOST", ""),
    "agent_port": os.environ.get("AGENT_PORT", ""),
}
url = os.environ["THERMO_URL"].rstrip("/") + "/api/setup/register"
request = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json", "Accept": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=15) as response:
        print(response.read().decode("utf-8"))
except urllib.error.HTTPError as exc:
    sys.stderr.write(exc.read().decode("utf-8", "replace") + "\n")
    raise
PY
  )" || fail "Thermo registration failed"

  AGENT_API_KEY="$(
    RESPONSE="$RESPONSE" python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["RESPONSE"])
key = payload.get("agent_api_key")
if not key:
    raise SystemExit("missing agent_api_key")
print(key)
PY
  )" || fail "Thermo registration response did not include an agent API key"
}

install_agent_files() {
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

  log "Downloading Thermo source..."
  download "$SOURCE_TARBALL_URL" "$TMP_DIR/thermo.tar.gz"

  mkdir -p "$TMP_DIR/src"
  if command -v tar >/dev/null 2>&1; then
    tar -xzf "$TMP_DIR/thermo.tar.gz" -C "$TMP_DIR/src"
  elif command -v gtar >/dev/null 2>&1; then
    gtar -xzf "$TMP_DIR/thermo.tar.gz" -C "$TMP_DIR/src"
  else
    fail "tar is required."
  fi

  SRC_ROOT="$(find "$TMP_DIR/src" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "$SRC_ROOT" ] || fail "Downloaded Thermo source archive was empty."

  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/agent"
  cp -R "$SRC_ROOT/agent" "$INSTALL_DIR/agent"
  chown -R root:root "$INSTALL_DIR" 2>/dev/null || true
}

create_venv() {
  log "Creating Python virtual environment..."
  python3 -m venv "$INSTALL_DIR/.venv"
  "$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
  "$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/agent/requirements.txt"
}

write_env_file() {
  log "Writing agent environment file..."
  mkdir -p "$(dirname "$ENV_FILE")"
  umask 077
  agent_api_key_quoted="$(shell_quote "$AGENT_API_KEY")"
  temp_command_quoted="$(shell_quote "$DEFAULT_TEMP_COMMAND")"
  cat >"$ENV_FILE" <<EOF
THERMO_AGENT_API_KEY=$agent_api_key_quoted
THERMO_TEMP_COMMAND=$temp_command_quoted
THERMO_TEMP_TIMEOUT_SECONDS='3'
EOF
}

create_linux_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    SERVICE_STYLE="manual"
    return
  fi

  log "Creating systemd service..."
  cat >/etc/systemd/system/thermo-agent.service <<EOF
[Unit]
Description=Thermo temperature agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$INSTALL_DIR/.venv/bin/uvicorn agent.main:app --host $BIND_HOST --port $AGENT_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now thermo-agent.service
}

create_freebsd_service() {
  if [ ! -f /etc/rc.subr ] || ! command -v daemon >/dev/null 2>&1; then
    SERVICE_STYLE="manual"
    return
  fi

  log "Creating FreeBSD rc.d service..."
  cat >"$INSTALL_DIR/run-agent.sh" <<EOF
#!/bin/sh
. "$ENV_FILE"
export THERMO_AGENT_API_KEY THERMO_TEMP_COMMAND THERMO_TEMP_TIMEOUT_SECONDS
cd "$INSTALL_DIR"
exec "$INSTALL_DIR/.venv/bin/uvicorn" agent.main:app --host "$BIND_HOST" --port "$AGENT_PORT"
EOF
  chmod 700 "$INSTALL_DIR/run-agent.sh"

  cat >/usr/local/etc/rc.d/thermo_agent <<EOF
#!/bin/sh
# PROVIDE: thermo_agent
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="thermo_agent"
rcvar="thermo_agent_enable"
pidfile="/var/run/\${name}.pid"
command="/usr/sbin/daemon"
command_args="-f -p \${pidfile} $INSTALL_DIR/run-agent.sh"

load_rc_config \$name
: \${thermo_agent_enable:="NO"}

run_rc_command "\$1"
EOF
  chmod 755 /usr/local/etc/rc.d/thermo_agent
  sysrc thermo_agent_enable=YES >/dev/null
  service thermo_agent restart
}

start_service() {
  case "$SERVICE_STYLE" in
    systemd)
      create_linux_service
      ;;
    rcd)
      create_freebsd_service
      ;;
    *)
      ;;
  esac

  if [ "$SERVICE_STYLE" = "manual" ]; then
    log "No supported service manager was detected."
    log "Run manually with:"
    log ". $ENV_FILE && export THERMO_AGENT_API_KEY THERMO_TEMP_COMMAND THERMO_TEMP_TIMEOUT_SECONDS && cd $INSTALL_DIR && $INSTALL_DIR/.venv/bin/uvicorn agent.main:app --host $BIND_HOST --port $AGENT_PORT"
  fi
}

test_agent() {
  log "Testing local agent endpoints..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsS "http://$LOCAL_TEST_HOST:$AGENT_PORT/health" >/dev/null || fail "Agent /health check failed"
    curl -fsS -H "X-API-Key: $AGENT_API_KEY" "http://$LOCAL_TEST_HOST:$AGENT_PORT/temperature" >/dev/null || fail "Agent /temperature check failed"
    return
  fi
  log "curl not available; skipping local HTTP test."
}

log "$INSTALLER_NAME"
log "Platform: $PLATFORM ($OS_NAME)"
log "Install directory: $INSTALL_DIR"

install_dependencies
install_agent_files
create_venv
register_with_thermo
write_env_file
start_service

if [ "$SERVICE_STYLE" != "manual" ]; then
  sleep 2
  test_agent
fi

log "Thermo agent installation completed."
log "Agent URL: http://$BIND_HOST:$AGENT_PORT/temperature"
