from __future__ import annotations

import hashlib
import math
import secrets
import shlex
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional
from urllib.parse import urlparse

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import PairingToken, Server


INSTALLER_URL = "https://raw.githubusercontent.com/zalaghi/thermo/main/scripts/install-agent.sh"
SOURCE_TARBALL_URL = "https://github.com/zalaghi/thermo/archive/refs/heads/main.tar.gz"
PAIRING_TOKEN_TTL_MINUTES = 15
DEFAULT_AGENT_PORT = 8090
DEFAULT_WARNING_THRESHOLD = 65.0
DEFAULT_CRITICAL_THRESHOLD = 80.0

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
    raw_token: str


def default_pairing_form_data(thermo_url: str) -> dict[str, object]:
    return {
        "server_name": "",
        "platform": "proxmox",
        "thermo_url": thermo_url,
        "bind_host": "",
        "agent_port": str(DEFAULT_AGENT_PORT),
        "warning_threshold": format_threshold(DEFAULT_WARNING_THRESHOLD),
        "critical_threshold": format_threshold(DEFAULT_CRITICAL_THRESHOLD),
    }


def validate_pairing_form(form_data: dict[str, object]) -> tuple[list[str], Optional[PairingFormValues]]:
    errors: list[str] = []
    server_name = str(form_data.get("server_name", "")).strip()
    platform = str(form_data.get("platform", "")).strip()
    thermo_url = str(form_data.get("thermo_url", "")).strip().rstrip("/")
    bind_host = str(form_data.get("bind_host", "")).strip()

    if not server_name:
        errors.append("Server name is required.")
    if platform not in PLATFORM_VALUES:
        errors.append("Choose a supported target platform.")
    if not is_valid_http_url(thermo_url):
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
    raw_token = secrets.token_urlsafe(32)
    pairing = PairingToken(
        token_hash=hash_pairing_token(raw_token),
        platform=values.platform,
        server_name=values.server_name,
        bind_host=values.bind_host,
        agent_port=values.agent_port,
        warning_threshold=values.warning_threshold,
        critical_threshold=values.critical_threshold,
        expires_at=utc_now() + timedelta(minutes=PAIRING_TOKEN_TTL_MINUTES),
    )
    session.add(pairing)
    session.flush()
    command = build_install_command(values=values, raw_token=raw_token)
    return PairingCreationResult(pairing=pairing, command=command, raw_token=raw_token)


def build_install_command(values: PairingFormValues, raw_token: str) -> str:
    args = [
        "--thermo-url",
        values.thermo_url,
        "--pairing-token",
        raw_token,
        "--platform",
        values.platform,
        "--bind-host",
        values.bind_host,
        "--port",
        str(values.agent_port),
    ]
    quoted_args = " ".join(shlex.quote(arg) for arg in args)
    return f"curl -fsSL {shlex.quote(INSTALLER_URL)} | sudo sh -s -- {quoted_args}"


def complete_pairing_registration(
    session: Session,
    raw_token: str,
) -> tuple[Server, str]:
    pairing = get_valid_pairing(session=session, raw_token=raw_token)
    agent_api_key = secrets.token_urlsafe(32)
    agent_url = build_agent_temperature_url(pairing.bind_host, pairing.agent_port)

    server = session.scalar(
        select(Server)
        .where(Server.name == pairing.server_name)
        .order_by(Server.id)
    )
    if server is None:
        server = Server(
            name=pairing.server_name,
            url=agent_url,
            api_key=agent_api_key,
            warning_threshold=pairing.warning_threshold,
            critical_threshold=pairing.critical_threshold,
            enabled=True,
        )
        session.add(server)
        session.flush()
    else:
        server.url = agent_url
        server.api_key = agent_api_key
        server.warning_threshold = pairing.warning_threshold
        server.critical_threshold = pairing.critical_threshold
        server.enabled = True

    pairing.server_id = server.id
    pairing.used_at = utc_now()
    return server, agent_api_key


def get_valid_pairing(session: Session, raw_token: str) -> PairingToken:
    token_hash = hash_pairing_token(raw_token.strip())
    pairing = session.scalar(select(PairingToken).where(PairingToken.token_hash == token_hash))
    if pairing is None:
        raise PairingError("Invalid pairing token.")
    if pairing.revoked_at is not None:
        raise PairingError("Pairing token has been revoked.")
    if pairing.used_at is not None:
        raise PairingError("Pairing token has already been used.")
    if is_expired(pairing.expires_at):
        raise PairingError("Pairing token has expired.")
    return pairing


def hash_pairing_token(raw_token: str) -> str:
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


def build_agent_temperature_url(bind_host: str, agent_port: int) -> str:
    return f"http://{bind_host}:{agent_port}/temperature"


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


def format_threshold(value: float) -> str:
    if float(value).is_integer():
        return str(int(value))
    return str(value)


def is_expired(expires_at: datetime) -> bool:
    now = utc_now()
    if expires_at.tzinfo is None:
        return expires_at <= now.replace(tzinfo=None)
    return expires_at <= now


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class PairingError(Exception):
    pass
