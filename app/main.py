import asyncio
import hmac
import logging
import math
import secrets
from contextlib import asynccontextmanager, suppress
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlparse

import httpx
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import HTMLResponse, PlainTextResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import func, select
from starlette.middleware.sessions import SessionMiddleware

from .auth import hash_password, verify_password
from .db import init_db, session_scope
from .models import PairingToken, Server, User
from .polling import get_status_payload, polling_loop
from .setup_wizard import (
    PLATFORM_CHOICES,
    PairingConflict,
    PairingError,
    bootstrap_pairing,
    complete_pairing_setup,
    create_pairing,
    default_pairing_form_data,
    host_is_ip_address,
    list_active_pairings,
    pairing_status_payload,
    pairing_status_payload_with_server,
    revoke_pairing,
    validate_agent_temperature_url,
    validate_pairing_form,
)
from .settings import get_settings


APP_DIR = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(APP_DIR / "templates"))
templates.env.filters["mask_api_key"] = lambda value: mask_api_key(value)
templates.env.filters["format_threshold"] = lambda value: format_threshold(value)
logger = logging.getLogger(__name__)
DEFAULT_WARNING_THRESHOLD = 65.0
DEFAULT_CRITICAL_THRESHOLD = 80.0
ADMIN_TEST_TIMEOUT_SECONDS = 3.0


