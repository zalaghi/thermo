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

SYNOLOGY_INSTALL_DIR="/volume1/@appdata/thermo-agent"
SYNOLOGY_SERVICE_NAME="thermo-agent"

DEFAULT_PORT="8090"
DEFAULT_BIND_HOST="0.0.0.0"

THERMO_URL=""
PAIRING_TOKEN=""
OVERRIDE_BIND_HOST=""
OVERRIDE_PORT=""
OVERRIDE_INSTALL_DIR=""
DRY_RUN=0
UNINSTALL=0
DEPS_INSTALLED=0
DEBUG=0
ALLOW_CLIENTS=""
ALLOW_CLIENTS_PROVIDED=0
PROTECT_HEALTH=0
RATE_LIMIT_PER_MINUTE="120"

TMP_DIR=""
OS_KIND=""
DISTRO_ID="unknown"
DISTRO_ID_LIKE=""
DISTRO_NAME="Linux"
DISTRO_FAMILY="generic"
IS_PROXMOX=0
IS_TRUENAS=0
IS_SYNOLOGY=0

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
HTTP_STATUS=""
HTTP_BODY=""

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
  install-agent.sh --thermo-url URL --token TOKEN [--bind-host HOST] [--port PORT] [--install-dir PATH] [--allow-client IP_OR_CIDR] [--protect-health] [--rate-limit NUMBER] [--debug] [--dry-run]
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
    --install-dir)
      OVERRIDE_INSTALL_DIR="${2:-}"
      shift 2
      ;;
    --allow-client)
      if [ -z "${2:-}" ]; then
        fail "--allow-client requires an IP address or CIDR."
      fi
      if [ -z "$ALLOW_CLIENTS" ]; then
        ALLOW_CLIENTS="$2"
      else
        ALLOW_CLIENTS="$ALLOW_CLIENTS,$2"
      fi
      ALLOW_CLIENTS_PROVIDED=1
      shift 2
      ;;
    --protect-health)
      PROTECT_HEALTH=1
      shift
      ;;
    --rate-limit)
      RATE_LIMIT_PER_MINUTE="${2:-}"
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

set_synology_paths() {
  if [ -n "$OVERRIDE_INSTALL_DIR" ]; then
    INSTALL_DIR="$OVERRIDE_INSTALL_DIR"
  else
    INSTALL_DIR="$SYNOLOGY_INSTALL_DIR"
  fi
  ENV_FILE="$INSTALL_DIR/thermo-agent.env"
  REGISTRATION_FILE="$INSTALL_DIR/thermo-agent-registration.env"
  SERVICE_FILE="$INSTALL_DIR/synology-task-scheduler-script.sh"
  SERVICE_NAME="$SYNOLOGY_SERVICE_NAME"
}

redacted_token() {
  if [ -z "$PAIRING_TOKEN" ]; then
    printf '%s' "<missing>"
    return
  fi
  printf '%s' "$PAIRING_TOKEN" | awk '{ if (length($0) > 8) print "********" substr($0, length($0)-7); else print "********" }'
}

redacted_secret() {
  value="$1"
  if [ -z "$value" ]; then
    printf '%s' "<missing>"
    return
  fi
  printf '%s' "$value" | awk '{
    if (length($0) > 8) {
      print substr($0, 1, 4) "..." substr($0, length($0)-3)
    } else {
      print "********"
    }
  }'
}

require_root() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return
  fi
  if [ "$(id -u)" -ne 0 ]; then
    if [ "$OS_KIND" = "synology" ]; then
      fail "Run as root, for example through DSM Task Scheduler as root or a root terminal session."
    fi
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

validate_install_dir() {
  value="$1"
  case "$value" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$value" in
    *..*|*";"*|*"|"*|*"&"*|*">"*|*"<"*|*"("*|*")"*|*" "*|*\'*|*\"*|*\\*) return 1 ;;
  esac
  return 0
}

validate_rate_limit() {
  value="$1"
  case "$value" in
    *[!0-9]*|"") return 1 ;;
  esac
  if [ "$value" -lt 1 ]; then
    return 1
  fi
  return 0
}

shell_quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

strip_wrapping_quotes() {
  sed "s/^['\"]//;s/['\"]$//"
}

owner_group() {
  if [ "$OS_KIND" = "freebsd" ]; then
    printf '%s' "root:wheel"
  else
    printf '%s' "root:root"
  fi
}

thermo_url_host() {
  THERMO_URL="$THERMO_URL" python3 - <<'PY'
import os
from urllib.parse import urlparse

print(urlparse(os.environ["THERMO_URL"]).hostname or "")
PY
}

is_ip_literal() {
  value="$1"
  VALUE="$value" python3 - <<'PY'
import ipaddress
import os
import sys

try:
    ipaddress.ip_address(os.environ["VALUE"])
except ValueError:
    sys.exit(1)
PY
}

