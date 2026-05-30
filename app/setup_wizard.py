from __future__ import annotations

import hashlib
import math
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional
from urllib.parse import urlparse

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import PairingToken, Server
from .settings import get_settings


DEFAULT_WARNING_THRESHOLD = 65.0
DEFAULT_CRITICAL_THRESHOLD = 80.0
TOKEN_SUFFIX_LENGTH = 8

LINUX_TEMPERATURE_COMMAND_HINT = (
    "sensors | awk '/Package id 0|Tctl|CPU/ {print $0; exit}' | "
    "grep -oE '[+-]?[0-9]+(\\.[0-9]+)?°C' | head -n1 | tr -d '+°C'"
)
FREEBSD_TEMPERATURE_COMMAND_HINT = "sysctl -n dev.cpu.0.temperature | sed 's/C//'"

PLATFORM_CHOICES = [
    ("proxmox", "Proxmox"),
    ("debian_ubuntu", "Debian / Ubuntu"),
    ("generic_systemd_linux", "Generic systemd Linux"),
    ("freebsd", "FreeBSD"),
    ("truenas_core", "TrueNAS CORE"),
    ("other_advanced", "Other / Advanced"),
]
PLATFORM_VALUES = {value for value, _label in PLATFORM_CHOICES}


@dataclass(frozen=True)
class PairingFormValues:
    server_name: str
    platform: str
    thermo_url: str
    bind_host: str
    agent_port: int
    warning_threshold: float
    critical_threshold: float


@dataclass(frozen=True)
class PairingCreationResult:
    pairing: PairingToken
    command: str
    linux_command: str
    freebsd_fetch_command: str
    freebsd_curl_command: str
    raw_token: str


@dataclass(frozen=True)
class PairingStatus:
    label: str
    key: str


def default_pairing_form_data(thermo_url: str) -> dict[str, object]:
    settings = get_settings()
    return {
        "server_name": "",
        "platform": "proxmox",
        "thermo_url": settings.public_url or thermo_url,
        "bind_host": "0.0.0.0",
        "agent_port": str(settings.agent_default_port),
        "warning_threshold": format_threshold(DEFAULT_WARNING_THRESHOLD),
        "critical_threshold": format_threshold(DEFAULT_CRITICAL_THRESHOLD),
    }


def validate_pairing_form(form_data: dict[str, object]) -> tuple[list[str], Optional[PairingFormValues]]:
    errors: list[str] = []
    server_name = str(form_data.get("server_name", "")).strip()
    platform = str(form_data.get("platform", "")).strip()
    thermo_url = str(form_data.get("thermo_url", "")).strip().rstrip("/")
    bind_host = str(form_data.get("bind_host", "")).strip()

    if not thermo_url:
        errors.append("THERMO_PUBLIC_URL must be configured before generating installer commands.")
    if not server_name:
        errors.append("Server name is required.")
    if platform not in PLATFORM_VALUES:
        errors.append("Choose a supported target platform.")
    if thermo_url and not is_valid_http_url(thermo_url):
        errors.append("Thermo URL must start with http:// or https:// and include a host.")
    if not is_valid_bind_host(bind_host):
        errors.append("Bind host must be a LAN IP address or hostname without a URL scheme.")

    agent_port = parse_port(form_data.get("agent_port"), errors)
    warning_threshold = parse_threshold(form_data.get("warning_threshold"), "Warning threshold", errors)
    critical_threshold = parse_threshold(form_data.get("critical_threshold"), "Critical threshold", errors)
    if warning_threshold is not None and critical_threshold is not None:
        if warning_threshold >= critical_threshold:
            errors.append("Warning threshold must be lower than critical threshold.")

    if errors or agent_port is None or warning_threshold is None or critical_threshold is None:
        return errors, None

    return errors, PairingFormValues(
        server_name=server_name,
        platform=platform,
        thermo_url=thermo_url,
        bind_host=bind_host,
        agent_port=agent_port,
        warning_threshold=warning_threshold,
        critical_threshold=critical_threshold,
    )


def create_pairing(session: Session, values: PairingFormValues) -> PairingCreationResult:
    settings = get_settings()
    raw_token = secrets.token_urlsafe(32)
    pairing = PairingToken(
        token_hash=hash_pairing_token(raw_token),
        display_token_suffix=token_suffix(raw_token),
        platform=values.platform,
        server_name=values.server_name,
        bind_host=values.bind_host,
        agent_port=values.agent_port,
        warning_threshold=values.warning_threshold,
        critical_threshold=values.critical_threshold,
        expires_at=utc_now() + timedelta(minutes=settings.pairing_token_ttl_minutes),
    )
    session.add(pairing)
    session.flush()
    linux_command, freebsd_fetch_command, freebsd_curl_command = build_install_commands(
        thermo_url=values.thermo_url,
        raw_token=raw_token,
    )
    return PairingCreationResult(
        pairing=pairing,
        command=linux_command,
        linux_command=linux_command,
        freebsd_fetch_command=freebsd_fetch_command,
        freebsd_curl_command=freebsd_curl_command,
        raw_token=raw_token,
    )