def create_app() -> FastAPI:
    settings = get_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        init_db()
        ensure_default_admin()
        app.state.polling_task = asyncio.create_task(polling_loop())
        try:
            yield
        finally:
            app.state.polling_task.cancel()
            with suppress(asyncio.CancelledError):
                await app.state.polling_task

    app = FastAPI(title=settings.app_name, lifespan=lifespan)
    if settings.secret_key_is_fallback:
        logger.warning("THERMO_SECRET_KEY is not set; using a development fallback secret key.")
    elif settings.secret_key_is_placeholder:
        logger.warning("THERMO_SECRET_KEY is set to a placeholder value; replace it before real use.")
    if settings.admin_password_is_default:
        logger.warning("THERMO_ADMIN_PASSWORD is using the default value; change it before real use.")

    app.add_middleware(
        SessionMiddleware,
        secret_key=settings.secret_key,
        session_cookie="thermo_session",
        same_site="lax",
        max_age=60 * 60 * 12,
    )

    app.mount(
        "/static",
        StaticFiles(directory=str(APP_DIR / "static")),
        name="static",
    )

    @app.get("/", response_class=HTMLResponse)
    async def dashboard(request: Request) -> HTMLResponse:
        return templates.TemplateResponse(
            "dashboard.html",
            {
                "request": request,
                "settings": settings,
                "servers": [],
            },
        )

    @app.get("/api/status")
    async def api_status() -> list[dict[str, object]]:
        return get_status_payload()

    @app.get("/api/setup/bootstrap")
    async def api_setup_bootstrap(request: Request, token: str = "") -> dict[str, object]:
        raw_token = token.strip()
        if not raw_token:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Pairing token is required.",
            )

        bootstrap_payload = None
        setup_error = None
        with session_scope() as session:
            try:
                bootstrap_payload = bootstrap_pairing(
                    session=session,
                    raw_token=raw_token,
                    central_url=get_effective_public_url(request),
                )
            except PairingError as exc:
                setup_error = str(exc)

        if setup_error:
            logger.warning("Thermo setup bootstrap failed: %s", setup_error)
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=setup_error,
            )

        return bootstrap_payload or {}

    @app.get("/api/setup/status/{pairing_id}")
    async def api_setup_status(request: Request, pairing_id: int) -> dict[str, object]:
        if not is_authenticated(request):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Admin login required.",
            )

        with session_scope() as session:
            pairing = session.get(PairingToken, pairing_id)
            if not pairing:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pairing token not found")
            server = session.get(Server, pairing.created_server_id) if pairing.created_server_id else None
            return pairing_status_payload_with_server(pairing, server)

    @app.post("/api/setup/complete")
    async def api_setup_complete(request: Request) -> dict[str, object]:
        try:
            payload = await request.json()
        except ValueError as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Invalid JSON body.",
            ) from exc

        if not isinstance(payload, dict):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Invalid JSON body.",
            )

        raw_token = str(payload.get("token", "")).strip()
        if not raw_token:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Pairing token is required.",
            )

        server_payload = None
        setup_error = None
        setup_status = status.HTTP_401_UNAUTHORIZED
        with session_scope() as session:
            try:
                server = complete_pairing_setup(
                    session=session,
                    raw_token=raw_token,
                    payload=payload,
                )
                server_payload = {
                    "ok": True,
                    "server_id": server.id,
                    "server_name": server.name,
                    "agent_url": server.url,
                }
            except PairingConflict as exc:
                setup_error = str(exc)
                setup_status = status.HTTP_409_CONFLICT
            except PairingError as exc:
                setup_error = str(exc)
                setup_status = status.HTTP_401_UNAUTHORIZED

        if setup_error:
            logger.warning("Thermo setup completion failed: %s", setup_error)
            raise HTTPException(
                status_code=setup_status,
                detail=setup_error,
            )

        return server_payload or {}

    @app.post("/api/setup/register")
    async def api_setup_register_legacy() -> dict[str, object]:
        raise HTTPException(
            status_code=status.HTTP_410_GONE,
            detail="Use /api/setup/bootstrap and /api/setup/complete.",
        )

    @app.get("/admin/login", response_class=HTMLResponse)
    async def admin_login(request: Request) -> Response:
        if is_authenticated(request):
            return RedirectResponse("/admin", status_code=status.HTTP_303_SEE_OTHER)
        return templates.TemplateResponse(
            "admin_login.html",
            {
                "request": request,
                "settings": settings,
                "error": None,
                "csrf_token": get_csrf_token(request),
            },
        )

    @app.post("/admin/login", response_class=HTMLResponse)
    async def admin_login_submit(request: Request) -> Response:
        form = await read_form(request)
        if not has_valid_csrf_token(request, form):
            return PlainTextResponse("Invalid CSRF token", status_code=status.HTTP_400_BAD_REQUEST)

        username = get_form_value(form, "username").strip()
        password = get_form_value(form, "password")

        with session_scope() as session:
            user = session.scalar(select(User).where(User.username == username))
            if not user or not verify_password(password, user.password_hash):
                return templates.TemplateResponse(
                    "admin_login.html",
                    {
                        "request": request,
                        "settings": settings,
                        "error": "Invalid username or password.",
                        "csrf_token": get_csrf_token(request),
                    },
                    status_code=status.HTTP_401_UNAUTHORIZED,
                )

            request.session.clear()
            request.session["user_id"] = user.id
            request.session["username"] = user.username

        return RedirectResponse("/admin", status_code=status.HTTP_303_SEE_OTHER)

    @app.get("/admin/logout")
    async def admin_logout(request: Request) -> RedirectResponse:
        request.session.clear()
        return RedirectResponse("/admin/login", status_code=status.HTTP_303_SEE_OTHER)

    @app.get("/admin", response_class=HTMLResponse)
    async def admin_home(request: Request) -> Response:
        if not is_authenticated(request):
            return RedirectResponse("/admin/login", status_code=status.HTTP_303_SEE_OTHER)
        return templates.TemplateResponse(
            "admin_home.html",
            {
                "request": request,
                "settings": settings,
                "username": request.session.get("username"),
            },
        )

    @app.get("/admin/setup-agent", response_class=HTMLResponse)
    async def admin_setup_agent(request: Request) -> Response:
        if not is_authenticated(request):
            return redirect_to_login()

        form_data = default_pairing_form_data(get_effective_public_url(request))
        copy_from = request.query_params.get("copy_from", "").strip()
        if copy_from.isdigit():
            with session_scope() as session:
                pairing = session.get(PairingToken, int(copy_from))
                if pairing:
                    form_data = pairing_form_data_from_model(pairing, get_effective_public_url(request))

        return render_agent_setup_form(
            request=request,
            settings=settings,
            form_data=form_data,
            errors=[],
        )

    @app.post("/admin/setup-agent", response_class=HTMLResponse)
    async def admin_setup_agent_create(request: Request) -> Response:
        if not is_authenticated(request):
            return redirect_to_login()

        form = await read_form(request)
        if not has_valid_csrf_token(request, form):
            return PlainTextResponse("Invalid CSRF token", status_code=status.HTTP_400_BAD_REQUEST)

        form_data = pairing_form_data_from_form(request, form)
        errors, values = validate_pairing_form(form_data)
        if errors or values is None:
            return render_agent_setup_form(
                request=request,
                settings=settings,
                form_data=form_data,
                errors=errors,
                status_code=status.HTTP_400_BAD_REQUEST,
            )

        with session_scope() as session:
            result = create_pairing(session=session, values=values)
            pairing = result.pairing
            install_commands = {
                "linux": result.linux_command,
                "freebsd_fetch": result.freebsd_fetch_command,
                "freebsd_curl": result.freebsd_curl_command,
            }

        return render_agent_setup_detail(
            request=request,
            settings=settings,
            pairing=pairing,
            install_commands=install_commands,
            status_code=status.HTTP_201_CREATED,
        )

    @app.get("/admin/setup-agent/{pairing_id}")
    async def admin_setup_agent_detail(request: Request, pairing_id: int) -> Response:
        if not is_authenticated(request):
            return redirect_to_login()

        with session_scope() as session:
            pairing = session.get(PairingToken, pairing_id)
            if not pairing:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pairing token not found")
            server = session.get(Server, pairing.created_server_id) if pairing.created_server_id else None
            status_payload = pairing_status_payload_with_server(pairing, server)

        if wants_json(request):
            return status_payload

        return render_agent_setup_detail(
            request=request,
            settings=settings,
            pairing=pairing,
            install_commands=None,
            status_payload=status_payload,
        )

    @app.post("/admin/setup-agent/{pairing_id}/revoke")
    async def admin_setup_agent_revoke(request: Request, pairing_id: int) -> Response:
        if not is_authenticated(request):
            return redirect_to_login()

        form = await read_form(request)
        if not has_valid_csrf_token(request, form):
            return PlainTextResponse("Invalid CSRF token", status_code=status.HTTP_400_BAD_REQUEST)

        with session_scope() as session:
            pairing = revoke_pairing(session=session, pairing_id=pairing_id)
            if not pairing:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pairing token not found")

        return RedirectResponse(f"/admin/setup-agent/{pairing_id}", status_code=status.HTTP_303_SEE_OTHER)

    @app.get("/admin/servers", response_class=HTMLResponse)
    async def admin_servers(request: Request) -> Response:
        if not is_authenticated(request):
            return redirect_to_login()

        with session_scope() as session:
            servers = list(session.scalars(select(Server).order_by(Server.name)))

        return templates.TemplateResponse(
            "admin_servers.html",
            {
                "request": request,
                "settings": settings,
                "servers": servers,
                "csrf_token": get_csrf_token(request),
            },
        )

    @app.get("/admin/servers/new", response_class=HTMLResponse)
    async def admin_server_new(request: Request) -> Response:
        if not is_authenticated(request):
            return redirect_to_login()

        return render_server_form(
            request=request,
            settings=settings,
            mode="new",
            form_data=default_server_form_data(),
            errors=[],
        )

    @app.post("/admin/servers/new", response_class=HTMLResponse)
    async def admin_server_create(request: Request) -> Response:
        if not is_authenticated(request):
            return redirect_to_login()

        form = await read_form(request)
        if not has_valid_csrf_token(request, form):
            return PlainTextResponse("Invalid CSRF token", status_code=status.HTTP_400_BAD_REQUEST)

        form_data = server_form_data_from_form(form)
        errors, values = validate_server_form(form_data, require_api_key=True)
        if errors:
            return render_server_form(
                request=request,
                settings=settings,
                mode="new",
                form_data=form_data,
                errors=errors,
                status_code=status.HTTP_400_BAD_REQUEST,
            )

        with session_scope() as session:
            session.add(
                Server(
                    name=values["name"],
                    url=values["url"],
                    api_key=values["api_key"],
                    warning_threshold=values["warning_threshold"],
                    critical_threshold=values["critical_threshold"],
                    enabled=values["enabled"],
                )
            )

        return RedirectResponse("/admin/servers", status_code=status.HTTP_303_SEE_OTHER)

    @app.post("/admin/servers/test")
    async def admin_server_test(request: Request) -> dict[str, object]:
        if not is_authenticated(request):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Admin login required.",
            )

        try:
            payload = await request.json()
        except ValueError as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Invalid JSON body.",
            ) from exc

        if not isinstance(payload, dict):
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid JSON body.")

        if not has_valid_csrf_token_from_value(request, str(payload.get("csrf_token", ""))):
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid CSRF token.")

        server_id = parse_optional_int(payload.get("server_id"))
        url = str(payload.get("url", "")).strip()
        api_key = str(payload.get("api_key", "")).strip()
        allow_missing_port = bool_from_payload(payload.get("allow_missing_port"))

        if server_id and not api_key:
            with session_scope() as session:
                server = session.get(Server, server_id)
                if server:
                    api_key = server.api_key

        errors = validate_agent_url_for_manual_form(url=url, allow_missing_port=allow_missing_port)
        if errors:
            return {"ok": False, "error": " ".join(errors)}
        if not api_key:
            return {"ok": False, "error": "API key is required to test the agent."}

        return await test_agent_connection(url=url, api_key=api_key)

    @app.get("/admin/servers/{server_id}/edit", response_class=HTMLResponse)
    async def admin_server_edit(request: Request, server_id: int) -> Response:
        if not is_authenticated(request):
            return redirect_to_login()

        with session_scope() as session:
            server = session.get(Server, server_id)
            if not server:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Server not found")
            form_data = server_form_data_from_model(server)
            masked_api_key = mask_api_key(server.api_key)

        return render_server_form(
            request=request,
            settings=settings,
            mode="edit",
            form_data=form_data,
            errors=[],
            server_id=server_id,
            masked_api_key=masked_api_key,
        )

    @app.post("/admin/servers/{server_id}/edit", response_class=HTMLResponse)
    async def admin_server_update(request: Request, server_id: int) -> Response:
        if not is_authenticated(request):
            return redirect_to_login()

        form = await read_form(request)
        if not has_valid_csrf_token(request, form):
            return PlainTextResponse("Invalid CSRF token", status_code=status.HTTP_400_BAD_REQUEST)

        with session_scope() as session:
            server = session.get(Server, server_id)
            if not server:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Server not found")

            form_data = server_form_data_from_form(form)
            errors, values = validate_server_form(form_data, require_api_key=False)
            if errors:
                return render_server_form(
                    request=request,
                    settings=settings,
                    mode="edit",
                    form_data=form_data,
                    errors=errors,
                    server_id=server_id,
                    masked_api_key=mask_api_key(server.api_key),
                    status_code=status.HTTP_400_BAD_REQUEST,
                )

            server.name = values["name"]
            server.url = values["url"]
            if values["api_key"]:
                server.api_key = values["api_key"]
            server.warning_threshold = values["warning_threshold"]
            server.critical_threshold = values["critical_threshold"]
            server.enabled = values["enabled"]

        return RedirectResponse("/admin/servers", status_code=status.HTTP_303_SEE_OTHER)

    @app.post("/admin/servers/{server_id}/delete")
    async def admin_server_delete(request: Request, server_id: int) -> Response:
        if not is_authenticated(request):
            return redirect_to_login()

        form = await read_form(request)
        if not has_valid_csrf_token(request, form):
            return PlainTextResponse("Invalid CSRF token", status_code=status.HTTP_400_BAD_REQUEST)

        with session_scope() as session:
            server = session.get(Server, server_id)
            if not server:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Server not found")
            session.delete(server)

        return RedirectResponse("/admin/servers", status_code=status.HTTP_303_SEE_OTHER)

    return app


