from __future__ import annotations

import mimetypes
import os
import re
import secrets
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

from fastapi import UploadFile
from sqlalchemy import select
from sqlalchemy.orm import Session

from .db import session_scope
from .models import AppSetting
from .settings import PROJECT_ROOT, get_settings


DEFAULT_ACCENT_COLOR = "#72d6a3"
DEFAULT_BACKGROUND_COLOR = "#0d0f10"
MAX_BRANDING_UPLOAD_BYTES = 1024 * 1024
BRANDING_UPLOAD_PREFIX = "/uploads/branding/"
SETTING_KEYS = {
    "app_name",
    "public_url",
    "accent_color",
    "favicon_path",
    "app_icon_path",
    "header_icon_path",
}
UPLOAD_SETTING_FIELDS = {
    "favicon": "favicon_path",
    "app_icon": "app_icon_path",
    "header_icon": "header_icon_path",
}
ALLOWED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".svg", ".ico", ".webp"}
ALLOWED_IMAGE_TYPES = {
    "image/png",
    "image/jpeg",
    "image/svg+xml",
    "image/x-icon",
    "image/vnd.microsoft.icon",
    "image/webp",
    "application/octet-stream",
}
HEX_COLOR_PATTERN = re.compile(r"^#[0-9a-fA-F]{6}$")


@dataclass(frozen=True)
class EffectiveAppConfig:
    app_name: str
    public_url: str
    public_url_source: str
    accent_color: str
    accent_soft_color: str
    favicon_path: str
    app_icon_path: str
    header_icon_path: str


@dataclass(frozen=True)
class SettingsFormResult:
    values: dict[str, str]
    errors: list[str]
    warnings: list[str]


def get_effective_app_config(current_request_url: str = "") -> EffectiveAppConfig:
    settings = get_settings()
    db_values = load_app_settings()
    env_public_url = settings.public_url or ""
    request_public_url = current_request_url.rstrip("/")

    public_url = normalize_public_url(db_values.get("public_url", ""))
    public_url_source = "database"
    if not public_url:
        public_url = normalize_public_url(env_public_url)
        public_url_source = "environment"
    if not public_url:
        public_url = request_public_url
        public_url_source = "request"

    app_name = first_nonempty(db_values.get("app_name"), os.getenv("THERMO_APP_NAME"), settings.app_name, "Thermo")
    accent_color = normalize_hex_color(
        first_nonempty(db_values.get("accent_color"), os.getenv("THERMO_ACCENT_COLOR"), DEFAULT_ACCENT_COLOR)
    )

    return EffectiveAppConfig(
        app_name=app_name,
        public_url=public_url,
        public_url_source=public_url_source,
        accent_color=accent_color,
        accent_soft_color=hex_to_rgba(accent_color, 0.14),
        favicon_path=first_nonempty(db_values.get("favicon_path"), os.getenv("THERMO_FAVICON_PATH"), ""),
        app_icon_path=first_nonempty(db_values.get("app_icon_path"), os.getenv("THERMO_APP_ICON_PATH"), ""),
        header_icon_path=first_nonempty(db_values.get("header_icon_path"), os.getenv("THERMO_HEADER_ICON_PATH"), ""),
    )


def load_app_settings(session: Optional[Session] = None) -> dict[str, str]:
    if session is not None:
        return load_app_settings_from_session(session)
    with session_scope() as scoped_session:
        return load_app_settings_from_session(scoped_session)


def load_app_settings_from_session(session: Session) -> dict[str, str]:
    rows = session.scalars(select(AppSetting).where(AppSetting.key.in_(SETTING_KEYS))).all()
    return {row.key: row.value for row in rows}


def save_app_setting(session: Session, key: str, value: str) -> None:
    if key not in SETTING_KEYS:
        raise ValueError(f"Unsupported setting key: {key}")
    cleaned_value = str(value or "").strip()
    existing = session.get(AppSetting, key)
    if not cleaned_value:
        if existing:
            session.delete(existing)
        return
    if existing:
        existing.value = cleaned_value
    else:
        session.add(AppSetting(key=key, value=cleaned_value))