normalize_allowed_clients() {
  if [ -z "$ALLOW_CLIENTS" ]; then
    return
  fi

  if ! normalized="$(
    ALLOW_CLIENTS="$ALLOW_CLIENTS" python3 - <<'PY'
import ipaddress
import os
import sys

raw_value = os.environ["ALLOW_CLIENTS"]
values = []
for item in raw_value.split(","):
    candidate = item.strip()
    if not candidate:
        continue
    try:
        if "/" in candidate:
            values.append(str(ipaddress.ip_network(candidate, strict=False)))
        else:
            values.append(str(ipaddress.ip_address(candidate)))
    except ValueError:
        sys.stderr.write(f"Invalid --allow-client value: {candidate}\n")
        sys.exit(1)

if not values:
    sys.stderr.write("--allow-client did not include a usable IP address or CIDR.\n")
    sys.exit(1)

print(",".join(values))
PY
  )"; then
    fail "Allowed client entries must be IP addresses or CIDR ranges."
  fi
  ALLOW_CLIENTS="$normalized"
}

configure_agent_security_defaults() {
  if [ "$ALLOW_CLIENTS_PROVIDED" -eq 0 ]; then
    thermo_host="$(thermo_url_host)"
    if [ -n "$thermo_host" ] && is_ip_literal "$thermo_host"; then
      ALLOW_CLIENTS="$thermo_host"
      log "Restricting agent access to Thermo server IP: $ALLOW_CLIENTS"
    else
      log "Warning: Thermo URL host is not an IP address; THERMO_AGENT_ALLOWED_CLIENTS will be empty."
      log "Use --allow-client IP_OR_CIDR to restrict the agent to the central Thermo server."
    fi
  fi

  normalize_allowed_clients
}

protect_health_value() {
  if [ "$PROTECT_HEALTH" -eq 1 ]; then
    printf '%s' "true"
  else
    printf '%s' "false"
  fi
}