def build_install_command(values: PairingFormValues, raw_token: str) -> str:
    linux_command, _freebsd_fetch_command, _freebsd_curl_command = build_install_commands(
        thermo_url=values.thermo_url,
        raw_token=raw_token,
    )
    return linux_command


def build_install_commands(thermo_url: str, raw_token: str) -> tuple[str, str, str]:
    settings = get_settings()
    script_url = shell_double_quote(settings.agent_install_script_url)
    quoted_thermo_url = shell_double_quote(thermo_url)
    quoted_token = shell_double_quote(raw_token)
    args = f'--thermo-url {quoted_thermo_url} --token {quoted_token}'
    return (
        f"curl -fsSL {script_url} | sudo sh -s -- {args}",
        f"fetch -o - {script_url} | sh -s -- {args}",
        f"curl -fsSL {script_url} | sh -s -- {args}",
    )


def shell_double_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
    return f'"{escaped}"'


def list_active_pairings(session: Session) -> list[PairingToken]:
    pairings = list(
        session.scalars(
            select(PairingToken)
            .where(PairingToken.used_at.is_(None))
            .where(PairingToken.revoked_at.is_(None))
            .order_by(PairingToken.created_at.desc())
        )
    )
    return [pairing for pairing in pairings if not is_expired(pairing.expires_at)]


def revoke_pairing(session: Session, pairing_id: int) -> Optional[PairingToken]:
    pairing = session.get(PairingToken, pairing_id)
    if pairing and pairing.used_at is None and pairing.revoked_at is None:
        pairing.revoked_at = utc_now()
    return pairing


def pairing_status(pairing: PairingToken) -> PairingStatus:
    if pairing.completed_at is not None or pairing.created_server_id is not None:
        return PairingStatus(label="Completed", key="completed")
    if pairing.revoked_at is not None:
        return PairingStatus(label="Revoked", key="revoked")
    if is_expired(pairing.expires_at):
        return PairingStatus(label="Expired", key="expired")
    if pairing.last_error:
        return PairingStatus(label="Failed", key="failed")
    return PairingStatus(label="Waiting", key="waiting")


def pairing_status_payload(pairing: PairingToken) -> dict[str, object]:
    status = pairing_status(pairing)
    return {
        "id": pairing.id,
        "server_name": pairing.server_name,
        "status": status.key,
        "status_label": status.label,
        "status_key": status.key,
        "completed": status.key == "completed",
        "revoked": status.key == "revoked",
        "expired": status.key == "expired",
        "failed": status.key == "failed",
        "waiting": status.key == "waiting",
        "token_suffix": pairing.display_token_suffix,
        "expires_at": format_datetime(pairing.expires_at),
        "completed_at": format_datetime(pairing.completed_at),
        "server_id": pairing.created_server_id,
        "created_server_id": pairing.created_server_id,
        "server_edit_url": f"/admin/servers/{pairing.created_server_id}/edit" if pairing.created_server_id else None,
        "dashboard_url": "/",
        "last_error": pairing.last_error,
        "detected_hostname": pairing.detected_hostname,
        "detected_platform": pairing.detected_platform,
        "detected_ip": pairing.detected_ip,
        "can_revoke": pairing.used_at is None and pairing.revoked_at is None and not is_expired(pairing.expires_at),
    }


def bootstrap_pairing(session: Session, raw_token: str, central_url: str) -> dict[str, object]:
    settings = get_settings()
    pairing = get_valid_pairing(session=session, raw_token=raw_token)
    if not pairing.generated_agent_api_key_encrypted_or_temporary:
        pairing.generated_agent_api_key_encrypted_or_temporary = secrets.token_urlsafe(32)
    pairing.last_error = None

    source_tarball_url = settings.agent_source_tarball_url
    return {
        "server_name": pairing.server_name,
        "platform": pairing.platform,
        "agent_port": pairing.agent_port,
        "bind_host": pairing.bind_host,
        "warning_threshold": pairing.warning_threshold,
        "critical_threshold": pairing.critical_threshold,
        "central_url": settings.public_url or central_url.rstrip("/"),
        "agent_api_key": pairing.generated_agent_api_key_encrypted_or_temporary,
        "temperature_command_hint": temperature_command_hint(pairing.platform),
        "source_tarbball_url": source_tarball_url,
        "source_tarball_url": source_tarball_url,
    }