def ensure_default_admin() -> None:
    settings = get_settings()
    with session_scope() as session:
        user_count = session.scalar(select(func.count(User.id))) or 0
        if user_count > 0:
            return

        username = settings.admin_username.strip() or "admin"
        password = settings.admin_password or "change-me-now"
        session.add(
            User(
                username=username,
                password_hash=hash_password(password),
            )
        )
        logger.warning("Created default Thermo admin user '%s'. Change the password before production use.", username)


def is_authenticated(request: Request) -> bool:
    return bool(request.session.get("user_id"))


def redirect_to_login() -> RedirectResponse:
    return RedirectResponse("/admin/login", status_code=status.HTTP_303_SEE_OTHER)


async def read_form(request: Request) -> dict[str, list[str]]:
    return parse_qs((await request.body()).decode("utf-8"), keep_blank_values=True)


def get_form_value(form: dict[str, list[str]], name: str) -> str:
    values = form.get(name)
    if not values:
        return ""
    return values[0]


def default_thermo_url(request: Request) -> str:
    return str(request.base_url).rstrip("/")


def get_effective_public_url(request: Request) -> str:
    settings = get_settings()
    return settings.public_url or default_thermo_url(request)


def wants_json(request: Request) -> bool:
    return "application/json" in request.headers.get("accept", "")