agent_health_header() {
  if [ "$PROTECT_HEALTH" -eq 1 ]; then
    printf 'X-API-Key: %s' "$AGENT_API_KEY"
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
        DETECTED_PLATFORM="$os_name (dry run only; installer targets Linux/Proxmox, FreeBSD/TrueNAS, and best-effort Synology DSM)"
        return
      fi
      fail "Unsupported OS: $os_name. This installer supports Linux/Proxmox, FreeBSD/TrueNAS CORE, and best-effort Synology DSM."
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

  if detect_synology; then
    IS_SYNOLOGY=1
    OS_KIND="synology"
    DISTRO_FAMILY="synology"
    set_synology_paths
    return
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

detect_synology() {
  synology_version=""
  if [ -f /etc.defaults/VERSION ]; then
    synology_version="$(sed -n 's/^productversion="*\([^"]*\)"*/\1/p' /etc.defaults/VERSION | head -n 1)"
  fi

  if [ -f /etc.defaults/VERSION ] || [ -f /etc/VERSION ] || [ -f /etc.defaults/synoinfo.conf ] || [ -d /usr/syno ]; then
    if [ -n "$synology_version" ]; then
      DETECTED_PLATFORM="Synology DSM $synology_version"
    else
      DETECTED_PLATFORM="Synology DSM"
    fi
    return 0
  fi

  if uname -a 2>/dev/null | grep -iq synology; then
    DETECTED_PLATFORM="Synology DSM"
    return 0
  fi

  return 1
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

print_synology_caution() {
  if [ "$IS_SYNOLOGY" -ne 1 ]; then
    return
  fi
  log "Synology DSM note:"
  log "  DSM support is best-effort and varies by model and DSM release."
  log "  Recommended path is Container Manager/Docker when available."
  log "  This non-Docker path writes only under $INSTALL_DIR and generates a Task Scheduler boot script."
  log "  If no readable temperature sensor exists, setup will stop before registration."
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
  if [ "$OS_KIND" = "synology" ]; then
    log "Synology Task Scheduler snippet: $SERVICE_FILE"
  fi
  if [ "$ALLOW_CLIENTS_PROVIDED" -eq 1 ]; then
    log "Allowed clients: $ALLOW_CLIENTS"
  else
    log "Allowed clients: auto when --thermo-url uses an IP address"
  fi
  log "Protect health endpoint: $(protect_health_value)"
  log "Rate limit per minute: $RATE_LIMIT_PER_MINUTE"
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
  if [ "$OS_KIND" = "synology" ]; then
    if [ -f "$INSTALL_DIR/thermo-agent.pid" ]; then
      old_pid="$(cat "$INSTALL_DIR/thermo-agent.pid" 2>/dev/null || true)"
      if [ -n "$old_pid" ] && kill -0 "$old_pid" >/dev/null 2>&1; then
        kill "$old_pid" >/dev/null 2>&1 || true
      fi
    fi
  elif [ "$OS_KIND" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
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
  command -v curl >/dev/null 2>&1 || command -v fetch >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
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
    synology)
      install_synology_dependencies
      ;;
    *)
      fail "Unsupported Linux distribution. Install python3, python3-venv, curl/fetch/wget, ca-certificates, tar, and lm-sensors manually, then rerun."
      ;;
  esac

  command -v python3 >/dev/null 2>&1 || fail "python3 is required but was not found after dependency installation."
  have_http_client || fail "curl, fetch, or wget is required but was not found after dependency installation."
  DEPS_INSTALLED=1
}

install_synology_dependencies() {
  log "Checking Synology DSM dependencies..."
  command -v python3 >/dev/null 2>&1 || fail "python3 was not found. Install Python 3 from Synology Package Center or run the Docker/Container Manager path."
  have_http_client || fail "curl or wget was not found. Install curl from Synology Package Center, use a DSM-provided wget, or run the Docker/Container Manager path."
  command -v tar >/dev/null 2>&1 || fail "tar was not found. DSM must provide tar to extract the Thermo source tarball."
  log "Synology DSM note: this installer will not modify DSM system files or firewall rules."
  log "If persistence is blocked by your DSM version, use the generated Task Scheduler script."
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
  if command -v wget >/dev/null 2>&1; then
    wget -q -O - "$url"
    return
  fi
  fail "curl, fetch, or wget is required."
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
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" "$url"
    return
  fi
  fail "curl, fetch, or wget is required."
}

fetch_bootstrap() {
  log "Fetching bootstrap configuration from Thermo..."
  BOOTSTRAP_JSON="$(http_get "$THERMO_URL/api/setup/bootstrap?token=$PAIRING_TOKEN")" || fail "Bootstrap request failed. Check the Thermo URL and pairing token."
}

print_redacted_bootstrap_json() {
  if [ -z "$BOOTSTRAP_JSON" ]; then
    log "<empty bootstrap response>"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    BOOTSTRAP_JSON="$BOOTSTRAP_JSON" python3 - <<'PY' || printf '%s\n' "$BOOTSTRAP_JSON"
import json
import os

body = os.environ.get("BOOTSTRAP_JSON", "")
try:
    payload = json.loads(body)
except Exception:
    print(body)
    raise SystemExit(0)

for key in ("agent_api_key", "token", "pairing_token"):
    if key in payload and payload[key]:
        value = str(payload[key])
        payload[key] = value[:4] + "..." + value[-4:] if len(value) > 8 else "********"
print(json.dumps(payload, sort_keys=True))
PY
    return
  fi

  printf '%s\n' "$BOOTSTRAP_JSON" | sed -E 's/("agent_api_key"[[:space:]]*:[[:space:]]*")[^"]+/\1<redacted>/g'
}

parse_bootstrap() {
  if ! parsed="$(
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
emit("BOOTSTRAP_BIND_HOST", payload.get("bind_host", ""))
emit("BOOTSTRAP_AGENT_PORT", payload.get("agent_port", ""))
emit("CENTRAL_URL", payload.get("central_url", ""))
emit("AGENT_API_KEY", payload.get("agent_api_key", ""))
emit("SOURCE_TARBALL_URL", payload.get("source_tarball_url") or payload.get("source_tarbball_url") or "")
emit("TEMPERATURE_COMMAND_HINT", payload.get("temperature_command_hint", ""))
PY
  )"; then
    log "Bootstrap response body with secrets redacted:"
    print_redacted_bootstrap_json
    fail "Could not parse bootstrap configuration."
  fi

  eval "$parsed"

  if [ -z "$AGENT_API_KEY" ]; then
    log "Bootstrap response body with secrets redacted:"
    print_redacted_bootstrap_json
    fail "Installer bug: missing generated agent API key from bootstrap response."
  fi
  [ -n "$BOOTSTRAP_AGENT_PORT" ] || fail "Bootstrap response did not include an agent port."
  [ -n "$BOOTSTRAP_BIND_HOST" ] || fail "Bootstrap response did not include a bind host."
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
  debug_log "Bootstrap agent key: $(redacted_secret "$AGENT_API_KEY")"
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
  elif [ "$OS_KIND" = "synology" ]; then
    choose_synology_temperature_command
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

choose_synology_temperature_command() {
  thermal_zone0='if [ -r /sys/class/thermal/thermal_zone0/temp ]; then awk '"'"'{printf "%.1f\n", $1 / 1000}'"'"' /sys/class/thermal/thermal_zone0/temp; fi'
  thermal_any='for zone in /sys/class/thermal/thermal_zone*/temp; do [ -r "$zone" ] || continue; awk '"'"'{printf "%.1f\n", $1 / 1000}'"'"' "$zone"; break; done'
  sensors_generic="sensors 2>/dev/null | grep -oE '[+-]?[0-9]+(\\.[0-9]+)?°C' | head -n1 | tr -d '+°C'"

  try_temperature_candidate "Synology thermal_zone0" "$thermal_zone0" && return
  try_temperature_candidate "Synology first readable thermal zone" "$thermal_any" && return
  try_temperature_candidate "Synology sensors output" "$sensors_generic" && return
  try_temperature_candidate "Bootstrap temperature hint" "$TEMPERATURE_COMMAND_HINT" && return

  log "Could not find a readable temperature sensor on this Synology system."
  log "Check available sensors with: ls -l /sys/class/thermal && cat /sys/class/thermal/thermal_zone*/temp"
  log "If your model exposes another command, edit $INSTALL_DIR/read-temperature.sh after installation and rerun setup with a new token."
  fail "Could not find a readable temperature sensor on this Synology system."
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

  if [ "$OS_KIND" != "freebsd" ] && [ "$OS_KIND" != "synology" ]; then
    fail "python3 venv failed. Install python3-venv or equivalent and rerun."
  fi

  log "python3 venv is unavailable; installing Python dependencies into $INSTALL_DIR/python."
  log "This is less isolated than a venv, but stays contained under the Thermo agent directory."
  if ! python3 -m pip --version >/dev/null 2>&1; then
    fail "Python venv and pip are unavailable. Install Python venv support or pip, then rerun."
  fi
  PYTHONPATH_DIR="$INSTALL_DIR/python"
  rm -rf "$PYTHONPATH_DIR"
  mkdir -p "$PYTHONPATH_DIR"
  python3 -m pip install -r "$INSTALL_DIR/agent/requirements.txt" --target "$PYTHONPATH_DIR"
  chown -R "$(owner_group)" "$PYTHONPATH_DIR"
}

validate_agent_api_key() {
  if [ -z "$AGENT_API_KEY" ]; then
    fail "Installer bug: missing generated agent API key from bootstrap response."
  fi
  case "$AGENT_API_KEY" in
    *[!A-Za-z0-9_-]*)
      fail "Installer bug: generated agent API key contains unsupported characters."
      ;;
  esac
}

temperature_command_script_path() {
  printf '%s' "$INSTALL_DIR/read-temperature.sh"
}

write_temperature_command_script() {
  command_script="$(temperature_command_script_path)"
  log "Writing temperature command script $command_script..."
  mkdir -p "$INSTALL_DIR"
  umask 077
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' "$TEMP_COMMAND"
  } >"$command_script"
  chown "$(owner_group)" "$command_script"
  chmod 700 "$command_script"
}

read_agent_api_key_from_env() {
  [ -f "$ENV_FILE" ] || return 1
  sed -n 's/^THERMO_AGENT_API_KEY=//p' "$ENV_FILE" | head -n 1 | strip_wrapping_quotes
}

read_temperature_command_from_env() {
  [ -f "$ENV_FILE" ] || return 1
  sed -n 's/^THERMO_TEMP_COMMAND=//p' "$ENV_FILE" | head -n 1 | strip_wrapping_quotes
}

verify_agent_api_key_env_consistency() {
  env_api_key="$(read_agent_api_key_from_env || true)"
  if [ -z "$env_api_key" ]; then
    fail "Installer bug: THERMO_AGENT_API_KEY was not written to $ENV_FILE."
  fi
  if [ "$env_api_key" != "$AGENT_API_KEY" ]; then
    log "In-memory API key: $(redacted_secret "$AGENT_API_KEY")"
    log "Env-file API key: $(redacted_secret "$env_api_key")"
    fail "Installer bug: generated agent API key does not match $ENV_FILE."
  fi
  debug_log "Verified agent API key in $ENV_FILE: $(redacted_secret "$env_api_key")"
}

verify_agent_env_temperature_command() {
  env_temp_command="$(read_temperature_command_from_env || true)"
  expected_temp_command="$(temperature_command_script_path)"
  if [ -z "$env_temp_command" ]; then
    fail "Installer bug: THERMO_TEMP_COMMAND was not written to $ENV_FILE."
  fi
  if [ "$env_temp_command" != "$expected_temp_command" ]; then
    log "Env-file temperature command: $env_temp_command"
    log "Expected temperature command: $expected_temp_command"
    fail "Installer bug: THERMO_TEMP_COMMAND does not point to the generated command script."
  fi
  if [ ! -x "$env_temp_command" ]; then
    fail "Installer bug: temperature command script is not executable: $env_temp_command"
  fi
  value="$(command_temperature_value "$env_temp_command" || true)"
  if [ -z "$value" ]; then
    print_sensors_output
    fail "Generated temperature command script did not return a numeric value."
  fi
  debug_log "Verified env temperature command script returned $value"
}

write_env_file() {
  log "Writing $ENV_FILE..."
  validate_agent_api_key
  write_temperature_command_script
  mkdir -p "$(dirname "$ENV_FILE")"
  temp_command_path="$(temperature_command_script_path)"

  umask 077
  cat >"$ENV_FILE" <<EOF
THERMO_AGENT_API_KEY=$AGENT_API_KEY
THERMO_TEMP_COMMAND=$temp_command_path
THERMO_TEMP_TIMEOUT_SECONDS=3
THERMO_AGENT_ALLOWED_CLIENTS=$ALLOW_CLIENTS
THERMO_AGENT_PROTECT_HEALTH=$(protect_health_value)
THERMO_AGENT_RATE_LIMIT_PER_MINUTE=$RATE_LIMIT_PER_MINUTE
EOF
  chown "$(owner_group)" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  verify_agent_api_key_env_consistency
  verify_agent_env_temperature_command
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
  if command -v wget >/dev/null 2>&1; then
    if [ -n "\$header" ]; then
      wget -q -O - --header "\$header" "\$url"
    else
      wget -q -O - "\$url"
    fi
    return
  fi
  printf '%s\n' "ERROR: curl, fetch, or wget is required." >&2
  exit 1
}

health_header() {
  case "\${THERMO_AGENT_PROTECT_HEALTH:-false}" in
    1|true|TRUE|yes|YES|on|ON)
      printf 'X-API-Key: %s' "\$THERMO_AGENT_API_KEY"
      ;;
  esac
}

