"""Week plan: safety checks, the rules-based plan, run matching and replans."""

import json
import uuid
from datetime import UTC, date, datetime, time, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from jogga.coach import LLMResult
from jogga.models import User, WeekPlan
from jogga.planner import Facts, check_plan, facts, fallback_plan, match_runs, sync_plan
from jogga.weekly import load_context
from jogga.weeks import monday
from tests.conftest import run_payload

ZONES = {"easy": [380, 420], "steady": 350, "tempo": 320, "intervals": 300}
WEEK = date(2026, 10, 19)


def mk_facts(**kw: Any) -> Facts:
    base: dict[str, Any] = {
        "today": WEEK,
        "week_start": WEEK,
        "days_left": [WEEK + timedelta(days=i) for i in range(7)],
        "done": [],
        "long4w": 8.0,
        "avg4w_km": 20.0,
        "beginner": False,
        "zones": ZONES,
        "hard_dates": set(),
        "runs_per_week": 3,
        "typical_km": 5.0,
        "typical_pace": 400,
    }
    return Facts(**{**base, **kw})


def plan_json(*sessions: tuple[int, str, float, str], note: str = "Three easy runs.") -> str:
    return json.dumps(
        {
            "note": note,
            "change": "",
            "sessions": [
                {
                    "date": (WEEK + timedelta(days=d)).isoformat(),
                    "kind": kind,
                    "km": km,
                    "pace": pace,
                    "detail": "Easy and relaxed.",
                    "why": "Builds the base.",
                }
                for d, kind, km, pace in sessions
            ],
        }
    )


def test_valid_plan_passes() -> None:
    raw = plan_json((0, "easy", 5, "6:50"), (2, "tempo", 5, "5:20"), (5, "long", 8, "7:00"))
    sessions, note, _ = check_plan(raw, mk_facts())
    assert [s["kind"] for s in sessions] == ["easy", "tempo", "long"]
    assert sessions[1]["pace"] == 320 and note == "Three easy runs."


@pytest.mark.parametrize(
    ("raw", "kw", "why"),
    [
        (plan_json((1, "tempo", 5, "5:20"), (2, "intervals", 4, "5:00")), {}, "back to back"),
        (plan_json((1, "tempo", 5, "5:20")), {"hard_dates": {WEEK}}, "back to back"),
        (plan_json((0, "easy", 11, "6:50")), {}, "cap"),
        (plan_json(*((d, "easy", 6, "6:50") for d in (0, 2, 4, 6))), {}, "left for the week"),
        (plan_json((0, "easy", 5, "5:30")), {}, "zone"),
        (plan_json((0, "easy", 5, "6:50")), {"days_left": [WEEK + timedelta(days=1)]}, "day"),
        (plan_json((0, "easy", 5, "6:50"), note="Easy week — rest well."), {}, "em dash"),
        (
            plan_json((1, "tempo", 4, "5:20"), (3, "intervals", 4, "5:00")),
            {"beginner": True},
            "hard sessions",
        ),
    ],
)
def test_unsafe_plans_are_rejected(raw: str, kw: dict[str, Any], why: str) -> None:
    with pytest.raises(ValueError, match=why):
        check_plan(raw, mk_facts(**kw))


def test_replan_never_adds_distance_or_runs() -> None:
    raw = plan_json((3, "easy", 5, "6:50"), (5, "easy", 5, "6:50"))
    f = mk_facts(days_left=[WEEK + timedelta(days=i) for i in range(3, 7)])
    with pytest.raises(ValueError, match="left for the week"):
        check_plan(raw, f, budget_km=8.0, budget_count=2)
    with pytest.raises(ValueError, match="at most 1"):
        check_plan(raw, f, budget_km=20.0, budget_count=1)


@pytest.mark.parametrize(("day", "runs"), [(0, 3), (3, 2), (4, 2), (5, 1), (6, 1)])
def test_rules_plan_shrinks_as_the_week_runs_out(day: int, runs: int) -> None:
    now = datetime.combine(WEEK + timedelta(days=day), time(9), UTC)
    f = facts([], "UTC", now, prev_count=3)
    sessions = fallback_plan(f)
    assert len(sessions) == runs
    picked = [date.fromisoformat(s["date"]) for s in sessions]
    assert all((b - a).days >= 2 for a, b in zip(picked, picked[1:], strict=False))


def test_runs_tick_off_sessions_and_misses_flag_a_replan() -> None:
    sessions, _, _ = check_plan(
        plan_json((0, "easy", 5, "6:50"), (2, "easy", 5, "6:50"), (4, "easy", 5, "6:50")),
        mk_facts(),
    )
    row = WeekPlan(sessions=sessions, needs_replan=False)
    run_day = WEEK + timedelta(days=1)
    done = [{"date": run_day, "km": 5.0, "pace": 400, "hard": False, "run_id": "r1"}]
    match_runs(row, mk_facts(today=WEEK + timedelta(days=3), done=done))
    by_status = {s["status"]: s for s in row.sessions}
    # Tuesday's run pulled Wednesday's session forward; Monday's was missed.
    assert by_status["done"]["date"] == run_day.isoformat()
    assert by_status["done"]["moved_from"] == (WEEK + timedelta(days=2)).isoformat()
    assert by_status["missed"]["date"] == WEEK.isoformat()
    assert row.needs_replan


