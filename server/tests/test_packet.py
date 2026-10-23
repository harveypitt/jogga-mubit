"""Packet builder shape and size."""

import json
from datetime import UTC, datetime, timedelta

import pytest
import pytest_asyncio
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from jogga.models import CoachNote, Run, Target, User
from jogga.packet import build_packet


@pytest_asyncio.fixture
async def seeded(session: AsyncSession) -> tuple[User, Run]:
    user = User(display_name="Runner")
    session.add(user)
    await session.flush()
    session.add(Target(user_id=user.id, distance="5k", target_s=1500))
    # Fixed datetimes so week-bucketing assertions are deterministic:
    # 2026-09-30 is a Wednesday, so both runs sit in the week of Mon 2026-09-28.
    run = Run(
        user_id=user.id,
        started_at=datetime(2026, 9, 30, 10, 0, tzinfo=UTC),
        distance_m=5040.0,
        moving_s=1640.0,
        elapsed_s=1680.0,
        gain_m=38.0,
        loss_m=35.0,
        splits=[
            {"distance_m": 1000.0, "moving_s": 318.0, "gain_m": 2.0, "loss_m": 5.0},
            {"distance_m": 1000.0, "moving_s": 331.0, "gain_m": 12.0, "loss_m": 1.0},
            {"distance_m": 1000.0, "moving_s": 325.0, "gain_m": 8.0, "loss_m": 6.0},
            {"distance_m": 1000.0, "moving_s": 328.0, "gain_m": 6.0, "loss_m": 10.0},
            {"distance_m": 1000.0, "moving_s": 326.0, "gain_m": 10.0, "loss_m": 13.0},
            {"distance_m": 40.0, "moving_s": 12.0, "gain_m": 0.0, "loss_m": 0.0},
        ],
        efforts={"5k": 1620.0},
    )
    session.add(run)
    older = Run(
        user_id=user.id,
        started_at=datetime(2026, 9, 28, 7, 0, tzinfo=UTC),
        distance_m=5020.0,
        moving_s=1655.0,
        elapsed_s=1690.0,
        gain_m=42.0,
        loss_m=40.0,
        splits=[],
        efforts={"5k": 1655.0},
    )
    session.add(older)
    await session.flush()
    return user, run


async def test_packet_shape(session: AsyncSession, seeded: tuple[User, Run]) -> None:
    _, run = seeded
    packet = json.loads(await build_packet(session, run))
    assert packet["v"] == 6
    assert packet["u"] == {"km": "km", "t": "m:ss|h:mm:ss", "pace": "m:ss/km", "elev": "m"}
    assert packet["today"] == run.started_at.date().isoformat()
    assert packet["hist"] == {"runs": 1, "first": "2026-09-28", "rest_d": 2}
    (goal,) = packet["goals"]
    # pb/last/n describe history before this run, so only the older run counts.
    assert list(goal.keys()) == ["d", "target", "tpace", "pb", "pb_d", "last", "n", "n4w"]
    assert goal["d"] == "5k" and goal["target"] == "25:00" and goal["tpace"] == "5:00"
    assert goal["pb"] == "27:35" and goal["last"] == "27:35"
    assert goal["n"] == 1 and goal["n4w"] == 1
    assert packet["recent"]["cols"] == ["date", "d", "km", "t", "pace", "gain"]
    assert len(packet["recent"]["rows"]) == 1
    assert packet["recent"]["rows"][0][1] == "5k"
    # older run: 1655 s over 5.02 km -> 27:35 at 5:30/km
    assert packet["recent"]["rows"][0][3:5] == ["27:35", "5:30"]
    assert packet["run"]["d"] == "5k"
    assert packet["run"]["mode"] is None
    assert list(packet["run"].keys()) == [
        "date",
        "mode",
        "d",
        "km",
        "t",
        "el",
        "pace",
        "gain",
        "loss",
        "shape",
        "eff",
        "splits",
    ]
    assert packet["run"]["shape"] == "steady"
    assert packet["run"]["t"] == "27:20" and packet["run"]["el"] == "28:00"
    assert packet["run"]["pace"] == "5:25"
    assert packet["run"]["eff"] == {
        "cols": ["d", "t", "vs_target", "vs_pb"],
        "rows": [["5k", "27:00", "+2:00", "-0:35"]],
    }
    assert packet["run"]["splits"]["cols"] == ["km", "t", "pace", "flat", "gain", "loss"]
    # Split 1: factor = 1 + 3.3*0.002 - 1.8*0.005 = 0.9976 -> flat 5:19.
    assert packet["run"]["splits"]["rows"][0] == [1.0, "5:18", "5:18", "5:19", 2, 5]
    assert packet["run"]["splits"]["rows"][-1][0] == 0.04
    assert packet["load4w"]["runs"] == 1
    assert packet["day"] == {"runs": 1, "km": 5.04}
    assert packet["wk"]["cols"] == ["wk", "runs", "km"]
    assert len(packet["wk"]["rows"]) == 8
    # Both runs share the ISO week starting Monday 2026-09-28.
    assert packet["wk"]["rows"][-1] == ["2026-09-28", 2, 10.06]
    assert packet["wk"]["rows"][-2][1] == 0
    assert packet["streak"] == 1
    assert packet["long4w"] == 5.04
    # fit: best 5K-equivalent is today's 5k effort (1620) over the whole runs.
    assert packet["fit"]["src"] == ["2026-09-30", "5k", 5.0, "27:00"]
    assert packet["fit"]["pred"]["10k"] == "56:18"
    assert packet["fit"]["zones"]["easy"] == ["6:29", "7:01"]
    assert packet["prev"] is None
    assert packet["past"] is None
    assert list(packet.keys()) == [
        "v",
        "u",
        "today",
        "hist",
        "past",
        "goals",
        "fit",
        "load4w",
        "long4w",
        "wk",
        "streak",
        "day",
        "recent",
        "prev",
        "run",
    ]