def get_csrf_token(request: Request) -> str:
    token = request.session.get("csrf_token")
    if not token:
        token = secrets.token_urlsafe(32)
        request.session["csrf_token"] = token
    return token


def has_valid_csrf_token(request: Request, form: dict[str, list[str]]) -> bool:
    return has_valid_csrf_token_from_value(request, get_form_value(form, "csrf_token"))


def has_valid_csrf_token_from_value(request: Request, provided_token: str) -> bool:
    expected_token = request.session.get("csrf_token")
    return bool(
        expected_token
        and provided_token
        and hmac.compare_digest(provided_token, expected_token)
    )


def default_server_form_data() -> dict[str, object]:
    return {
        "name": "",
        "url": "",
        "api_key": "",
        "warning_threshold": format_threshold(DEFAULT_WARNING_THRESHOLD),
        "critical_threshold": format_threshold(DEFAULT_CRITICAL_THRESHOLD),
        "enabled": True,
        "allow_missing_port": False,
    }


def server_form_data_from_form(form: dict[str, list[str]]) -> dict[str, object]:
    return {
        "name": get_form_value(form, "name").strip(),
        "url": get_form_value(form, "url").strip(),
        "api_key": get_form_value(form, "api_key").strip(),
        "warning_threshold": get_form_value(form, "warning_threshold").strip(),
        "critical_threshold": get_form_value(form, "critical_threshold").strip(),
        "enabled": get_form_value(form, "enabled") == "on",
        "allow_missing_port": get_form_value(form, "allow_missing_port") == "on",
    }


