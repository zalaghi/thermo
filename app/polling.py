from __future__ import annotations

import asyncio
import logging
import math
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

import httpx
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from .db import session_scope
from .models import LatestStatus, Server
from .settings import get_settings


logger = logging.getLogger(__name__)
REQUEST_TIMEOUT_SECONDS = 3.0
UNIT_CELSIUS = "C"
STATUS_OK = "OK"
STATUS_WARM = "Warm"
STATUS_HOT = "Hot"
STATUS_OFFLINE = "Offline"
STATUS_PENDING = "Pending"
STATUS_DISABLED = "Disabled"


@dataclass(frozen=True)
class ServerPollTarget:
    id: int
    url: str
    api_key: str
    warning_threshold: float
    critical_threshold: float


@dataclass(frozen=True)
class PollResult:
    server_id: int
    temperature: Optional[float]
    status: str
    error: Optional[str]
    checked_at: datetime


async def polling_loop() -> None:
    settings = get_settings()
    logger.info("Thermo polling started with %.2f second interval.", settings.poll_interval_seconds)
    while True:
        try:
            await poll_enabled_servers()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Unexpected polling failure.")

        await asyncio.sleep(settings.poll_interval_seconds)


async def poll_enabled_servers() -> None:
    targets = load_enabled_poll_targets()
    if not targets:
        return

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        results = await asyncio.gather(
            *(poll_server(client, target) for target in targets),
            return_exceptions=True,
        )

    poll_results: list[PollResult] = []
    for target, result in zip(targets, results):
        if isinstance(result, PollResult):
            poll_results.append(result)
            continue

        logger.error(
            "Polling failed unexpectedly for server %s.",
            target.id,
            exc_info=(type(result), result, result.__traceback__),
        )
        poll_results.append(
            PollResult(
                server_id=target.id,
                temperature=None,
                status=STATUS_OFFLINE,
                error="Unexpected polling error",
                checked_at=utc_now(),
            )
        )

    store_poll_results(poll_results)


def load_enabled_poll_targets() -> list[ServerPollTarget]:
    with session_scope() as session:
        servers = session.scalars(
            select(Server)
            .where(Server.enabled.is_(True))
            .order_by(Server.id)
        ).all()
        return [
            ServerPollTarget(
                id=server.id,
                url=server.url,
                api_key=server.api_key,
                warning_threshold=server.warning_threshold,
                critical_threshold=server.critical_threshold,
            )
            for server in servers
        ]


async def poll_server(client: httpx.AsyncClient, target: ServerPollTarget) -> PollResult:
    checked_at = utc_now()
    try:
        response = await client.get(target.url, headers={"X-API-Key": target.api_key})
        response.raise_for_status()
        payload = response.json()
        temperature = parse_temperature(payload)
    except httpx.TimeoutException:
        return offline_result(target.id, "Request timed out", checked_at)
    except httpx.HTTPStatusError as exc:
        return offline_result(target.id, f"Agent returned HTTP {exc.response.status_code}", checked_at)
    except httpx.RequestError:
        return offline_result(target.id, "Request failed", checked_at)
    except ValueError:
        return offline_result(target.id, "Invalid JSON from agent", checked_at)
    except TypeError as exc:
        return offline_result(target.id, str(exc), checked_at)

    return PollResult(
        server_id=target.id,
        temperature=temperature,
        status=status_for_temperature(
            temperature=temperature,
            warning_threshold=target.warning_threshold,
            critical_threshold=target.critical_threshold,
        ),
        error=None,
        checked_at=checked_at,
    )


def parse_temperature(payload: object) -> float:
    if not isinstance(payload, dict):
        raise TypeError("Agent response was not a JSON object")

    raw_temperature = payload.get("temperature")
    if raw_temperature is None:
        raise TypeError("Agent response did not include a temperature")

    try:
        temperature = float(raw_temperature)
    except (TypeError, ValueError) as exc:
        raise TypeError("Agent temperature was not numeric") from exc

    if not math.isfinite(temperature):
        raise TypeError("Agent temperature was not numeric")

    return temperature


def status_for_temperature(
    temperature: float,
    warning_threshold: float,
    critical_threshold: float,
) -> str:
    if temperature >= critical_threshold:
        return STATUS_HOT
    if temperature >= warning_threshold:
        return STATUS_WARM
    return STATUS_OK


def offline_result(server_id: int, error: str, checked_at: datetime) -> PollResult:
    return PollResult(
        server_id=server_id,
        temperature=None,
        status=STATUS_OFFLINE,
        error=error,
        checked_at=checked_at,
    )


def store_poll_results(results: list[PollResult]) -> None:
    if not results:
        return

    with session_scope() as session:
        for result in results:
            latest_status = session.scalar(
                select(LatestStatus).where(LatestStatus.server_id == result.server_id)
            )
            if not latest_status:
                latest_status = LatestStatus(
                    server_id=result.server_id,
                    temperature=result.temperature,
                    status=result.status,
                    error=result.error,
                    checked_at=result.checked_at,
                )
                session.add(latest_status)
                continue

            latest_status.temperature = result.temperature
            latest_status.status = result.status
            latest_status.error = result.error
            latest_status.checked_at = result.checked_at


def get_status_payload() -> list[dict[str, object]]:
    with session_scope() as session:
        servers = session.scalars(
            select(Server)
            .options(selectinload(Server.latest_status))
            .order_by(Server.name)
        ).all()

        payload = []
        for server in servers:
            latest_status = server.latest_status
            status_value = status_value_for_api(server, latest_status)
            payload.append(
                {
                    "id": server.id,
                    "name": server.name,
                    "url": server.url,
                    "enabled": server.enabled,
                    "temperature": latest_status.temperature if latest_status else None,
                    "unit": UNIT_CELSIUS,
                    "status": status_value,
                    "error": latest_status.error if latest_status else None,
                    "checked_at": format_checked_at(latest_status.checked_at) if latest_status else None,
                }
            )

        return payload


def status_value_for_api(server: Server, latest_status: Optional[LatestStatus]) -> str:
    if not server.enabled:
        return STATUS_DISABLED
    if not latest_status:
        return STATUS_PENDING
    return latest_status.status


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def format_checked_at(checked_at: datetime) -> str:
    if checked_at.tzinfo is None:
        checked_at = checked_at.replace(tzinfo=timezone.utc)
    return checked_at.isoformat()
