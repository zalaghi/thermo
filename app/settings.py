import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEV_SECRET_KEY = "thermo-dev-secret-key-change-me"
PLACEHOLDER_SECRET_KEYS = {
    "change-me-to-a-long-random-secret",
    "replace-with-a-long-random-secret",
}
DEFAULT_ADMIN_PASSWORD = "change-me-now"


@dataclass(frozen=True)
class Settings:
    app_name: str
    environment: str
    database_path: Path
    secret_key: str
    secret_key_is_fallback: bool
    secret_key_is_placeholder: bool
    admin_username: str
    admin_password: str
    admin_password_is_default: bool
    poll_interval_seconds: float


def _path_from_env(name: str, default: Path) -> Path:
    value = os.getenv(name)
    if not value:
        return default
    return Path(value).expanduser()


def _float_from_env(name: str, default: float) -> float:
    value = os.getenv(name)
    if not value:
        return default
    try:
        parsed_value = float(value)
    except ValueError:
        return default
    if parsed_value <= 0:
        return default
    return parsed_value


@lru_cache
def get_settings() -> Settings:
    secret_key = os.getenv("THERMO_SECRET_KEY")
    admin_password = os.getenv("THERMO_ADMIN_PASSWORD", DEFAULT_ADMIN_PASSWORD)
    return Settings(
        app_name=os.getenv("THERMO_APP_NAME", "Thermo"),
        environment=os.getenv("THERMO_ENV", "development"),
        database_path=_path_from_env(
            "THERMO_DB_PATH",
            _path_from_env("THERMO_DATABASE_PATH", Path("/data/thermo.db")),
        ),
        secret_key=secret_key or DEV_SECRET_KEY,
        secret_key_is_fallback=not bool(secret_key),
        secret_key_is_placeholder=bool(secret_key in PLACEHOLDER_SECRET_KEYS),
        admin_username=os.getenv("THERMO_ADMIN_USER", "admin"),
        admin_password=admin_password,
        admin_password_is_default=admin_password == DEFAULT_ADMIN_PASSWORD,
        poll_interval_seconds=_float_from_env("THERMO_POLL_INTERVAL", 5.0),
    )