temperature_from_command() {
  sh -c "\$THERMO_TEMP_COMMAND" 2>/dev/null | awk '/^-?[0-9]+([.][0-9]+)?$/ {print; exit}'
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
    if [ -z "\$detected_ip" ] && command -v ifconfig >/dev/null 2>&1; then
      detected_ip="\$(ifconfig 2>/dev/null | awk '/inet / && \$2 != "127.0.0.1" {print \$2; exit}')"
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
if ! test_url "\$health_url" "\$(health_header)" >/dev/null 2>&1; then
  if [ "\$THERMO_AGENT_BIND_HOST" != "0.0.0.0" ] && [ "\$THERMO_AGENT_BIND_HOST" != "127.0.0.1" ]; then
    health_url="http://\$THERMO_AGENT_BIND_HOST:\$THERMO_AGENT_PORT/health"
    temp_url="http://\$THERMO_AGENT_BIND_HOST:\$THERMO_AGENT_PORT/temperature"
    test_url "\$health_url" "\$(health_header)" >/dev/null
  else
    printf '%s\n' "ERROR: Agent /health check failed." >&2
    exit 1
  fi
fi

if temp_json="\$(test_url "\$temp_url" "X-API-Key: \$THERMO_AGENT_API_KEY" 2>/dev/null)"; then
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
else
  if [ -n "\${THERMO_AGENT_ALLOWED_CLIENTS:-}" ]; then
    printf '%s\n' "Local /temperature check was blocked by the agent allowlist; using the local temperature command for registration proof."
    test_temperature="\$(temperature_from_command || true)"
    [ -n "\$test_temperature" ] || { printf '%s\n' "ERROR: Local temperature command did not return a number." >&2; exit 1; }
  else
    printf '%s\n' "ERROR: Agent /temperature check failed." >&2
    exit 1
  fi
fi

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
  if [ "$OS_KIND" = "synology" ]; then
    log "Agent log: $INSTALL_DIR/thermo-agent.log"
    log "Manual start: $SERVICE_FILE"
    log "Retry registration: $INSTALL_DIR/retry-registration.sh"
  elif [ "$OS_KIND" = "freebsd" ]; then
    log "Service status: service $SERVICE_NAME status"
    log "Retry registration: $INSTALL_DIR/retry-registration.sh"
  else
    log "Service status: systemctl status $SERVICE_NAME"
    log "Logs: journalctl -u $SERVICE_NAME -n 80 --no-pager"
    log "Retry registration: sudo $INSTALL_DIR/retry-registration.sh"
  fi
}

