#!/bin/sh
set -eu

INSTALLER_NAME="Thermo agent installer"
DEFAULT_SOURCE_TARBALL_URL="https://github.com/zalaghi/thermo/archive/refs/heads/main.tar.gz"

LINUX_INSTALL_DIR="/opt/thermo-agent"
LINUX_ENV_FILE="/etc/thermo-agent.env"
LINUX_REGISTRATION_FILE="/etc/thermo-agent-registration.env"
LINUX_SERVICE_FILE="/etc/systemd/system/thermo-agent.service"
LINUX_SERVICE_NAME="thermo-agent.service"

FREEBSD_INSTALL_DIR="/usr/local/thermo-agent"
FREEBSD_ENV_FILE="/usr/local/etc/thermo-agent.env"
FREEBSD_REGISTRATION_FILE="/usr/local/etc/thermo-agent-registration.env"
FREEBSD_SERVICE_FILE="/usr/local/etc/rc.d/thermo_agent"
FREEBSD_SERVICE_NAME="thermo_agent"

DEFAULT_PORT="8090"
DEFAULT_BIND_HOST="0.0.0.0"

THERMO_URL=""
PAIRING_TOKEN=""
OVERRIDE_BIND_HOST=""
OVERRIDE_PORT=""
DRY_RUN=0
UNINSTALL=0
DEPS_INSTALLED=0
DEBUG=0

TMP_DIR=""
OS_KIND=""
DISTRO_ID="unknown"
DISTRO_ID_LIKE=""
DISTRO_NAME="Linux"
DISTRO_FAMILY="generic"
IS_PROXMOX=0
IS_TRUENAS=0

INSTALL_DIR="$LINUX_INSTALL_DIR"
ENV_FILE="$LINUX_ENV_FILE"
REGISTRATION_FILE="$LINUX_REGISTRATION_FILE"
SERVICE_FILE="$LINUX_SERVICE_FILE"
SERVICE_NAME="$LINUX_SERVICE_NAME"

BOOTSTRAP_JSON=""
SERVER_NAME=""
BOOTSTRAP_PLATFORM=""
BOOTSTRAP_BIND_HOST=""
BOOTSTRAP_AGENT_PORT=""
CENTRAL_URL=""
AGENT_API_KEY=""
SOURCE_TARBALL_URL="$DEFAULT_SOURCE_TARBALL_URL"
TEMPERATURE_COMMAND_HINT=""
TEMP_COMMAND=""
TEMP_COMMAND_LABEL=""
TEST_TEMPERATURE=""
DETECTED_IP=""
DETECTED_HOSTNAME=""
DETECTED_PLATFORM=""

PYTHONPATH_DIR=""

log() {
  printf '%s\n' "$*"
}

debug_log() {
  if [ "$DEBUG" -eq 1 ]; then
    printf 'DEBUG: %s\n' "$*"
  fi
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  install-agent.sh --thermo-url URL --token TOKEN [--bind-host HOST] [--port PORT] [--debug] [--dry-run]
  install-agent.sh --uninstall

Examples:
  curl -fsSL "https://raw.githubusercontent.com/zalaghi/thermo/main/scripts/install-agent.sh" | sudo sh -s -- \
    --thermo-url "http://THERMO-IP:8088" \
    --token "PAIRING_TOKEN"

  fetch -o - "https://raw.githubusercontent.com/zalaghi/thermo/main/scripts/install-agent.sh" | sh -s -- \
    --thermo-url "http://THERMO-IP:8088" \
    --token "PAIRING_TOKEN"
EOF
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --thermo-url)
      THERMO_URL="${2:-}"
      shift 2
      ;;
    --token)
      PAIRING_TOKEN="${2:-}"
      shift 2
      ;;
    --pairing-token)
      PAIRING_TOKEN="${2:-}"
      shift 2
      ;;
    --bind-host)
      OVERRIDE_BIND_HOST="${2:-}"
      shift 2
      ;;
    --port)
      OVERRIDE_PORT="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      shift
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

THERMO_URL="${THERMO_URL%/}"

set_linux_paths() {
  INSTALL_DIR="$LINUX_INSTALL_DIR"
  ENV_FILE="$LINUX_ENV_FILE"
  REGISTRATION_FILE="$LINUX_REGISTRATION_FILE"
  SERVICE_FILE="$LINUX_SERVICE_FILE"
  SERVICE_NAME="$LINUX_SERVICE_NAME"
}

set_freebsd_paths() {
  INSTALL_DIR="$FREEBSD_INSTALL_DIR"
  ENV_FILE="$FREEBSD_ENV_FILE"
  REGISTRATION_FILE="$FREEBSD_REGISTRATION_FILE"
  SERVICE_FILE="$FREEBSD_SERVICE_FILE"
  SERVICE_NAME="$FREEBSD_SERVICE_NAME"
}

redacted_token() {
  if [ -z "$PAIRING_TOKEN" ]; then
    printf '%s' "<missing>"
    return
  fi
  printf '%s' "$PAIRING_TOKEN" | awk '{ if (length($0) > 8) print "********" substr($0, length($0)-7); else print "********" }'
}

require_root() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return
  fi
  if [ "$(id -u)" -ne 0 ]; then
    fail "Run as root, for example: curl -fsSL ... | sudo sh -s -- --thermo-url URL --token TOKEN"
  fi
}