async def test_packet_hist_first_run(session: AsyncSession) -> None:
    user = User(display_name="R")
    session.add(user)
    await session.flush()
    run = _mk_run(user.id, datetime(2026, 9, 30, 10, 0, tzinfo=UTC))
    session.add(run)
    await session.flush()
    packet = json.loads(await build_packet(session, run))
    assert packet["hist"] == {"runs": 0, "first": None, "rest_d": None}
    assert packet["fit"] is not None  # the run itself is a candidate
    assert packet["prev"] is None


async def test_packet_prev_plan(session: AsyncSession, seeded: tuple[User, Run]) -> None:
    user, run = seeded
    run.mode = "plan"
    older = (await session.execute(select(Run).where(Run.id != run.id))).scalar_one()
    session.add(
        CoachNote(
            run_id=older.id,
            user_id=user.id,
            source="heuristic",
            payload={
                "feedback": "f",
                "pacing": "even",
                "next": {"km": 4.0, "pace": 340, "kind": "easy", "detail": "d", "why": "w"},
                "frequency": {"runs_per_week": 3, "note": "n"},
            },
        )
    )
    await session.flush()
    packet = json.loads(await build_packet(session, run))
    assert packet["run"]["mode"] == "plan"
    assert packet["prev"] == {"plan": ["easy", 4.0, "5:40"], "did": [5.04, "5:25"]}


async def _add_previous_plan(session: AsyncSession, user: User, run: Run) -> None:
    older = (await session.execute(select(Run).where(Run.id != run.id))).scalar_one()
    session.add(
        CoachNote(
            run_id=older.id,
            user_id=user.id,
            source="heuristic",
            payload={
                "feedback": "f",
                "pacing": "even",
                "next": {"km": 4.0, "pace": 340, "kind": "easy", "detail": "d", "why": "w"},
                "frequency": {"runs_per_week": 3, "note": "n"},
            },
        )
    )
    await session.flush()


async def test_packet_prev_legacy_mode_none(
    session: AsyncSession, seeded: tuple[User, Run]
) -> None:
    user, run = seeded
    await _add_previous_plan(session, user, run)

    packet = json.loads(await build_packet(session, run))
    assert packet["run"]["mode"] is None
    assert packet["prev"] == {"plan": ["easy", 4.0, "5:40"], "did": [5.04, "5:25"]}


@pytest.mark.parametrize("mode", ["free", "race"])
async def test_packet_prev_is_null_for_unprescribed_modes(
    session: AsyncSession, seeded: tuple[User, Run], mode: str
) -> None:
    user, run = seeded
    run.mode = mode
    await _add_previous_plan(session, user, run)

    packet = json.loads(await build_packet(session, run))
    assert packet["run"]["mode"] == mode
    assert packet["prev"] is None


async def test_packet_history_counts_imported_runs(session: AsyncSession) -> None:
    user = User(display_name="Runner")
    session.add(user)
    await session.flush()
    imported = _mk_run(user.id, datetime(2026, 9, 28, 7, 0, tzinfo=UTC))
    imported.source = "strava"
    run = _mk_run(user.id, datetime(2026, 9, 30, 10, 0, tzinfo=UTC))
    session.add_all([imported, run])
    await session.flush()

    packet = json.loads(await build_packet(session, run))
    assert packet["hist"] == {"runs": 1, "first": "2026-09-28", "rest_d": 2}


def _mk_run(
    user_id: object,
    started_at: datetime,
    km: float = 5.0,
) -> Run:
    return Run(
        user_id=user_id,
        started_at=started_at,
        distance_m=km * 1000,
        moving_s=km * 320,
        elapsed_s=km * 320,
        gain_m=0.0,
        loss_m=0.0,
        splits=[],
        efforts={},
    )


