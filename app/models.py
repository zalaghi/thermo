from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import Boolean, DateTime, Float, ForeignKey, Integer, String, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    username: Mapped[str] = mapped_column(String(150), unique=True, index=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)


class Server(Base):
    __tablename__ = "servers"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(150), nullable=False)
    url: Mapped[str] = mapped_column(String(500), nullable=False)
    api_key: Mapped[str] = mapped_column(Text, nullable=False)
    warning_threshold: Mapped[float] = mapped_column(Float, default=65.0, nullable=False)
    critical_threshold: Mapped[float] = mapped_column(Float, default=80.0, nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=utc_now,
        onupdate=utc_now,
        nullable=False,
    )

    latest_status: Mapped[Optional["LatestStatus"]] = relationship(
        back_populates="server",
        cascade="all, delete-orphan",
    )


class LatestStatus(Base):
    __tablename__ = "latest_status"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    server_id: Mapped[int] = mapped_column(ForeignKey("servers.id"), unique=True, nullable=False)
    temperature: Mapped[Optional[float]] = mapped_column(Float)
    status: Mapped[str] = mapped_column(String(50), nullable=False)
    error: Mapped[Optional[str]] = mapped_column(Text)
    checked_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)

    server: Mapped[Server] = relationship(back_populates="latest_status")


class PairingToken(Base):
    __tablename__ = "pairing_tokens"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True, nullable=False)
    platform: Mapped[str] = mapped_column(String(50), nullable=False)
    server_name: Mapped[str] = mapped_column(String(150), nullable=False)
    bind_host: Mapped[str] = mapped_column(String(255), nullable=False)
    agent_port: Mapped[int] = mapped_column(Integer, nullable=False)
    warning_threshold: Mapped[float] = mapped_column(Float, default=65.0, nullable=False)
    critical_threshold: Mapped[float] = mapped_column(Float, default=80.0, nullable=False)
    server_id: Mapped[Optional[int]] = mapped_column(ForeignKey("servers.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    used_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