validate_port() {
  value="$1"
  case "$value" in
    *[!0-9]*|"") return 1 ;;
  esac
  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    return 1
  fi
  return 0
}

validate_bind_host() {
  value="$1"
  case "$value" in
    ""|*"://"*|*"/"*|*"\\"*|*" "*) return 1 ;;
  esac
  return 0
}

shell_quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

owner_group() {
  if [ "$OS_KIND" = "freebsd" ]; then
    printf '%s' "root:wheel"
  else
    printf '%s' "root:root"
  fi
}

detect_os() {
  os_name="$(uname -s)"
  case "$os_name" in
    Linux)
      OS_KIND="linux"
      set_linux_paths
      detect_linux
      ;;
    FreeBSD)
      OS_KIND="freebsd"
      set_freebsd_paths
      detect_freebsd
      ;;
    *)
      if [ "$DRY_RUN" -eq 1 ]; then
        OS_KIND="linux"
        set_linux_paths
        DETECTED_PLATFORM="$os_name (dry run only; installer targets Linux/Proxmox and FreeBSD/TrueNAS)"
        return
      fi
      fail "Unsupported OS: $os_name. This installer supports Linux/Proxmox and FreeBSD/TrueNAS CORE."
      ;;
  esac
}

detect_linux() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_ID_LIKE="${ID_LIKE:-}"
    DISTRO_NAME="${PRETTY_NAME:-Linux}"
  fi

  if command -v pveversion >/dev/null 2>&1; then
    IS_PROXMOX=1
  elif command -v dpkg-query >/dev/null 2>&1; then
    if dpkg-query -W -f='${Status}' pve-manager 2>/dev/null | grep -q "install ok installed"; then
      IS_PROXMOX=1
    elif dpkg-query -W -f='${Status}' proxmox-ve 2>/dev/null | grep -q "install ok installed"; then
      IS_PROXMOX=1
    fi
  fi

  if [ "$IS_PROXMOX" -eq 1 ]; then
    DISTRO_FAMILY="debian"
    DETECTED_PLATFORM="Proxmox ($DISTRO_NAME)"
    return
  fi

  case "$DISTRO_ID" in
    debian|ubuntu)
      DISTRO_FAMILY="debian"
      ;;
    rhel|rocky|almalinux|centos|fedora)
      DISTRO_FAMILY="rhel"
      ;;
    arch|manjaro)
      DISTRO_FAMILY="arch"
      ;;
    alpine)
      DISTRO_FAMILY="alpine"
      ;;
    *)
      case " $DISTRO_ID_LIKE " in
        *" debian "*) DISTRO_FAMILY="debian" ;;
        *" rhel "*|*" fedora "*) DISTRO_FAMILY="rhel" ;;
        *" arch "*) DISTRO_FAMILY="arch" ;;
        *" alpine "*) DISTRO_FAMILY="alpine" ;;
        *) DISTRO_FAMILY="generic" ;;
      esac
      ;;
  esac

  DETECTED_PLATFORM="$DISTRO_NAME"
}

detect_freebsd() {
  DISTRO_FAMILY="freebsd"
  freebsd_version="$(uname -r 2>/dev/null || printf '%s' unknown)"
  version_text=""

  if [ -f /etc/version ]; then
    version_text="$(cat /etc/version 2>/dev/null || true)"
    if printf '%s' "$version_text" | grep -Eiq 'truenas|freenas'; then
      IS_TRUENAS=1
    fi
  fi

  if uname -a 2>/dev/null | grep -Eiq 'truenas|freenas'; then
    IS_TRUENAS=1
  fi

  if sysctl -n kern.version 2>/dev/null | grep -Eiq 'truenas|freenas'; then
    IS_TRUENAS=1
  fi

  if [ -d /usr/local/www/freenasUI ] || [ -d /usr/local/www/truenas ] || [ -f /data/freenas-v1.db ]; then
    IS_TRUENAS=1
  fi

  if [ "$IS_TRUENAS" -eq 1 ]; then
    if [ -n "$version_text" ]; then
      DETECTED_PLATFORM="TrueNAS CORE ($version_text)"
    else
      DETECTED_PLATFORM="TrueNAS CORE / FreeBSD $freebsd_version"
    fi
  else
    DETECTED_PLATFORM="FreeBSD $freebsd_version"
  fi
}

print_truenas_caution() {
  if [ "$IS_TRUENAS" -ne 1 ]; then
    return
  fi
  log "TrueNAS CORE note:"
  log "  Persistent custom services can vary by host, jail, and TrueNAS release."
  log "  Prefer running this inside a FreeBSD jail if the jail can access the required temperature sensor."
  log "  If the jail cannot read host CPU temperature, use a host-level service carefully or set a different sensor command."
}

dry_run_plan() {
  log "$INSTALLER_NAME dry run"
  log "Detected platform: $DETECTED_PLATFORM"
  log "Thermo URL: $THERMO_URL"
  log "Pairing token: $(redacted_token)"
  log "Install directory: $INSTALL_DIR"
  log "Environment file: $ENV_FILE"
  log "Registration retry file: $REGISTRATION_FILE"
  log "Service file: $SERVICE_FILE"
  log "No files were changed."
}