def server_form_data_from_model(server: Server) -> dict[str, object]:
    return {
        "name": server.name,
        "url": server.url,
        "api_key": "",
        "warning_threshold": format_threshold(server.warning_threshold),
        "critical_threshold": format_threshold(server.critical_threshold),
        "enabled": server.enabled,
        "allow_missing_port": False,
    }


def validate_server_form(
    form_data: dict[str, object],
    require_api_key: bool,
) -> tuple[list[str], dict[str, object]]:
    errors = []
    values: dict[str, object] = {}

    name = str(form_data["name"]).strip()
    url = str(form_data["url"]).strip()
    api_key = str(form_data["api_key"]).strip()
    allow_missing_port = bool(form_data.get("allow_missing_port"))

    if not name:
        errors.append("Name is required.")
    if not url:
        errors.append("URL is required.")
    else:
        errors.extend(validate_agent_url_for_manual_form(url=url, allow_missing_port=allow_missing_port))
    if require_api_key and not api_key:
        errors.append("API key is required.")

    warning_threshold = parse_threshold(form_data["warning_threshold"], "Warning threshold", errors)
    critical_threshold = parse_threshold(form_data["critical_threshold"], "Critical threshold", errors)
    if warning_threshold is not None and critical_threshold is not None:
        if warning_threshold >= critical_threshold:
            errors.append("Warning threshold must be lower than critical threshold.")

    if errors:
        return errors, {}

    values["name"] = name
    values["url"] = url
    values["api_key"] = api_key
    values["warning_threshold"] = warning_threshold
    values["critical_threshold"] = critical_threshold
    values["enabled"] = bool(form_data["enabled"])
    values["allow_missing_port"] = allow_missing_port
    return errors, values


