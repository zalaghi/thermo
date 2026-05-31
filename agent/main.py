import hmac
import ipaddress
import os
import re
import subprocess
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse


DEFAULT_TEMP_COMMAND = (
    r"sensors | awk '/Package id 0|Tctl|CPU/ {print $0; exit}' | "
    r"grep -oE '[+-]?[0-9]+(\.[0-9]+)?°C' | head -n1 | tr -d '+°C'"
)
DEFAULT_COMMAND_TIMEOUT_SECONDS = 3.0
DEFAULT_RATE_LIMIT_PER_MINUTE = 120
TEMPERATURE_PATTERN = re.compile(r"[+-]?\d+(?:\.\d+)?")
RATE_LIMIT_WINDOW_SECONDS = 60.0
rate_limit_events: dict[str, deque[float]] = defaultdict(deque)


app = FastAPI(title="Thermo Agent")


@app.get("/health")
async def health(x_api_key: Optional[str] = Header(default=None)) -> dict[str, bool]:
    if should_protect_health():
        require_api_key(x_api_key)
    return {"ok": True}


@app.get("/temperature")
async def temperature(request: Request, x_api_key: Optional[str] = Header(default=None)) -> dict[str, object]:
    require_api_key(x_api_key)
    client_ip = get_client_ip(request)
    require_allowed_client(client_ip)
    enforce_rate_limit(client_ip)
    try:
        value = read_temperature()
    except TemperatureCommandError as exc:
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content=exc.payload,
        )
    return {"temperature": value, "unit": "C"}


def require_api_key(provided_api_key: Optional[str]) -> None:
    expected_api_key = os.getenv("THERMO_AGENT_API_KEY")
    if not expected_api_key or not provided_api_key:
        raise_unauthorized()

    if not hmac.compare_digest(provided_api_key, expected_api_key):
        raise_unauthorized()


def raise_unauthorized() -> None:
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Unauthorized",
    )


def raise_forbidden() -> None:
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Forbidden",
    )


def raise_rate_limited() -> None:
    raise HTTPException(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        detail="Rate limit exceeded",
    )


def get_client_ip(request: Request) -> str:
    if request.client is None:
        return ""
    return request.client.host


def require_allowed_client(client_ip: str) -> None:
    allowed_networks = get_allowed_client_networks()
    if not allowed_networks:
        return

    try:
        remote_address = ipaddress.ip_address(client_ip)
    except ValueError:
        raise_forbidden()

    if not any(remote_address in network for network in allowed_networks):
        raise_forbidden()


def get_allowed_client_networks() -> list[object]:
    raw_value = os.getenv("THERMO_AGENT_ALLOWED_CLIENTS", "")
    if not raw_value.strip():
        return []

    networks = []
    for item in raw_value.split(","):
        candidate = item.strip()
        if not candidate:
            continue
        try:
            networks.append(ipaddress.ip_network(candidate, strict=False))
        except ValueError as exc:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Invalid agent allowed clients configuration.",
            ) from exc
    return networks


def enforce_rate_limit(client_ip: str) -> None:
    limit = get_rate_limit_per_minute()
    if limit <= 0:
        return

    now = time.monotonic()
    events = rate_limit_events[client_ip or "unknown"]
    while events and now - events[0] >= RATE_LIMIT_WINDOW_SECONDS:
        events.popleft()
    if len(events) >= limit:
        raise_rate_limited()
    events.append(now)


def get_rate_limit_per_minute() -> int:
    raw_value = os.getenv("THERMO_AGENT_RATE_LIMIT_PER_MINUTE", str(DEFAULT_RATE_LIMIT_PER_MINUTE))
    try:
        limit = int(raw_value)
    except ValueError:
        return DEFAULT_RATE_LIMIT_PER_MINUTE
    if limit < 0:
        return DEFAULT_RATE_LIMIT_PER_MINUTE
    return limit


def should_protect_health() -> bool:
    return os.getenv("THERMO_AGENT_PROTECT_HEALTH", "false").strip().lower() in {"1", "true", "yes", "on"}


def read_temperature() -> float:
    result = run_temperature_command()
    match = TEMPERATURE_PATTERN.search(result.stdout)
    if not match:
        raise TemperatureCommandError(
            "no_numeric_temperature",
            "No numeric temperature found in temperature command output.",
            result,
        )
    return float(match.group(0))


def run_temperature_command() -> "CommandResult":
    command = os.getenv("THERMO_TEMP_COMMAND", DEFAULT_TEMP_COMMAND)
    timeout_seconds = get_command_timeout_seconds()

    try:
        completed = subprocess.run(
            command,
            shell=True,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise TemperatureCommandError(
            "temperature_command_timeout",
            "Temperature command timed out.",
            CommandResult(stdout=exc.stdout or "", stderr=exc.stderr or "", returncode=None),
        ) from exc
    except OSError as exc:
        raise TemperatureCommandError(
            "temperature_command_exec_error",
            "Temperature command could not be executed.",
        ) from exc

    result = CommandResult(
        stdout=completed.stdout.strip(),
        stderr=completed.stderr.strip(),
        returncode=completed.returncode,
    )
    if completed.returncode != 0:
        raise TemperatureCommandError(
            "temperature_command_failed",
            "Temperature command failed.",
            result,
        )

    return result


def get_command_timeout_seconds() -> float:
    raw_value = os.getenv("THERMO_TEMP_TIMEOUT_SECONDS")
    if not raw_value:
        return DEFAULT_COMMAND_TIMEOUT_SECONDS

    try:
        timeout_seconds = float(raw_value)
    except ValueError as exc:
        raise TemperatureCommandError(
            "invalid_temperature_timeout",
            "Invalid temperature command timeout.",
        ) from exc

    if timeout_seconds <= 0:
        raise TemperatureCommandError(
            "invalid_temperature_timeout",
            "Invalid temperature command timeout.",
        )

    return timeout_seconds


@dataclass(frozen=True)
class CommandResult:
    stdout: str
    stderr: str
    returncode: Optional[int]


class TemperatureCommandError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        result: Optional[CommandResult] = None,
    ) -> None:
        super().__init__(message)
        self.payload: dict[str, object] = {
            "error": code,
            "message": message,
        }
        if result is not None:
            self.payload["exit_status"] = result.returncode
            stderr_excerpt = safe_excerpt(result.stderr)
            if stderr_excerpt:
                self.payload["stderr_excerpt"] = stderr_excerpt


def safe_excerpt(value: str, max_length: int = 240) -> str:
    return " ".join(str(value or "").split())[:max_length]