uninstall_agent() {
  require_root
  if [ "$DRY_RUN" -eq 1 ]; then
    log "$INSTALLER_NAME uninstall dry run"
    log "Would stop and disable $SERVICE_NAME"
    log "Would remove $SERVICE_FILE"
    log "Would remove $INSTALL_DIR"
    log "Would remove $ENV_FILE"
    log "Would remove $REGISTRATION_FILE"
    return
  fi

  log "Stopping Thermo agent service..."
  if [ "$OS_KIND" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  elif [ "$OS_KIND" = "freebsd" ] && command -v service >/dev/null 2>&1; then
    service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    if command -v sysrc >/dev/null 2>&1; then
      sysrc "${SERVICE_NAME}_enable=NO" >/dev/null 2>&1 || true
    fi
  fi

  log "Removing Thermo agent files..."
  rm -f "$SERVICE_FILE"
  rm -rf "$INSTALL_DIR"
  rm -f "$ENV_FILE"
  rm -f "$REGISTRATION_FILE"

  if [ "$OS_KIND" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
  fi

  log "Thermo agent uninstalled."
}

have_http_client() {
  command -v curl >/dev/null 2>&1 || command -v fetch >/dev/null 2>&1
}

ensure_python_for_bootstrap() {
  if command -v python3 >/dev/null 2>&1 && have_http_client; then
    return
  fi
  install_dependencies
}

install_dependencies() {
  if [ "$DEPS_INSTALLED" -eq 1 ]; then
    return
  fi

  case "$DISTRO_FAMILY" in
    debian)
      command -v apt-get >/dev/null 2>&1 || fail "apt-get is required on Debian/Ubuntu/Proxmox."
      log "Installing dependencies with apt..."
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv curl ca-certificates tar lm-sensors
      run_sensors_detect
      ;;
    rhel)
      log "Installing dependencies with dnf/yum..."
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 python3-pip python3-virtualenv curl ca-certificates tar lm_sensors
      elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 python3-pip python3-virtualenv curl ca-certificates tar lm_sensors
      else
        fail "dnf or yum is required on RHEL/Fedora-family systems."
      fi
      run_sensors_detect
      ;;
    arch)
      command -v pacman >/dev/null 2>&1 || fail "pacman is required on Arch-family systems."
      log "Installing dependencies with pacman..."
      pacman -Sy --noconfirm python curl ca-certificates tar lm_sensors
      run_sensors_detect
      ;;
    alpine)
      command -v apk >/dev/null 2>&1 || fail "apk is required on Alpine."
      log "Installing dependencies with apk..."
      apk add --no-cache python3 py3-pip py3-virtualenv curl ca-certificates tar lm-sensors
      run_sensors_detect
      ;;
    freebsd)
      install_freebsd_dependencies
      ;;
    *)
      fail "Unsupported Linux distribution. Install python3, python3-venv, curl or fetch, ca-certificates, tar, and lm-sensors manually, then rerun."
      ;;
  esac

  command -v python3 >/dev/null 2>&1 || fail "python3 is required but was not found after dependency installation."
  have_http_client || fail "curl or fetch is required but was not found after dependency installation."
  DEPS_INSTALLED=1
}

install_freebsd_dependencies() {
  if ! command -v pkg >/dev/null 2>&1; then
    command -v python3 >/dev/null 2>&1 || fail "python3 is required. Install it with pkg or run inside a prepared jail."
    have_http_client || fail "curl or fetch is required. Install curl or use the base fetch tool."
    return
  fi

  log "Installing FreeBSD dependencies with pkg..."
  pkg install -y python3 ca_root_nss curl gtar || pkg install -y python3 ca_root_nss curl || fail "pkg could not install required FreeBSD dependencies."

  if ! python3 -m pip --version >/dev/null 2>&1; then
    pkg install -y py312-pip >/dev/null 2>&1 || \
      pkg install -y py311-pip >/dev/null 2>&1 || \
      pkg install -y py310-pip >/dev/null 2>&1 || true
  fi
}

run_sensors_detect() {
  if ! command -v sensors-detect >/dev/null 2>&1; then
    return
  fi

  log "Running sensors-detect non-interactively where supported..."
  if sensors-detect --help 2>&1 | grep -q -- "--auto"; then
    sensors-detect --auto >/dev/null 2>&1 || log "sensors-detect --auto did not complete; continuing."
    return
  fi

  log "Skipping sensors-detect because this version has no --auto option and may prompt interactively."
}

http_get() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
    return
  fi
  if command -v fetch >/dev/null 2>&1; then
    fetch -q -o - "$url"
    return
  fi
  fail "curl or fetch is required."
}

download_file() {
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
  fail "curl or fetch is required."
}

fetch_bootstrap() {
  log "Fetching bootstrap configuration from Thermo..."
  BOOTSTRAP_JSON="$(http_get "$THERMO_URL/api/setup/bootstrap?token=$PAIRING_TOKEN")" || fail "Bootstrap request failed. Check the Thermo URL and pairing token."
}