class FakePlanner:
    """Plans easy runs on alternate days, inside whatever caps the packet gives."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    async def complete(self, system: str, user: str) -> LLMResult:
        packet = json.loads(user)
        self.calls.append(packet)
        cap = packet["cap"]
        days = [d for d, _ in packet["days_left"]][::2][: min(cap["sessions"], 3)]
        km = round(min(cap["run_km"], cap["week_km"] / max(len(days), 1)), 1)
        pace = packet["fit"]["zones"]["easy"][1] if packet["fit"] else "7:00"
        body = {
            "note": "Easy running to build the habit.",
            "change": "Moved the missed run later." if packet["why"] == "missed" else "",
            "sessions": [
                {
                    "date": d,
                    "kind": "easy",
                    "km": km,
                    "pace": pace,
                    "detail": "Easy.",
                    "why": "Base.",
                }
                for d in days
            ],
        }
        return LLMResult(json.dumps(body), 10, 10, None, None)


async def _user_with_history(client: AsyncClient, auth: dict[str, str], db: AsyncSession) -> Any:
    for days_ago in (8, 10, 13, 15, 17, 20, 22, 24):
        payload = run_payload(run_id=uuid.uuid4(), days_ago=days_ago)
        assert (await client.post("/runs", json=payload, headers=auth)).status_code == 200
    return (await db.scalars(select(User.id))).one()


async def test_plan_is_written_once_and_replanned_once_a_day_after_a_miss(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    uid = await _user_with_history(client, auth, session)
    week = monday(datetime.now(UTC).date())
    mon = datetime.combine(week, time(10), UTC)
    llm = FakePlanner()

    row = await sync_plan(session, uid, "UTC", llm_client=llm, now=mon)
    assert row is not None and row.source == "llm" and row.original_count == 3
    await sync_plan(session, uid, "UTC", llm_client=llm, now=mon + timedelta(hours=2))
    assert len(llm.calls) == 1

    wed = mon + timedelta(days=2)
    row = await sync_plan(session, uid, "UTC", llm_client=llm, now=wed)
    assert row is not None and len(llm.calls) == 2 and llm.calls[1]["why"] == "missed"
    assert [s["status"] for s in row.sessions].count("missed") == 1
    assert row.change == "Moved the missed run later." and row.original_count == 3
    # Monday's miss is never made up: the rest of the week gets at most what was left.
    planned = [float(s["km"]) for s in row.sessions if s["status"] == "planned"]
    assert sum(planned) <= llm.calls[1]["cap"]["week_km"] + 0.05 * len(planned)
    await sync_plan(session, uid, "UTC", llm_client=llm, now=wed + timedelta(hours=3))
    assert len(llm.calls) == 2

    ctx = await load_context(session, uid, "UTC")
    assert any(count == 3 and at < mon for at, count in ctx.plans)


async def test_bad_llm_plan_falls_back_to_rules(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    uid = await _user_with_history(client, auth, session)

    class Reckless:
        async def complete(self, system: str, user: str) -> LLMResult:
            days = [d for d, _ in json.loads(user)["days_left"]]
            hard = [
                {
                    "date": d,
                    "kind": "intervals",
                    "km": 30,
                    "pace": "4:00",
                    "detail": "Go.",
                    "why": "x",
                }
                for d in days
            ]
            return LLMResult(
                json.dumps({"note": "n", "change": "", "sessions": hard}), 1, 1, None, None
            )

    row = await sync_plan(session, uid, "UTC", llm_client=Reckless())
    assert row is not None and row.source == "fallback" and row.error
    assert all(s["kind"] in ("easy", "tempo") for s in row.sessions)


async def test_plan_endpoint_and_upload_matching(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    assert (await client.get("/plan/current", headers=auth)).json() == {"plan": None}
    await _user_with_history(client, auth, session)
    plan = (await client.get("/plan/current?tz=UTC", headers=auth)).json()["plan"]
    assert plan["source"] == "fallback" and plan["sessions"]
    resp = await client.post("/runs", json=run_payload(run_id=uuid.uuid4()), headers=auth)
    statuses = [s["status"] for s in resp.json()["plan"]["sessions"]]
    assert "done" in statuses


async def test_first_plan_mid_week_keeps_the_weekly_count(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    uid = await _user_with_history(client, auth, session)
    sat = datetime.combine(monday(datetime.now(UTC).date()) + timedelta(days=5), time(9), UTC)
    row = await sync_plan(session, uid, "UTC", llm_client=FakePlanner(), now=sat)
    assert row is not None and len(row.sessions) == 1
    # The coach asked for 3 a week; arriving on Saturday must not shrink that to 1.
    assert row.original_count == 3