def validate_agent_url_for_manual_form(url: str, allow_missing_port: bool) -> list[str]:
    base_error = validate_agent_temperature_url(url, require_port=False)
    if base_error:
        return [base_error]

    parsed = urlparse(url)
    try:
        parsed_port = parsed.port
    except ValueError:
        return ["Agent URL port is invalid."]

    host = parsed.hostname or ""
    if parsed_port is None and host_is_ip_address(host) and not allow_missing_port:
        return [
            "Agent URL should include the agent port, for example "
            "http://192.168.4.2:8090/temperature."
        ]

    return []


def parse_optional_int(value: object) -> Optional[int]:
    try:
        if value is None or str(value).strip() == "":
            return None
        return int(str(value))
    except (TypeError, ValueError):
        return None


def bool_from_payload(value: object) -> bool:
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


async def test_agent_connection(url: str, api_key: str) -> dict[str, object]:
    try:
        async with httpx.AsyncClient(timeout=ADMIN_TEST_TIMEOUT_SECONDS) as client:
            response = await client.get(url, headers={"X-API-Key": api_key})
        response.raise_for_status()
        payload = response.json()
    except httpx.TimeoutException:
        return {"ok": False, "error": "Connection timed out."}
    except httpx.ConnectError:
        return {"ok": False, "error": "Connection refused or unreachable."}
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code == status.HTTP_401_UNAUTHORIZED:
            return {"ok": False, "error": "Unauthorized. Check the API key."}
        excerpt = safe_response_excerpt(exc.response.text)
        message = f"Agent returned HTTP {exc.response.status_code}."
        if excerpt:
            message = f"{message} {excerpt}"
        return {"ok": False, "error": message}
    except httpx.RequestError:
        return {"ok": False, "error": "Request failed."}
    except ValueError:
        return {"ok": False, "error": "Invalid JSON from agent."}

    temperature = payload.get("temperature") if isinstance(payload, dict) else None
    if temperature is None or not is_numeric_value(temperature):
        return {"ok": False, "error": "Agent response did not include a numeric temperature."}

    return {
        "ok": True,
        "temperature": float(str(temperature)),
        "unit": str(payload.get("unit", "C")) if isinstance(payload, dict) else "C",
    }


def safe_response_excerpt(text: str, max_length: int = 180) -> str:
    cleaned = " ".join(str(text or "").split())
    if not cleaned:
        return ""
    return cleaned[:max_length]