async def test_streak_and_zero_week(session: AsyncSession) -> None:
    # Runs in the week of Sep 7 (3 wks ago), a gap in Sep 14 week, then the
    # weeks of Sep 21 and Sep 28 -> streak 2 with a zero row two weeks back.
    user = User(display_name="R")
    session.add(user)
    await session.flush()
    anchor = datetime(2026, 9, 30, 10, 0, tzinfo=UTC)
    for days_ago in (22, 8, 1):
        session.add(_mk_run(user.id, anchor - timedelta(days=days_ago)))
    run = _mk_run(user.id, anchor)
    session.add(run)
    await session.flush()
    packet = json.loads(await build_packet(session, run))
    assert packet["streak"] == 2
    rows = {row[0]: row for row in packet["wk"]["rows"]}
    assert rows["2026-09-14"][1] == 0  # gap week
    assert rows["2026-09-07"][1] == 1
    assert rows["2026-09-21"][1] == 1
    assert rows["2026-09-28"][1] == 2
    assert packet["long4w"] == 5.0


async def test_day_counts_same_day_runs(session: AsyncSession) -> None:
    user = User(display_name="R")
    session.add(user)
    await session.flush()
    morning = datetime(2026, 9, 30, 7, 0, tzinfo=UTC)
    first_run = _mk_run(user.id, morning, km=5.0)
    session.add(first_run)
    evening = _mk_run(user.id, morning + timedelta(hours=12), km=6.0)
    session.add(evening)
    await session.flush()
    packet = json.loads(await build_packet(session, evening))
    assert packet["day"] == {"runs": 2, "km": 11.0}
    # The morning run's own packet only sees itself — the evening run is later.
    first = json.loads(await build_packet(session, first_run))
    assert first["day"]["runs"] == 1


async def test_packet_compact(session: AsyncSession, seeded: tuple[User, Run]) -> None:
    _, run = seeded
    raw = await build_packet(session, run)
    assert '": ' not in raw and '", ' not in raw
    assert len(raw) < 4000


async def test_packet_past_years(session: AsyncSession, seeded: tuple[User, Run]) -> None:
    user, run = seeded
    for started, km, five in [
        (datetime(2024, 1, 10, 9, 0, tzinfo=UTC), 5.2, 1700.0),
        (datetime(2024, 3, 2, 9, 0, tzinfo=UTC), 4.1, None),
        (datetime(2025, 5, 1, 9, 0, tzinfo=UTC), 6.0, 1610.0),
        # Inside the 8-week window: counted in `wk`, not `past`.
        (datetime(2026, 9, 1, 9, 0, tzinfo=UTC), 5.0, 1500.0),
    ]:
        session.add(
            Run(
                user_id=user.id,
                started_at=started,
                distance_m=km * 1000,
                moving_s=km * 330,
                elapsed_s=km * 330,
                gain_m=0.0,
                loss_m=0.0,
                splits=[],
                efforts={"5k": five} if five else {},
                source="strava",
                external_id=str(started.timestamp()),
            )
        )
    await session.flush()
    packet = json.loads(await build_packet(session, run))
    assert packet["past"] == {
        "cols": ["yr", "runs", "km", "best5k"],
        "rows": [[2024, 2, 9.3, "28:20"], [2025, 1, 6.0, "26:50"]],
    }


async def test_fit_uses_recent_runs_not_old_peak(session: AsyncSession) -> None:
    user = User(display_name="R")
    session.add(user)
    await session.flush()
    now = datetime(2026, 9, 30, 10, 0, tzinfo=UTC)
    peak = _mk_run(user.id, now - timedelta(days=30))
    peak.moving_s = 1300.0
    peak.efforts = {"5k": 1300.0}
    session.add(peak)
    for i in range(1, 11):
        session.add(_mk_run(user.id, now - timedelta(days=i)))
    run = _mk_run(user.id, now)
    session.add(run)
    await session.flush()
    packet = json.loads(await build_packet(session, run))
    # The 30-day-old peak is outside the last 10 runs and the last 3 weeks.
    assert packet["fit"]["src"] == ["2026-09-30", None, 5.0, "26:40"]
    goal = packet["goals"][0]
    assert goal["pb"] == "21:40" and goal["pb_d"] == "2026-08-31"


async def test_fit_keeps_last_three_weeks(session: AsyncSession) -> None:
    user = User(display_name="R")
    session.add(user)
    await session.flush()
    now = datetime(2026, 9, 30, 10, 0, tzinfo=UTC)
    fast = _mk_run(user.id, now - timedelta(days=15))
    fast.moving_s = 1500.0
    session.add(fast)
    for i in range(1, 13):
        session.add(_mk_run(user.id, now - timedelta(days=i)))
    old = _mk_run(user.id, now - timedelta(days=43))
    old.moving_s = 1200.0
    session.add(old)
    run = _mk_run(user.id, now)
    session.add(run)
    await session.flush()
    packet = json.loads(await build_packet(session, run))
    # More than 10 runs back but within 3 weeks still counts; over 6 weeks never does.
    assert packet["fit"]["src"] == ["2026-09-15", None, 5.0, "25:00"]
