"""Test fixtures: real jogga_test Postgres, fresh tables per test."""

import os
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from typing import Any

os.environ["DATABASE_URL"] = "postgresql+asyncpg://localhost:5432/jogga_test"
os.environ["JOGGA_DEV_AUTH"] = "1"
os.environ.pop("OPENROUTER_API_KEY", None)
os.environ.pop("MUBIT_API_KEY", None)
os.environ.pop("JOGGA_MUBIT_URL", None)

import pytest_asyncio  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402
from sqlalchemy.ext.asyncio import (  # noqa: E402
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from jogga import config  # noqa: E402
from jogga.db import get_session  # noqa: E402
from jogga.main import app  # noqa: E402
from jogga.models import Base  # noqa: E402


@pytest_asyncio.fixture
async def session() -> AsyncIterator[AsyncSession]:
    engine = create_async_engine(config.DATABASE_URL)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as s:
        yield s
    await engine.dispose()


@pytest_asyncio.fixture
async def client(session: AsyncSession) -> AsyncIterator[AsyncClient]:
    async def override() -> AsyncIterator[AsyncSession]:
        yield session

    app.dependency_overrides[get_session] = override
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()


@pytest_asyncio.fixture
async def token(client: AsyncClient) -> str:
    resp = await client.post("/auth/dev", json={"name": "Dev Runner"})
    assert resp.status_code == 200
    return str(resp.json()["token"])


@pytest_asyncio.fixture
def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def run_payload(
    *,
    run_id: uuid.UUID | None = None,
    days_ago: float = 0,
    distance_m: float = 5020.0,
    moving_s: float = 1600.0,
    gain_m: float = 20.0,
    loss_m: float = 18.0,
    splits: list[dict[str, float]] | None = None,
    efforts: dict[str, float] | None = None,
) -> dict[str, Any]:
    started = datetime.now(UTC) - timedelta(days=days_ago)
    if splits is None:
        splits = [
            {"distance_m": 1000.0, "moving_s": 320.0, "gain_m": 5.0, "loss_m": 4.0}
            for _ in range(5)
        ] + [{"distance_m": 20.0, "moving_s": 6.0, "gain_m": 0.0, "loss_m": 0.0}]
    if efforts is None:
        efforts = {"5k": 1580.0}
    return {
        "id": str(run_id or uuid.uuid4()),
        "started_at": started.isoformat(),
        "distance_m": distance_m,
        "moving_s": moving_s,
        "elapsed_s": moving_s + 30,
        "gain_m": gain_m,
        "loss_m": loss_m,
        "splits": splits,
        "efforts": efforts,
    }