def validate_settings_form(values: dict[str, str]) -> SettingsFormResult:
    errors: list[str] = []
    warnings: list[str] = []
    cleaned: dict[str, str] = {}

    cleaned["app_name"] = str(values.get("app_name", "")).strip()
    if not cleaned["app_name"]:
        warnings.append("App name is empty, so Thermo will use the environment/default name.")

    raw_public_url = str(values.get("public_url", "")).strip().rstrip("/")
    if raw_public_url:
        if is_valid_public_url(raw_public_url):
            cleaned["public_url"] = raw_public_url
        else:
            cleaned["public_url"] = ""
            warnings.append("Public Thermo URL was not saved because it must start with http:// or https:// and include a host.")
    else:
        cleaned["public_url"] = ""
        warnings.append("Public Thermo URL is empty, so generated commands will use the environment or current request URL fallback.")

    raw_accent_color = str(values.get("accent_color", "")).strip()
    if raw_accent_color:
        if HEX_COLOR_PATTERN.fullmatch(raw_accent_color):
            cleaned["accent_color"] = raw_accent_color.lower()
        else:
            cleaned["accent_color"] = ""
            errors.append("Accent color must be a 6-digit hex color like #72d6a3.")
    else:
        cleaned["accent_color"] = DEFAULT_ACCENT_COLOR

    return SettingsFormResult(values=cleaned, errors=errors, warnings=warnings)


async def save_branding_upload(upload: UploadFile, setting_name: str) -> tuple[Optional[str], Optional[str]]:
    filename = Path(upload.filename or "").name
    if not filename:
        return None, None

    suffix = Path(filename).suffix.lower()
    if suffix not in ALLOWED_EXTENSIONS:
        return None, f"{setting_name} must be png, jpg, jpeg, svg, ico, or webp."

    content_type = (upload.content_type or "").lower()
    if content_type and content_type not in ALLOWED_IMAGE_TYPES:
        return None, f"{setting_name} has unsupported content type: {content_type}."

    content = await upload.read(MAX_BRANDING_UPLOAD_BYTES + 1)
    if len(content) > MAX_BRANDING_UPLOAD_BYTES:
        return None, f"{setting_name} must be 1 MB or smaller."
    if not content:
        return None, f"{setting_name} upload was empty."
    if suffix == ".svg" and not is_probably_safe_svg(content):
        return None, f"{setting_name} SVG contains unsupported active content."

    upload_dir = get_branding_upload_dir()
    upload_dir.mkdir(parents=True, exist_ok=True)
    safe_prefix = re.sub(r"[^a-z0-9_-]+", "-", setting_name.lower()).strip("-") or "branding"
    target = upload_dir / f"{safe_prefix}-{secrets.token_urlsafe(12)}{suffix}"
    if target.parent.resolve() != upload_dir.resolve():
        return None, f"{setting_name} upload path was invalid."

    target.write_bytes(content)
    return f"{BRANDING_UPLOAD_PREFIX}{target.name}", None


def get_branding_upload_dir() -> Path:
    settings = get_settings()
    database_parent = settings.database_path.parent
    if database_parent == Path("/data") or str(database_parent).startswith("/data/"):
        return database_parent / "uploads" / "branding"
    return PROJECT_ROOT / "data" / "uploads" / "branding"


def manifest_icon_type(path: str) -> str:
    content_type, _encoding = mimetypes.guess_type(path)
    return content_type or "image/png"


def is_probably_safe_svg(content: bytes) -> bool:
    lowered = content[:MAX_BRANDING_UPLOAD_BYTES].decode("utf-8", "ignore").lower()
    blocked_fragments = ("<script", "javascript:", " onload=", " onerror=")
    return not any(fragment in lowered for fragment in blocked_fragments)


def normalize_public_url(value: str) -> str:
    cleaned = str(value or "").strip().rstrip("/")
    if cleaned and is_valid_public_url(cleaned):
        return cleaned
    return ""


def is_valid_public_url(value: str) -> bool:
    if any(character.isspace() for character in value):
        return False
    parsed = urlparse(value)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def normalize_hex_color(value: str) -> str:
    cleaned = str(value or "").strip()
    if HEX_COLOR_PATTERN.fullmatch(cleaned):
        return cleaned.lower()
    return DEFAULT_ACCENT_COLOR


def hex_to_rgba(hex_color: str, alpha: float) -> str:
    cleaned = normalize_hex_color(hex_color).lstrip("#")
    red = int(cleaned[0:2], 16)
    green = int(cleaned[2:4], 16)
    blue = int(cleaned[4:6], 16)
    return f"rgba({red}, {green}, {blue}, {alpha})"


def first_nonempty(*values: object) -> str:
    for value in values:
        cleaned = str(value or "").strip()
        if cleaned:
            return cleaned
    return ""
