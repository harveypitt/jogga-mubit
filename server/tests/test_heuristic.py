"""Heuristic coach: pacing classification, alternation, frequency."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession

from jogga.coach import heuristic_coach
from jogga.fitness import run_shape
from jogga.models import CoachNote, Run, Target, User


def _split(pace: float, km: float = 1000.0) -> dict[str, float]:
    return {"distance_m": km, "moving_s": pace * (km / 1000.0), "gain_m": 0.0, "loss_m": 0.0}


def test_shape_steady() -> None:
    assert run_shape([_split(320), _split(322), _split(319), _split(321)]) == "steady"


def test_shape_faded() -> None:
    assert run_shape([_split(300), _split(300), _split(340), _split(340)]) == "faded"


def test_shape_sped_up() -> None:
    assert run_shape([_split(340), _split(340), _split(300), _split(300)]) == "sped_up"


def test_shape_uneven() -> None:
    # Halves match on average (no trend) but the spread is huge.
    assert run_shape([_split(280), _split(360), _split(360), _split(280)]) == "uneven"


def test_shape_hill_not_a_fade() -> None:
    # Raw pace fades 300 -> 340, but the late splits climbed ~40 m/km, so
    # hill-adjusted pace is flat: this is steady, not a fade.
    splits = [
        {"distance_m": 1000.0, "moving_s": 300.0, "gain_m": 0.0, "loss_m": 0.0},
        {"distance_m": 1000.0, "moving_s": 300.0, "gain_m": 0.0, "loss_m": 0.0},
        {"distance_m": 1000.0, "moving_s": 340.0, "gain_m": 40.0, "loss_m": 0.0},
        {"distance_m": 1000.0, "moving_s": 340.0, "gain_m": 40.0, "loss_m": 0.0},
    ]
    assert run_shape(splits) == "steady"


def _run(user: User, *, kind_marker: str = "") -> Run:
    return Run(
        id=uuid.uuid4(),
        user_id=user.id,
        started_at=datetime.now(UTC),
        distance_m=5000.0,
        moving_s=1600.0,
        elapsed_s=1600.0,
        gain_m=0.0,
        loss_m=0.0,
        splits=[_split(320) for _ in range(5)],
        efforts={"5k": 1600.0},
    )


@pytest_asyncio.fixture
async def user(session: AsyncSession) -> User:
    u = User(display_name="R")
    session.add(u)
    await session.flush()
    session.add(Target(user_id=u.id, distance="5k", target_s=1400))
    await session.flush()
    return u


async def test_next_run_easy_after_other(session: AsyncSession, user: User) -> None:
    run = _run(user)
    session.add(run)
    await session.flush()
    out = await heuristic_coach(session, run, previous_note=None)
    # target pace = 280 s/km; easy pace = 340, km = 5 * 0.8 = 4.0
    assert out.next.kind == "easy"
    assert out.next.km == 4.0
    assert out.next.pace == 340
    assert out.frequency.runs_per_week in (3, 4)


async def test_next_run_tempo_after_easy(session: AsyncSession, user: User) -> None:
    run = _run(user)
    session.add(run)
    await session.flush()
    older = _run(user)
    session.add(older)
    await session.flush()
    prev = CoachNote(
        run_id=older.id,
        user_id=user.id,
        source="heuristic",
        model=None,
        payload={
            "feedback": "x",
            "pacing": "even",
            "next": {"km": 4.0, "pace": 340, "kind": "easy", "detail": "d", "why": "w"},
            "frequency": {"runs_per_week": 3, "note": "n"},
        },
    )
    session.add(prev)
    await session.flush()
    out = await heuristic_coach(session, run, previous_note=prev)
    # tempo: km = min(5,5)*0.8 = 4.0, pace = 280 + 5 = 285
    assert out.next.kind == "tempo"
    assert out.next.km == 4.0
    assert out.next.pace == 285


async def test_no_targets_easy_default(session: AsyncSession) -> None:
    u = User(display_name="R2")
    session.add(u)
    await session.flush()
    run = _run(u)
    session.add(run)
    await session.flush()
    out = await heuristic_coach(session, run, previous_note=None)
    assert out.next.kind == "easy"
    assert out.next.km == 5.0
    assert out.next.pace == 320 + 30


async def test_feedback_compares_to_recent_best(session: AsyncSession, user: User) -> None:
    now = datetime.now(UTC)
    for days, effort in ((100, 1300.0), (5, 1500.0)):
        old = _run(user)
        old.started_at = now - timedelta(days=days)
        old.efforts = {"5k": effort}
        session.add(old)
    run = _run(user)
    session.add(run)
    await session.flush()
    out = await heuristic_coach(session, run, previous_note=None)
    assert out.feedback.endswith("effort was 1:40 off your recent best of 25:00.")