create_service() {
  if [ "$OS_KIND" = "synology" ]; then
    create_synology_run_scripts
  elif [ "$OS_KIND" = "freebsd" ]; then
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
export THERMO_AGENT_ALLOWED_CLIENTS THERMO_AGENT_PROTECT_HEALTH THERMO_AGENT_RATE_LIMIT_PER_MINUTE
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

create_synology_run_scripts() {
  log "Creating Synology run script..."
  cat >"$INSTALL_DIR/thermo-agent-run.sh" <<EOF
#!/bin/sh
set -eu
. "$ENV_FILE"
export THERMO_AGENT_API_KEY THERMO_TEMP_COMMAND THERMO_TEMP_TIMEOUT_SECONDS
export THERMO_AGENT_ALLOWED_CLIENTS THERMO_AGENT_PROTECT_HEALTH THERMO_AGENT_RATE_LIMIT_PER_MINUTE
cd "$INSTALL_DIR"
if [ -d "$INSTALL_DIR/python" ]; then
  export PYTHONPATH="$INSTALL_DIR/python\${PYTHONPATH:+:\$PYTHONPATH}"
  exec python3 -m uvicorn agent.main:app --host "$BIND_HOST" --port "$AGENT_PORT"
fi
exec "$INSTALL_DIR/.venv/bin/uvicorn" agent.main:app --host "$BIND_HOST" --port "$AGENT_PORT"
EOF
  chown "$(owner_group)" "$INSTALL_DIR/thermo-agent-run.sh"
  chmod 700 "$INSTALL_DIR/thermo-agent-run.sh"

  log "Creating DSM Task Scheduler script snippet..."
  cat >"$SERVICE_FILE" <<EOF
#!/bin/sh
# Thermo agent DSM Task Scheduler user-defined script.
# Configure this as a triggered task at boot, running as root.
if [ -f "$INSTALL_DIR/thermo-agent.pid" ]; then
  old_pid="\$(cat "$INSTALL_DIR/thermo-agent.pid" 2>/dev/null || true)"
  if [ -n "\$old_pid" ] && kill -0 "\$old_pid" >/dev/null 2>&1; then
    exit 0
  fi
fi
nohup "$INSTALL_DIR/thermo-agent-run.sh" >> "$INSTALL_DIR/thermo-agent.log" 2>&1 &
echo \$! > "$INSTALL_DIR/thermo-agent.pid"
chmod 600 "$INSTALL_DIR/thermo-agent.pid"
EOF
  chown "$(owner_group)" "$SERVICE_FILE"
  chmod 700 "$SERVICE_FILE"
}

start_service() {
  if [ "$OS_KIND" = "synology" ]; then
    start_synology_agent
  elif [ "$OS_KIND" = "freebsd" ]; then
    start_freebsd_service
  else
    start_systemd_service
  fi
}

start_systemd_service() {
  log "Enabling and restarting $SERVICE_NAME..."
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Restarting existing $SERVICE_NAME so it reloads $ENV_FILE..."
    systemctl restart "$SERVICE_NAME"
  else
    systemctl start "$SERVICE_NAME"
  fi
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

start_synology_agent() {
  log "Starting Thermo agent using DSM-compatible run script..."
  if [ -f "$INSTALL_DIR/thermo-agent.pid" ]; then
    old_pid="$(cat "$INSTALL_DIR/thermo-agent.pid" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" >/dev/null 2>&1; then
      kill "$old_pid" >/dev/null 2>&1 || true
      sleep 1
    fi
  fi
  nohup "$INSTALL_DIR/thermo-agent-run.sh" >> "$INSTALL_DIR/thermo-agent.log" 2>&1 &
  echo $! >"$INSTALL_DIR/thermo-agent.pid"
  chown "$(owner_group)" "$INSTALL_DIR/thermo-agent.pid"
  chmod 600 "$INSTALL_DIR/thermo-agent.pid"
  log "If DSM does not keep custom processes after reboot, paste $SERVICE_FILE into DSM Task Scheduler as a boot task."
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
  if command -v wget >/dev/null 2>&1; then
    if [ -n "$header" ]; then
      wget -q -O - --header "$header" "$url"
    else
      wget -q -O - "$url"
    fi
    return
  fi
  fail "curl, fetch, or wget is required."
}

test_url_body() {
  url="$1"
  header="$2"
  response_file="$(mktemp "${TMPDIR:-/tmp}/thermo-agent-response.XXXXXX")"
  status_code=""
  body=""

  if command -v curl >/dev/null 2>&1; then
    if [ -n "$header" ]; then
      status_code="$(curl -sS -o "$response_file" -w "%{http_code}" -H "$header" "$url" || printf '%s' "000")"
    else
      status_code="$(curl -sS -o "$response_file" -w "%{http_code}" "$url" || printf '%s' "000")"
    fi
    body="$(cat "$response_file" 2>/dev/null || true)"
    rm -f "$response_file"
    HTTP_STATUS="$status_code"
    HTTP_BODY="$body"
    return
  fi
  if command -v fetch >/dev/null 2>&1; then
    if [ -n "$header" ]; then
      if fetch -q -o "$response_file" --header "$header" "$url"; then
        status_code="200"
      else
        status_code="000"
      fi
    else
      if fetch -q -o "$response_file" "$url"; then
        status_code="200"
      else
        status_code="000"
      fi
    fi
    body="$(cat "$response_file" 2>/dev/null || true)"
    rm -f "$response_file"
    HTTP_STATUS="$status_code"
    HTTP_BODY="$body"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    if [ -n "$header" ]; then
      if wget -q -O "$response_file" --header "$header" "$url"; then
        status_code="200"
      else
        status_code="000"
      fi
    else
      if wget -q -O "$response_file" "$url"; then
        status_code="200"
      else
        status_code="000"
      fi
    fi
    body="$(cat "$response_file" 2>/dev/null || true)"
    rm -f "$response_file"
    HTTP_STATUS="$status_code"
    HTTP_BODY="$body"
    return
  fi
  rm -f "$response_file"
  fail "curl, fetch, or wget is required."
}

print_redacted_env_summary() {
  log "Thermo agent config summary:"
  log "  Env file: $ENV_FILE"
  log "  Install directory: $INSTALL_DIR"
  log "  Bind host: $BIND_HOST"
  log "  Port: $AGENT_PORT"
  log "  Temperature command: ${TEMP_COMMAND_LABEL:-custom/unknown}"
  if [ -n "$ALLOW_CLIENTS" ]; then
    log "  Allowed clients: $ALLOW_CLIENTS"
  else
    log "  Allowed clients: <not restricted by agent allowlist>"
  fi
  log "  Protected health: $(protect_health_value)"
  log "  Rate limit per minute: $RATE_LIMIT_PER_MINUTE"
  env_api_key="$(read_agent_api_key_from_env 2>/dev/null || true)"
  if [ -n "$env_api_key" ]; then
    log "  API key: $(redacted_secret "$env_api_key")"
  else
    log "  API key: <missing from $ENV_FILE>"
  fi
}

print_redacted_runtime_config() {
  if [ "$OS_KIND" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
    log "systemd service environment with secrets redacted:"
    systemctl show "$SERVICE_NAME" -p Environment 2>/dev/null | \
      sed -E 's/(THERMO_AGENT_API_KEY=)[^[:space:]]+/\1<redacted>/g' || true
  fi

  if [ -f "$ENV_FILE" ]; then
    log "$ENV_FILE with secrets redacted:"
    sed -E 's/^THERMO_AGENT_API_KEY=.*/THERMO_AGENT_API_KEY=<redacted>/' "$ENV_FILE" || true
  fi
}

print_manual_debug_commands() {
  log "Manual debug commands:"
  if [ "$OS_KIND" = "synology" ]; then
    log "  KEY=\"\$(sed -n 's/^THERMO_AGENT_API_KEY=//p' $ENV_FILE | head -n1 | sed \"s/^['\\\"']//;s/['\\\"']$//\")\""
  else
    log "  KEY=\"\$(sudo sed -n 's/^THERMO_AGENT_API_KEY=//p' $ENV_FILE | head -n1 | sed \"s/^['\\\"']//;s/['\\\"']$//\")\""
  fi
  log "  curl -i http://127.0.0.1:$AGENT_PORT/health"
  log "  curl -i -H \"X-API-Key: \$KEY\" http://127.0.0.1:$AGENT_PORT/health"
  log "  curl -i -H \"X-API-Key: \$KEY\" http://127.0.0.1:$AGENT_PORT/temperature"
  if [ "$OS_KIND" = "synology" ]; then
    log "  $SERVICE_FILE"
    log "  tail -n 100 $INSTALL_DIR/thermo-agent.log"
  elif [ "$OS_KIND" = "linux" ]; then
    log "  sudo systemctl status $SERVICE_NAME --no-pager"
    log "  sudo journalctl -u $SERVICE_NAME -n 100 --no-pager"
  else
    log "  service $SERVICE_NAME status"
  fi
}

print_service_logs() {
  if [ "$OS_KIND" = "synology" ]; then
    if [ -f "$INSTALL_DIR/thermo-agent.log" ]; then
      log "Recent Synology agent log:"
      tail -n 80 "$INSTALL_DIR/thermo-agent.log" || true
    fi
    return
  fi

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
  print_redacted_runtime_config
  print_manual_debug_commands
  print_service_logs
}

firewall_source_example() {
  if [ -n "$ALLOW_CLIENTS" ]; then
    first_source="$(printf '%s' "$ALLOW_CLIENTS" | awk -F, '{print $1}')"
    printf '%s' "$first_source"
  else
    printf '%s' "THERMO_IP"
  fi
}

print_firewall_guidance() {
  source_example="$(firewall_source_example)"
  log "Firewall recommendation:"
  log "  The agent requires X-API-Key, but you should still restrict port $AGENT_PORT to the central Thermo server."
  log "  Fedora/firewalld example:"
  log "    sudo firewall-cmd --permanent --add-rich-rule='rule family=\"ipv4\" source address=\"$source_example\" port port=\"$AGENT_PORT\" protocol=\"tcp\" accept'"
  log "    sudo firewall-cmd --reload"
  log "  Debian/Ubuntu UFW example:"
  log "    sudo ufw allow from $source_example to any port $AGENT_PORT proto tcp"
  if [ "$OS_KIND" = "synology" ]; then
    log "  Synology DSM: restrict port $AGENT_PORT to the Thermo server in DSM Firewall manually if enabled."
  fi
  log "  No firewall rules were changed by this installer."
}

test_agent() {
  log "Testing local agent endpoints..."
  if [ -z "$AGENT_API_KEY" ]; then
    fail "Installer bug: missing generated agent API key from bootstrap response."
  fi
  if [ -z "$AGENT_PORT" ]; then
    fail "Installer bug: missing agent port before local test."
  fi
  verify_agent_api_key_env_consistency
  debug_log "Testing /temperature with API key $(redacted_secret "$AGENT_API_KEY")"

  health_url="http://127.0.0.1:$AGENT_PORT/health"
  temp_url="http://127.0.0.1:$AGENT_PORT/temperature"

  if ! test_url "$health_url" "$(agent_health_header)" >/dev/null 2>&1; then
    if [ "$BIND_HOST" != "0.0.0.0" ] && [ "$BIND_HOST" != "127.0.0.1" ]; then
      health_url="http://$BIND_HOST:$AGENT_PORT/health"
      temp_url="http://$BIND_HOST:$AGENT_PORT/temperature"
      if ! test_url "$health_url" "$(agent_health_header)" >/dev/null 2>&1; then
        print_agent_diagnostics
        fail "Agent /health check failed."
      fi
    else
      print_agent_diagnostics
      fail "Agent /health check failed."
    fi
  fi

  test_url_body "$temp_url" "X-API-Key: $AGENT_API_KEY"
  temp_json="$HTTP_BODY"
  if [ "$HTTP_STATUS" = "401" ]; then
    log "Agent rejected the API key during local test."
    log "This means the service did not receive the same THERMO_AGENT_API_KEY that the installer used."
    log "Agent /temperature response body:"
    log "$temp_json"
    print_agent_diagnostics
    fail "Agent /temperature check failed."
  fi
  if [ "$HTTP_STATUS" = "403" ] && [ -n "$ALLOW_CLIENTS" ]; then
    log "Local /temperature check was blocked by the agent allowlist, which is expected when localhost is not allowed."
    log "Thermo will verify the agent from the central server during registration."
    TEST_TEMPERATURE="$(command_temperature_value "$(temperature_command_script_path)" || true)"
    if [ -z "$TEST_TEMPERATURE" ]; then
      print_agent_diagnostics
      fail "Local temperature command did not return a numeric value."
    fi
    return
  fi
  case "$HTTP_STATUS" in
    2??)
      ;;
    *)
      log "Agent /temperature returned HTTP $HTTP_STATUS."
      log "Agent /temperature response body:"
      log "$temp_json"
      print_agent_diagnostics
      fail "Agent /temperature check failed."
      ;;
  esac

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
    if [ -z "$DETECTED_IP" ] && command -v ifconfig >/dev/null 2>&1; then
      DETECTED_IP="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
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
  if [ -n "$OVERRIDE_INSTALL_DIR" ]; then
    validate_install_dir "$OVERRIDE_INSTALL_DIR" || fail "--install-dir must be an absolute path without spaces, traversal, quotes, or shell metacharacters."
  fi
  validate_rate_limit "$RATE_LIMIT_PER_MINUTE" || fail "--rate-limit must be a positive whole number."
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
  print_synology_caution
  log "Install directory: $INSTALL_DIR"

  ensure_python_for_bootstrap
  install_dependencies
  fetch_bootstrap
  parse_bootstrap
  configure_agent_security_defaults
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
  if [ "$OS_KIND" = "synology" ]; then
    log "Manual start / boot script: $SERVICE_FILE"
    log "Agent log: $INSTALL_DIR/thermo-agent.log"
    log "DSM persistence: paste $SERVICE_FILE into Task Scheduler as a boot task if needed."
  elif [ "$OS_KIND" = "freebsd" ]; then
    log "Service status: service $SERVICE_NAME status"
  else
    log "Service status: systemctl status $SERVICE_NAME"
  fi
  print_firewall_guidance
  log "Thermo dashboard: ${CENTRAL_URL:-$THERMO_URL}"
}

if [ "$UNINSTALL" -eq 1 ]; then
  detect_os
  uninstall_agent
else
  main_install
fi