parse_bootstrap() {
  parsed="$(
    BOOTSTRAP_JSON="$BOOTSTRAP_JSON" python3 - <<'PY'
import json
import os
import shlex

try:
    payload = json.loads(os.environ["BOOTSTRAP_JSON"])
except Exception as exc:
    raise SystemExit(f"invalid bootstrap JSON: {exc}")

def emit(name, value):
    if value is None:
        value = ""
    print(f"{name}={shlex.quote(str(value))}")

emit("SERVER_NAME", payload.get("server_name", ""))
emit("BOOTSTRAP_PLATFORM", payload.get("platform", ""))
emit("BOOTSTRAP_BIND_HOST", payload.get("bind_host", "0.0.0.0"))
emit("BOOTSTRAP_AGENT_PORT", payload.get("agent_port", "8090"))
emit("CENTRAL_URL", payload.get("central_url", ""))
emit("AGENT_API_KEY", payload.get("agent_api_key", ""))
emit("SOURCE_TARBALL_URL", payload.get("source_tarbball_url") or payload.get("source_tarball_url") or "")
emit("TEMPERATURE_COMMAND_HINT", payload.get("temperature_command_hint", ""))
PY
  )" || fail "Could not parse bootstrap configuration."

  eval "$parsed"

  [ -n "$AGENT_API_KEY" ] || fail "Bootstrap response did not include an agent API key."
  [ -n "$SOURCE_TARBALL_URL" ] || SOURCE_TARBALL_URL="$DEFAULT_SOURCE_TARBALL_URL"

  if [ -n "$OVERRIDE_BIND_HOST" ]; then
    BIND_HOST="$OVERRIDE_BIND_HOST"
  else
    BIND_HOST="${BOOTSTRAP_BIND_HOST:-$DEFAULT_BIND_HOST}"
  fi

  if [ -n "$OVERRIDE_PORT" ]; then
    AGENT_PORT="$OVERRIDE_PORT"
  else
    AGENT_PORT="${BOOTSTRAP_AGENT_PORT:-$DEFAULT_PORT}"
  fi

  validate_port "$AGENT_PORT" || fail "--port must be a number between 1 and 65535."
  validate_bind_host "$BIND_HOST" || fail "--bind-host must be a host or IP without spaces, slashes, or URL scheme."
}

temperature_extract() {
  printf "%s" "grep -oE '[+-]?[0-9]+(\\.[0-9]+)?°C' | head -n1 | tr -d '+°C'"
}

command_temperature_value() {
  candidate="$1"
  sh -c "$candidate" 2>/dev/null | awk '/^-?[0-9]+([.][0-9]+)?$/ {print; exit}'
}

detect_temperature_command() {
  if [ "$OS_KIND" = "freebsd" ]; then
    choose_freebsd_temperature_command
  else
    choose_linux_temperature_command
  fi
}

choose_temperature_command() {
  detect_temperature_command
}

try_temperature_candidate() {
  label="$1"
  candidate="$2"
  [ -n "$candidate" ] || return 1

  value="$(command_temperature_value "$candidate" || true)"
  if [ -n "$value" ]; then
    TEMP_COMMAND="$candidate"
    TEMP_COMMAND_LABEL="$label"
    log "Selected temperature command: $TEMP_COMMAND_LABEL"
    debug_log "Temperature test value: $value"
    return 0
  fi
  debug_log "Temperature command candidate did not return a number: $label"
  return 1
}

choose_linux_temperature_command() {
  extractor="$(temperature_extract)"
  primary="sensors | awk '/Package id 0|Tctl|CPU/ {print \$0; exit}' | $extractor"
  generic="sensors | grep -oE '[+-]?[0-9]+(\\.[0-9]+)?°C' | head -n1 | tr -d '+°C'"
  alt_k10temp="sensors | awk '/Tctl/ {print \$0; exit}' | $extractor"
  alt_coretemp="sensors | awk '/Package id/ {print \$0; exit}' | $extractor"
  alt_acpitz="sensors | awk '/acpitz|temp1/ {print \$0; exit}' | $extractor"

  command -v sensors >/dev/null 2>&1 || fail "lm-sensors is installed, but the sensors command was not found."

  try_temperature_candidate "CPU package / Tctl / CPU" "$primary" && return
  try_temperature_candidate "Generic first Celsius reading" "$generic" && return
  try_temperature_candidate "k10temp Tctl" "$alt_k10temp" && return
  try_temperature_candidate "coretemp Package id" "$alt_coretemp" && return
  try_temperature_candidate "acpitz temp1" "$alt_acpitz" && return
  try_temperature_candidate "Bootstrap temperature hint" "$TEMPERATURE_COMMAND_HINT" && return

  print_sensors_output
  fail "Could not detect a working temperature command. Run 'sensors' and set THERMO_TEMP_COMMAND manually if your hardware uses a different sensor label."
}

choose_freebsd_temperature_command() {
  command="sysctl -n dev.cpu.0.temperature | sed 's/C//'"
  if command_temperature_value "$command" >/dev/null 2>&1 && [ -n "$(command_temperature_value "$command")" ]; then
    TEMP_COMMAND="$command"
    TEMP_COMMAND_LABEL="FreeBSD dev.cpu.0.temperature"
    log "Selected temperature command: $TEMP_COMMAND_LABEL"
    return
  fi

  fail "FreeBSD CPU temperature sysctl dev.cpu.0.temperature is unavailable. Run: sysctl -a | grep -i temperature. If this is a jail, it may not be able to read host CPU temperature; use a host-level service carefully or set a different sensor command."
}