def is_numeric_value(value: object) -> bool:
    try:
        number = float(str(value))
    except (TypeError, ValueError):
        return False
    return math.isfinite(number)


def parse_threshold(value: object, label: str, errors: list[str]) -> Optional[float]:
    try:
        threshold = float(str(value))
    except ValueError:
        errors.append(f"{label} must be numeric.")
        return None

    if not math.isfinite(threshold):
        errors.append(f"{label} must be numeric.")
        return None

    return threshold


def render_server_form(
    request: Request,
    settings,
    mode: str,
    form_data: dict[str, object],
    errors: list[str],
    server_id: Optional[int] = None,
    masked_api_key: Optional[str] = None,
    status_code: int = status.HTTP_200_OK,
) -> Response:
    return templates.TemplateResponse(
        "admin_server_form.html",
        {
            "request": request,
            "settings": settings,
            "mode": mode,
            "form_data": form_data,
            "errors": errors,
            "server_id": server_id,
            "masked_api_key": masked_api_key,
            "csrf_token": get_csrf_token(request),
        },
        status_code=status_code,
    )


def pairing_form_data_from_form(request: Request, form: dict[str, list[str]]) -> dict[str, object]:
    return {
        "server_name": get_form_value(form, "server_name").strip(),
        "platform": get_form_value(form, "platform").strip(),
        "thermo_url": get_effective_public_url(request),
        "bind_host": get_form_value(form, "bind_host").strip(),
        "agent_port": get_form_value(form, "agent_port").strip(),
        "warning_threshold": get_form_value(form, "warning_threshold").strip(),
        "critical_threshold": get_form_value(form, "critical_threshold").strip(),
    }


def pairing_form_data_from_model(pairing: PairingToken, thermo_url: str) -> dict[str, object]:
    return {
        "server_name": pairing.server_name,
        "platform": pairing.platform,
        "thermo_url": thermo_url,
        "bind_host": pairing.bind_host,
        "agent_port": str(pairing.agent_port),
        "warning_threshold": format_threshold(pairing.warning_threshold),
        "critical_threshold": format_threshold(pairing.critical_threshold),
    }


def render_agent_setup_form(
    request: Request,
    settings,
    form_data: dict[str, object],
    errors: list[str],
    status_code: int = status.HTTP_200_OK,
) -> Response:
    with session_scope() as session:
        active_pairings = list_active_pairings(session)

    return templates.TemplateResponse(
        "admin_agent_setup.html",
        {
            "request": request,
            "settings": settings,
            "form_data": form_data,
            "errors": errors,
            "active_pairings": active_pairings,
            "platform_choices": PLATFORM_CHOICES,
            "pairing_ttl_minutes": settings.pairing_token_ttl_minutes,
            "public_url_is_fallback": settings.public_url is None,
            "effective_public_url": get_effective_public_url(request),
            "csrf_token": get_csrf_token(request),
        },
        status_code=status_code,
    )


def render_agent_setup_detail(
    request: Request,
    settings,
    pairing: PairingToken,
    install_commands: Optional[dict[str, str]],
    status_payload: Optional[dict[str, object]] = None,
    status_code: int = status.HTTP_200_OK,
) -> Response:
    return templates.TemplateResponse(
        "admin_agent_setup_detail.html",
        {
            "request": request,
            "settings": settings,
            "pairing": pairing,
            "status": status_payload or pairing_status_payload(pairing),
            "install_commands": install_commands,
            "effective_public_url": get_effective_public_url(request),
            "target_agent_url_preview": f"http://TARGET-IP:{pairing.agent_port}/temperature",
            "csrf_token": get_csrf_token(request),
        },
        status_code=status_code,
    )


def mask_api_key(api_key: str) -> str:
    suffix = api_key[-4:] if len(api_key) >= 4 else api_key
    return f"********{suffix}"


def format_threshold(value: float) -> str:
    if float(value).is_integer():
        return str(int(value))
    return str(value)


app = create_app()
