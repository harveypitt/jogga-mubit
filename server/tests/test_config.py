"""DATABASE_URL normalisation and OPENROUTER_API_KEY validation."""

import importlib
import os

from jogga import config
from jogga.config import db_url


def _reload_config(monkeypatch: object, key: str | None) -> None:
    if key is None:
        os.environ.pop("OPENROUTER_API_KEY")
    else:
        os.environ["OPENROUTER_API_KEY"] = key
    importlib.reload(config)


def test_malformed_key(monkeypatch: object) -> None:
    try:
        _reload_config(monkeypatch, "- sk-or-v1-abc -")
        assert config.OPENROUTER_API_KEY is None
        assert config.OPENROUTER_KEY_MALFORMED
    finally:
        _reload_config(monkeypatch, None)


def test_padded_valid_key_stripped(monkeypatch: object) -> None:
    try:
        _reload_config(monkeypatch, "  sk-or-v1-abc123  ")
        assert config.OPENROUTER_API_KEY == "sk-or-v1-abc123"
        assert not config.OPENROUTER_KEY_MALFORMED
    finally:
        _reload_config(monkeypatch, None)


def test_postgres_scheme_to_asyncpg() -> None:
    assert db_url("postgres://u:p@h:5432/db", "asyncpg") == ("postgresql+asyncpg://u:p@h:5432/db")


def test_postgresql_scheme_to_psycopg2() -> None:
    assert db_url("postgresql://u:p@h:5432/db", "psycopg2") == (
        "postgresql+psycopg2://u:p@h:5432/db"
    )


def test_driver_scheme_normalised() -> None:
    assert db_url("postgresql+asyncpg://u:p@h/db", "asyncpg") == ("postgresql+asyncpg://u:p@h/db")
    assert db_url("postgresql+psycopg2://u:p@h/db", "asyncpg") == ("postgresql+asyncpg://u:p@h/db")


def test_sslmode_becomes_ssl_for_asyncpg() -> None:
    assert db_url("postgresql://u:p@h/db?sslmode=require", "asyncpg") == (
        "postgresql+asyncpg://u:p@h/db?ssl=require"
    )


def test_ssl_becomes_sslmode_for_psycopg2() -> None:
    assert db_url("postgresql://u:p@h/db?ssl=verify-full", "psycopg2") == (
        "postgresql+psycopg2://u:p@h/db?sslmode=verify-full"
    )


def test_other_params_preserved() -> None:
    url = db_url("postgresql://u:p@h:5433/db?sslmode=require&connect_timeout=10", "asyncpg")
    assert url == "postgresql+asyncpg://u:p@h:5433/db?ssl=require&connect_timeout=10"


def test_urlencoded_password_preserved() -> None:
    url = db_url("postgresql://user:p%40ss@host/db?sslmode=prefer", "asyncpg")
    assert url == "postgresql+asyncpg://user:p%40ss@host/db?ssl=prefer"