def complete_pairing_setup(
    session: Session,
    raw_token: str,
    payload: dict[str, object],
) -> Server:
    pairing = get_valid_pairing(session=session, raw_token=raw_token)
    agent_api_key = pairing.generated_agent_api_key_encrypted_or_temporary
    if not agent_api_key:
        record_pairing_error(pairing, "Pairing token has not been bootstrapped.")
        raise PairingError("Pairing token has not been bootstrapped.")

    agent_url = str(payload.get("agent_url", "")).strip()
    if not is_valid_http_url(agent_url):
        record_pairing_error(pairing, "Installer submitted an invalid agent URL.")
        raise PairingError("Installer submitted an invalid agent URL.")

    temperature = payload.get("temperature")
    if temperature is None or not is_numeric(temperature):
        record_pairing_error(pairing, "Installer did not submit a successful local temperature test.")
        raise PairingError("Installer did not submit a successful local temperature test.")

    detected_hostname = clean_optional_string(payload.get("detected_hostname"))
    server_name = clean_optional_string(pairing.server_name) or detected_hostname or "Thermo Agent"
    existing_server = session.scalar(select(Server).where(Server.url == agent_url).order_by(Server.id))
    if existing_server and existing_server.id != pairing.created_server_id:
        record_pairing_error(pairing, "A server with this agent URL already exists.")
        raise PairingConflict("A server with this agent URL already exists.")

    if existing_server:
        server = existing_server
        server.name = server_name
        server.url = agent_url
        server.api_key = agent_api_key
        server.warning_threshold = pairing.warning_threshold
        server.critical_threshold = pairing.critical_threshold
        server.enabled = True
    else:
        server = Server(
            name=server_name,
            url=agent_url,
            api_key=agent_api_key,
            warning_threshold=pairing.warning_threshold,
            critical_threshold=pairing.critical_threshold,
            enabled=True,
        )
        session.add(server)
    session.flush()

    now = utc_now()
    pairing.detected_hostname = detected_hostname
    pairing.detected_platform = clean_optional_string(payload.get("detected_platform"))
    pairing.detected_ip = clean_optional_string(payload.get("detected_ip"))
    pairing.created_server_id = server.id
    pairing.used_at = now
    pairing.completed_at = now
    pairing.generated_agent_api_key_encrypted_or_temporary = None
    pairing.last_error = None
    return server


def get_valid_pairing(session: Session, raw_token: str) -> PairingToken:
    token_hash = hash_pairing_token(raw_token.strip())
    pairing = session.scalar(select(PairingToken).where(PairingToken.token_hash == token_hash))
    if pairing is None:
        raise PairingError("Invalid pairing token.")
    if pairing.revoked_at is not None:
        record_pairing_error(pairing, "Pairing token has been revoked.")
        raise PairingError("Pairing token has been revoked.")
    if pairing.used_at is not None:
        raise PairingError("Pairing token has already been used.")
    if is_expired(pairing.expires_at):
        record_pairing_error(pairing, "Pairing token has expired.")
        raise PairingError("Pairing token has expired.")
    return pairing


def record_pairing_error(pairing: PairingToken, message: str) -> None:
    pairing.last_error = message


def hash_pairing_token(raw_token: str) -> str:
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


def token_suffix(raw_token: str) -> str:
    return raw_token[-TOKEN_SUFFIX_LENGTH:]


def build_agent_temperature_url(bind_host: str, agent_port: int) -> str:
    return f"http://{bind_host}:{agent_port}/temperature"


def temperature_command_hint(platform: str) -> str:
    if platform in {"freebsd", "truenas_core"}:
        return FREEBSD_TEMPERATURE_COMMAND_HINT
    if platform in {"proxmox", "debian_ubuntu", "generic_systemd_linux"}:
        return LINUX_TEMPERATURE_COMMAND_HINT
    return "Configure THERMO_TEMP_COMMAND for this platform."


def is_valid_http_url(value: str) -> bool:
    if any(character.isspace() for character in value):
        return False
    parsed = urlparse(value)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def is_valid_bind_host(value: str) -> bool:
    if not value:
        return False
    if any(character.isspace() for character in value):
        return False
    if "://" in value:
        return False
    if "/" in value or "\\" in value:
        return False
    if value in {".", ".."}:
        return False
    return True


def parse_port(value: object, errors: list[str]) -> Optional[int]:
    try:
        port = int(str(value))
    except (TypeError, ValueError):
        errors.append("Agent port must be a number.")
        return None
    if port < 1 or port > 65535:
        errors.append("Agent port must be between 1 and 65535.")
        return None
    return port


def parse_threshold(value: object, label: str, errors: list[str]) -> Optional[float]:
    try:
        threshold = float(str(value))
    except (TypeError, ValueError):
        errors.append(f"{label} must be numeric.")
        return None
    if not math.isfinite(threshold):
        errors.append(f"{label} must be numeric.")
        return None
    return threshold


def is_numeric(value: object) -> bool:
    try:
        number = float(str(value))
    except (TypeError, ValueError):
        return False
    return math.isfinite(number)


def clean_optional_string(value: object, max_length: int = 255) -> Optional[str]:
    cleaned = str(value or "").strip()
    if not cleaned:
        return None
    return cleaned[:max_length]


def format_threshold(value: float) -> str:
    if float(value).is_integer():
        return str(int(value))
    return str(value)


def is_expired(expires_at: datetime) -> bool:
    now = utc_now()
    if expires_at.tzinfo is None:
        return expires_at <= now.replace(tzinfo=None)
    return expires_at <= now


def format_datetime(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.isoformat()


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class PairingError(Exception):
    pass


class PairingConflict(PairingError):
    pass
