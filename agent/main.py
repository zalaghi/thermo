import hmac
import os
import re
import subprocess
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, status


DEFAULT_TEMP_COMMAND = (
    r"sensors | awk '/Package id 0|Tctl|CPU/ {print $0; exit}' | "
    r"grep -oE '[+-]?[0-9]+(\.[0-9]+)?°C' | head -n1 | tr -d '+°C'"
)
DEFAULT_COMMAND_TIMEOUT_SECONDS = 3.0
TEMPERATURE_PATTERN = re.compile(r"[+-]?\d+(?:\.\d+)?")


app = FastAPI(title="Thermo Agent")


@app.get("/health")
async def health() -> dict[str, bool]:
    return {"ok": True}


@app.get("/temperature")
async def temperature(x_api_key: Optional[str] = Header(default=None)) -> dict[str, object]:
    require_api_key(x_api_key)
    value = read_temperature()
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


def read_temperature() -> float:
    output = run_temperature_command()
    match = TEMPERATURE_PATTERN.search(output)
    if not match:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Temperature command did not return a numeric value",
        )
    return float(match.group(0))


def run_temperature_command() -> str:
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
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Temperature command timed out",
        ) from exc
    except OSError as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Temperature command could not be executed",
        ) from exc

    if completed.returncode != 0:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Temperature command failed",
        )

    return completed.stdout.strip()


def get_command_timeout_seconds() -> float:
    raw_value = os.getenv("THERMO_TEMP_TIMEOUT_SECONDS")
    if not raw_value:
        return DEFAULT_COMMAND_TIMEOUT_SECONDS

    try:
        timeout_seconds = float(raw_value)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Invalid temperature command timeout",
        ) from exc

    if timeout_seconds <= 0:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Invalid temperature command timeout",
        )

    return timeout_seconds