print_sensors_output() {
  if ! command -v sensors >/dev/null 2>&1; then
    return
  fi
  log "Current sensors output:"
  sensors 2>&1 || true
}

verify_env_temperature_command() {
  log "Verifying selected temperature command before starting the service..."
  value="$(command_temperature_value "$TEMP_COMMAND" || true)"
  if [ -z "$value" ]; then
    print_sensors_output
    fail "Selected temperature command did not return a numeric value. Service was not started."
  fi
  debug_log "Selected command returned $value"
}

tar_command() {
  if command -v tar >/dev/null 2>&1; then
    printf '%s' "tar"
    return
  fi
  if command -v gtar >/dev/null 2>&1; then
    printf '%s' "gtar"
    return
  fi
  fail "tar or gtar is required."
}

install_agent_files() {
  TMP_DIR="$(mktemp -d)"
  log "Downloading Thermo source tarball..."
  download_file "$SOURCE_TARBALL_URL" "$TMP_DIR/thermo.tar.gz"

  mkdir -p "$TMP_DIR/src"
  tar_bin="$(tar_command)"
  "$tar_bin" -xzf "$TMP_DIR/thermo.tar.gz" -C "$TMP_DIR/src"

  set -- "$TMP_DIR"/src/*
  src_root="$1"
  [ -d "$src_root/agent" ] || fail "Downloaded source tarball does not contain agent/."

  log "Installing agent files into $INSTALL_DIR..."
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/agent"
  cp -R "$src_root/agent" "$INSTALL_DIR/agent"
  chown -R "$(owner_group)" "$INSTALL_DIR"
}

create_python_env() {
  log "Creating Python environment..."
  if python3 -m venv "$INSTALL_DIR/.venv" >/dev/null 2>&1; then
    "$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
    "$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/agent/requirements.txt"
    return
  fi

  if [ "$OS_KIND" != "freebsd" ]; then
    fail "python3 venv failed. Install python3-venv or equivalent and rerun."
  fi

  log "python3 venv is unavailable; installing Python dependencies into $INSTALL_DIR/python."
  log "This is less isolated than a venv, but stays contained under the Thermo agent directory."
  if ! python3 -m pip --version >/dev/null 2>&1; then
    fail "FreeBSD venv and pip are unavailable. Install Python venv support or py3*-pip, then rerun."
  fi
  PYTHONPATH_DIR="$INSTALL_DIR/python"
  rm -rf "$PYTHONPATH_DIR"
  mkdir -p "$PYTHONPATH_DIR"
  python3 -m pip install -r "$INSTALL_DIR/agent/requirements.txt" --target "$PYTHONPATH_DIR"
  chown -R "$(owner_group)" "$PYTHONPATH_DIR"
}

write_env_file() {
  log "Writing $ENV_FILE..."
  mkdir -p "$(dirname "$ENV_FILE")"
  api_key_quoted="$(shell_quote "$AGENT_API_KEY")"
  temp_command_quoted="$(shell_quote "$TEMP_COMMAND")"

  umask 077
  cat >"$ENV_FILE" <<EOF
THERMO_AGENT_API_KEY=$api_key_quoted
THERMO_TEMP_COMMAND=$temp_command_quoted
THERMO_TEMP_TIMEOUT_SECONDS='3'
EOF
  chown "$(owner_group)" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

write_registration_retry_files() {
  log "Preparing local retry registration command..."
  mkdir -p "$(dirname "$REGISTRATION_FILE")"
  thermo_url_quoted="$(shell_quote "$THERMO_URL")"
  token_quoted="$(shell_quote "$PAIRING_TOKEN")"
  port_quoted="$(shell_quote "$AGENT_PORT")"
  bind_host_quoted="$(shell_quote "$BIND_HOST")"
  platform_quoted="$(shell_quote "$DETECTED_PLATFORM")"

  umask 077
  cat >"$REGISTRATION_FILE" <<EOF
THERMO_SETUP_URL=$thermo_url_quoted
THERMO_PAIRING_TOKEN=$token_quoted
THERMO_AGENT_PORT=$port_quoted
THERMO_AGENT_BIND_HOST=$bind_host_quoted
THERMO_DETECTED_PLATFORM=$platform_quoted
EOF
  chown "$(owner_group)" "$REGISTRATION_FILE"
  chmod 600 "$REGISTRATION_FILE"

  cat >"$INSTALL_DIR/retry-registration.sh" <<EOF
#!/bin/sh
set -eu

ENV_FILE="$ENV_FILE"
REGISTRATION_FILE="$REGISTRATION_FILE"

[ -f "\$ENV_FILE" ] || { printf '%s\n' "ERROR: Missing \$ENV_FILE" >&2; exit 1; }
[ -f "\$REGISTRATION_FILE" ] || { printf '%s\n' "ERROR: Missing \$REGISTRATION_FILE" >&2; exit 1; }

. "\$ENV_FILE"
. "\$REGISTRATION_FILE"

test_url() {
  url="\$1"
  header="\$2"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "\$header" ]; then
      curl -fsS -H "\$header" "\$url"
    else
      curl -fsS "\$url"
    fi
    return
  fi
  if command -v fetch >/dev/null 2>&1; then
    if [ -n "\$header" ]; then
      fetch -q -o - --header "\$header" "\$url"
    else
      fetch -q -o - "\$url"
    fi
    return
  fi
  printf '%s\n' "ERROR: curl or fetch is required." >&2
  exit 1
}

detect_ip() {
  detected_ip=""
  os_name="\$(uname -s)"
  if [ "\$os_name" = "FreeBSD" ]; then
    iface="\$(route -n get default 2>/dev/null | awk '/interface:/ {print \$2; exit}')"
    if [ -n "\$iface" ]; then
      detected_ip="\$(ifconfig "\$iface" 2>/dev/null | awk '/inet / && \$2 != "127.0.0.1" {print \$2; exit}')"
    fi
  else
    detected_ip="\$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if (\$i == "src") {print \$(i + 1); exit}}')"
    if [ -z "\$detected_ip" ]; then
      detected_ip="\$(hostname -I 2>/dev/null | awk '{print \$1}')"
    fi
  fi
  if [ -z "\$detected_ip" ]; then
    if [ "\$THERMO_AGENT_BIND_HOST" != "0.0.0.0" ]; then
      detected_ip="\$THERMO_AGENT_BIND_HOST"
    else
      detected_ip="127.0.0.1"
    fi
  fi
  printf '%s' "\$detected_ip"
}

printf '%s\n' "Testing local Thermo agent..."
health_url="http://127.0.0.1:\$THERMO_AGENT_PORT/health"
temp_url="http://127.0.0.1:\$THERMO_AGENT_PORT/temperature"
if ! test_url "\$health_url" "" >/dev/null 2>&1; then
  if [ "\$THERMO_AGENT_BIND_HOST" != "0.0.0.0" ] && [ "\$THERMO_AGENT_BIND_HOST" != "127.0.0.1" ]; then
    health_url="http://\$THERMO_AGENT_BIND_HOST:\$THERMO_AGENT_PORT/health"
    temp_url="http://\$THERMO_AGENT_BIND_HOST:\$THERMO_AGENT_PORT/temperature"
    test_url "\$health_url" "" >/dev/null
  else
    printf '%s\n' "ERROR: Agent /health check failed." >&2
    exit 1
  fi
fi

temp_json="\$(test_url "\$temp_url" "X-API-Key: \$THERMO_AGENT_API_KEY")"
test_temperature="\$(TEMP_JSON="\$temp_json" python3 - <<'PY'
import json
import math
import os

payload = json.loads(os.environ["TEMP_JSON"])
temperature = float(payload["temperature"])
if not math.isfinite(temperature):
    raise SystemExit("temperature was not finite")
print(temperature)
PY
)"

detected_hostname="\$(hostname 2>/dev/null || printf '%s' unknown)"
detected_ip="\$(detect_ip)"
agent_url="http://\$detected_ip:\$THERMO_AGENT_PORT/temperature"

printf '%s\n' "Completing Thermo setup registration..."
TOKEN="\$THERMO_PAIRING_TOKEN" THERMO_URL="\$THERMO_SETUP_URL" AGENT_URL="\$agent_url" DETECTED_HOSTNAME="\$detected_hostname" DETECTED_PLATFORM="\$THERMO_DETECTED_PLATFORM" DETECTED_IP="\$detected_ip" TEST_TEMPERATURE="\$test_temperature" python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

payload = {
    "token": os.environ["TOKEN"],
    "agent_url": os.environ["AGENT_URL"],
    "detected_hostname": os.environ.get("DETECTED_HOSTNAME", ""),
    "detected_platform": os.environ.get("DETECTED_PLATFORM", ""),
    "detected_ip": os.environ.get("DETECTED_IP", ""),
    "temperature": os.environ.get("TEST_TEMPERATURE", ""),
}
request = urllib.request.Request(
    os.environ["THERMO_URL"].rstrip("/") + "/api/setup/complete",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json", "Accept": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        response.read()
except urllib.error.HTTPError as exc:
    sys.stderr.write(exc.read().decode("utf-8", "replace") + "\n")
    raise
PY

rm -f "\$REGISTRATION_FILE" "$INSTALL_DIR/retry-registration.sh"
printf '%s\n' "Thermo registration completed."
EOF
  chown "$(owner_group)" "$INSTALL_DIR/retry-registration.sh"
  chmod 700 "$INSTALL_DIR/retry-registration.sh"
}

remove_registration_retry_files() {
  rm -f "$REGISTRATION_FILE" "$INSTALL_DIR/retry-registration.sh"
}

print_registration_failure_help() {
  log "Thermo setup registration failed after the agent service was installed."
  log "The agent was left installed so you can inspect and retry before the pairing token expires."
  print_redacted_env_summary
  print_service_logs
  if [ "$OS_KIND" = "freebsd" ]; then
    log "Service status: service $SERVICE_NAME status"
    log "Retry registration: $INSTALL_DIR/retry-registration.sh"
  else
    log "Service status: systemctl status $SERVICE_NAME"
    log "Logs: journalctl -u $SERVICE_NAME -n 80 --no-pager"
    log "Retry registration: sudo $INSTALL_DIR/retry-registration.sh"
  fi
}

create_service() {
  if [ "$OS_KIND" = "freebsd" ]; then
    create_freebsd_service
  else
    create_systemd_service
  fi
}

create_systemd_service() {
  command -v systemctl >/dev/null 2>&1 || fail "systemctl was not found. This installer currently requires systemd on Linux."

  log "Creating systemd service..."
  cat >"$SERVICE_FILE" <<EOF
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

  chown "$(owner_group)" "$SERVICE_FILE"
  chmod 644 "$SERVICE_FILE"
}

create_freebsd_service() {
  [ -f /etc/rc.subr ] || fail "/etc/rc.subr was not found; cannot create a FreeBSD rc.d service."
  command -v daemon >/dev/null 2>&1 || fail "daemon was not found; cannot create a FreeBSD rc.d service."

  log "Creating FreeBSD run script..."
  cat >"$INSTALL_DIR/run-agent.sh" <<EOF
#!/bin/sh
set -eu
. "$ENV_FILE"
export THERMO_AGENT_API_KEY THERMO_TEMP_COMMAND THERMO_TEMP_TIMEOUT_SECONDS
cd "$INSTALL_DIR"
if [ -d "$INSTALL_DIR/python" ]; then
  export PYTHONPATH="$INSTALL_DIR/python\${PYTHONPATH:+:\$PYTHONPATH}"
  exec python3 -m uvicorn agent.main:app --host "$BIND_HOST" --port "$AGENT_PORT"
fi
exec "$INSTALL_DIR/.venv/bin/uvicorn" agent.main:app --host "$BIND_HOST" --port "$AGENT_PORT"
EOF
  chown "$(owner_group)" "$INSTALL_DIR/run-agent.sh"
  chmod 700 "$INSTALL_DIR/run-agent.sh"

  log "Creating FreeBSD rc.d service..."
  cat >"$SERVICE_FILE" <<EOF
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
  chown "$(owner_group)" "$SERVICE_FILE"
  chmod 755 "$SERVICE_FILE"
}

start_service() {
  if [ "$OS_KIND" = "freebsd" ]; then
    start_freebsd_service
  else
    start_systemd_service
  fi
}

start_systemd_service() {
  log "Enabling and starting $SERVICE_NAME..."
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
}

start_freebsd_service() {
  command -v sysrc >/dev/null 2>&1 || fail "sysrc was not found; cannot enable the FreeBSD service."
  command -v service >/dev/null 2>&1 || fail "service was not found; cannot start the FreeBSD service."

  log "Enabling and starting $SERVICE_NAME..."
  sysrc thermo_agent_enable=YES >/dev/null
  if service "$SERVICE_NAME" status >/dev/null 2>&1; then
    service_action="restart"
  else
    service_action="start"
  fi
  if ! service "$SERVICE_NAME" "$service_action"; then
    print_truenas_caution
    fail "Could not start the FreeBSD rc.d service. Review /var/log/messages and the TrueNAS jail/host service policy."
  fi
}

test_url() {
  url="$1"
  header="$2"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$header" ]; then
      curl -fsS -H "$header" "$url"
    else
      curl -fsS "$url"
    fi
    return
  fi
  if command -v fetch >/dev/null 2>&1; then
    if [ -n "$header" ]; then
      fetch -q -o - --header "$header" "$url"
    else
      fetch -q -o - "$url"
    fi
    return
  fi
  fail "curl or fetch is required."
}

test_url_body() {
  url="$1"
  header="$2"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$header" ]; then
      curl -sS -H "$header" "$url"
    else
      curl -sS "$url"
    fi
    return
  fi
  if command -v fetch >/dev/null 2>&1; then
    if [ -n "$header" ]; then
      fetch -q -o - --header "$header" "$url"
    else
      fetch -q -o - "$url"
    fi
    return
  fi
  fail "curl or fetch is required."
}

print_redacted_env_summary() {
  log "Thermo agent config summary:"
  log "  Env file: $ENV_FILE"
  log "  Install directory: $INSTALL_DIR"
  log "  Bind host: $BIND_HOST"
  log "  Port: $AGENT_PORT"
  log "  Temperature command: ${TEMP_COMMAND_LABEL:-custom/unknown}"
  log "  API key: stored in $ENV_FILE (redacted)"
}

print_service_logs() {
  if [ "$OS_KIND" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
    log "systemctl status $SERVICE_NAME:"
    systemctl status "$SERVICE_NAME" --no-pager -l || true
    if command -v journalctl >/dev/null 2>&1; then
      log "Recent journal logs for $SERVICE_NAME:"
      journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
    fi
    return
  fi

  if [ "$OS_KIND" = "freebsd" ] && command -v service >/dev/null 2>&1; then
    log "service $SERVICE_NAME status:"
    service "$SERVICE_NAME" status || true
    if [ "$DEBUG" -eq 1 ] && [ -f /var/log/messages ]; then
      log "Recent /var/log/messages lines:"
      tail -n 80 /var/log/messages || true
    fi
  fi
}

print_agent_diagnostics() {
  print_redacted_env_summary
  print_service_logs
}

test_agent() {
  log "Testing local agent endpoints..."
  health_url="http://127.0.0.1:$AGENT_PORT/health"
  temp_url="http://127.0.0.1:$AGENT_PORT/temperature"

  if ! test_url "$health_url" "" >/dev/null 2>&1; then
    if [ "$BIND_HOST" != "0.0.0.0" ] && [ "$BIND_HOST" != "127.0.0.1" ]; then
      health_url="http://$BIND_HOST:$AGENT_PORT/health"
      temp_url="http://$BIND_HOST:$AGENT_PORT/temperature"
      if ! test_url "$health_url" "" >/dev/null 2>&1; then
        print_agent_diagnostics
        fail "Agent /health check failed."
      fi
    else
      print_agent_diagnostics
      fail "Agent /health check failed."
    fi
  fi

  if ! temp_json="$(test_url_body "$temp_url" "X-API-Key: $AGENT_API_KEY" 2>&1)"; then
    log "Agent /temperature response body:"
    log "$temp_json"
    print_agent_diagnostics
    fail "Agent /temperature check failed."
  fi

  if ! TEST_TEMPERATURE="$(
    TEMP_JSON="$temp_json" python3 - <<'PY'
import json
import math
import os

payload = json.loads(os.environ["TEMP_JSON"])
temperature = float(payload["temperature"])
if not math.isfinite(temperature):
    raise SystemExit("temperature was not finite")
print(temperature)
PY
  )"; then
    log "Agent /temperature response body:"
    log "$temp_json"
    print_agent_diagnostics
    fail "Could not parse local agent temperature response."
  fi

  if [ -z "$TEST_TEMPERATURE" ]; then
    log "Agent /temperature response body:"
    log "$temp_json"
    print_agent_diagnostics
    fail "Local agent temperature response did not include a temperature."
  fi
}

detect_primary_ip() {
  DETECTED_HOSTNAME="$(hostname 2>/dev/null || printf '%s' unknown)"

  if [ "$OS_KIND" = "freebsd" ]; then
    iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')"
    if [ -n "$iface" ]; then
      DETECTED_IP="$(ifconfig "$iface" 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
    fi
  else
    DETECTED_IP="$(
      ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
    )"
    if [ -z "$DETECTED_IP" ]; then
      DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
  fi

  if [ -z "$DETECTED_IP" ]; then
    if [ "$BIND_HOST" != "0.0.0.0" ]; then
      DETECTED_IP="$BIND_HOST"
    else
      DETECTED_IP="127.0.0.1"
    fi
  fi
}

complete_registration() {
  agent_url="http://$DETECTED_IP:$AGENT_PORT/temperature"
  log "Completing setup registration with Thermo..."
  TOKEN="$PAIRING_TOKEN" THERMO_URL="$THERMO_URL" AGENT_URL="$agent_url" DETECTED_HOSTNAME="$DETECTED_HOSTNAME" DETECTED_PLATFORM="$DETECTED_PLATFORM" DETECTED_IP="$DETECTED_IP" TEST_TEMPERATURE="$TEST_TEMPERATURE" python3 - <<'PY' >/dev/null
import json
import os
import sys
import urllib.error
import urllib.request

payload = {
    "token": os.environ["TOKEN"],
    "agent_url": os.environ["AGENT_URL"],
    "detected_hostname": os.environ.get("DETECTED_HOSTNAME", ""),
    "detected_platform": os.environ.get("DETECTED_PLATFORM", ""),
    "detected_ip": os.environ.get("DETECTED_IP", ""),
    "temperature": os.environ.get("TEST_TEMPERATURE", ""),
}
request = urllib.request.Request(
    os.environ["THERMO_URL"].rstrip("/") + "/api/setup/complete",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json", "Accept": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        response.read()
except urllib.error.HTTPError as exc:
    sys.stderr.write(exc.read().decode("utf-8", "replace") + "\n")
    raise
PY
}

validate_install_args() {
  [ -n "$THERMO_URL" ] || fail "--thermo-url is required."
  [ -n "$PAIRING_TOKEN" ] || fail "--token is required."
  if [ -n "$OVERRIDE_PORT" ]; then
    validate_port "$OVERRIDE_PORT" || fail "--port must be a number between 1 and 65535."
  fi
  if [ -n "$OVERRIDE_BIND_HOST" ]; then
    validate_bind_host "$OVERRIDE_BIND_HOST" || fail "--bind-host must be a host or IP without spaces, slashes, or URL scheme."
  fi
}

main_install() {
  validate_install_args
  detect_os

  if [ "$DRY_RUN" -eq 1 ]; then
    dry_run_plan
    return
  fi

  require_root
  log "$INSTALLER_NAME"
  log "Detected platform: $DETECTED_PLATFORM"
  print_truenas_caution
  log "Install directory: $INSTALL_DIR"

  ensure_python_for_bootstrap
  install_dependencies
  fetch_bootstrap
  parse_bootstrap
  choose_temperature_command
  install_agent_files
  create_python_env
  write_env_file
  verify_env_temperature_command
  create_service
  start_service
  sleep 2
  test_agent
  detect_primary_ip
  write_registration_retry_files
  if ! complete_registration; then
    print_registration_failure_help
    exit 1
  fi
  remove_registration_retry_files

  log "Thermo agent installed successfully."
  if [ "$OS_KIND" = "freebsd" ]; then
    log "Service status: service $SERVICE_NAME status"
    log "Firewall recommendation: allow agent port $AGENT_PORT only from the central Thermo server."
  else
    log "Service status: systemctl status $SERVICE_NAME"
  fi
  log "Thermo dashboard: ${CENTRAL_URL:-$THERMO_URL}"
}

if [ "$UNINSTALL" -eq 1 ]; then
  detect_os
  uninstall_agent
else
  main_install
fi
