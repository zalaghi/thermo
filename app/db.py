from contextlib import contextmanager
from functools import lru_cache
from typing import Iterator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from .models import Base
from .settings import get_settings


def get_database_url() -> str:
    settings = get_settings()
    return f"sqlite:///{settings.database_path}"


@lru_cache
def get_engine():
    settings = get_settings()
    settings.database_path.parent.mkdir(parents=True, exist_ok=True)
    return create_engine(
        get_database_url(),
        connect_args={"check_same_thread": False},
    )


@lru_cache
def get_session_factory():
    return sessionmaker(bind=get_engine(), autoflush=False, autocommit=False, expire_on_commit=False)


def init_db() -> None:
    Base.metadata.create_all(bind=get_engine())


@contextmanager
def session_scope() -> Iterator[Session]:
    session = get_session_factory()()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()
