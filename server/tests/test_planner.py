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
from jogga.models import RunSurvey, User, WeekPlan
from jogga.planner import (
    HARD_KINDS,
    Facts,
    check_plan,
    facts,
    fallback_plan,
    match_runs,
    public_packet,
    sync_plan,
)
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
        (plan_json(*((d, "easy", 7, "6:50") for d in (0, 2, 4, 6))), {}, "left for the week"),
        (plan_json((0, "easy", 1.7, "6:50")), {}, "minimum"),
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
        while days and cap["week_km"] / len(days) < cap["min_km"]:
            days.pop()
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


async def test_survey_is_stored_and_pain_replans_easy(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    uid = await _user_with_history(client, auth, session)
    mon = datetime.combine(monday(datetime.now(UTC).date()), time(8), UTC)
    llm = FakePlanner()
    await sync_plan(session, uid, "UTC", llm_client=llm, now=mon)
    await session.commit()

    run_id = uuid.uuid4()
    payload = run_payload(run_id=run_id, days_ago=0)
    payload["started_at"] = (mon + timedelta(hours=1)).isoformat()
    assert (await client.post("/runs", json=payload, headers=auth)).status_code == 200
    survey = {
        "difficulty": "hard",
        "coaching": "too_much",
        "injury": True,
        "injury_area": "knee",
        "injury_severity": "sore",
        "notes": "  Knee tight on the hill.  ",
    }
    url = f"/runs/{run_id}/survey"
    assert (await client.put(url, json=survey, headers=auth)).status_code == 200
    stored = (await session.scalars(select(RunSurvey))).one()
    assert stored.notes == "Knee tight on the hill." and stored.injury_area == "knee"

    row = await sync_plan(session, uid, "UTC", llm_client=llm, now=mon + timedelta(hours=2))
    packet = llm.calls[-1]
    # Pain replans even if the plan was already replanned today.
    assert len(llm.calls) == 2 and packet["why"] in ("check_in", "missed")
    assert packet["injury"] == "sore" and packet["cap"]["hard"] == 0
    assert packet["feel"][-1][1:] == ["hard", "knee/sore", "Knee tight on the hill."]
    assert row is not None and all(s["kind"] not in HARD_KINDS for s in row.sessions)
    assert "feel" not in public_packet(json.dumps(packet))


async def test_survey_is_validated_and_private_to_the_runner(
    client: AsyncClient, auth: dict[str, str]
) -> None:
    run_id = uuid.uuid4()
    await client.post("/runs", json=run_payload(run_id=run_id), headers=auth)
    bad = await client.put(f"/runs/{run_id}/survey", json={"difficulty": "meh"}, headers=auth)
    assert bad.status_code == 422
    other = (await client.post("/auth/dev", json={"name": "Other"})).json()["token"]
    resp = await client.put(
        f"/runs/{run_id}/survey",
        json={"difficulty": "easy"},
        headers={"Authorization": f"Bearer {other}"},
    )
    assert resp.status_code == 404


def test_no_run_too_short_to_be_worth_doing() -> None:
    # Harvey's week: 6.3 km done, a cap that only left 3.7 km, split into 2.0 + 1.7 km.
    f = mk_facts(
        today=WEEK + timedelta(days=5),
        days_left=[WEEK + timedelta(days=5), WEEK + timedelta(days=6)],
        done=[
            {
                "date": WEEK + timedelta(days=2),
                "km": 6.3,
                "pace": 356,
                "hard": False,
                "run_id": "r1",
            }
        ],
        long4w=6.3,
        avg4w_km=8.0,
        typical_km=5.5,
    )
    assert f.min_km == 3.0  # 20 min at 7:00/km is under 3 km
    # A low-volume week may still add one usual run on top of its average.
    assert f.week_cap == round(8.0 + 5.5 - 6.3, 1)
    sessions = fallback_plan(f)
    assert sessions and all(s["km"] >= f.min_km for s in sessions)
    assert len(sessions) == 1


def test_growth_follows_how_runs_felt() -> None:
    from jogga.planner import growth_factor

    assert growth_factor([], None, False) == 1.10
    assert growth_factor(["moderate", "easy"], None, False) == 1.30
    assert growth_factor(["moderate", "easy"], None, True) == 1.25
    assert growth_factor(["easy", "hard", "max"], None, False) == 1.0
    assert growth_factor(["hard", "hard", "easy"], None, False) == 1.10
    assert growth_factor(["easy"], "niggle", False) == 1.0
    assert growth_factor(["easy"], "sore", False) == 0.75
    # Comfortable weeks at 8 km may grow to 13.5 km (one usual run more), sore ones shrink.
    assert mk_facts(avg4w_km=8.0, typical_km=5.5, growth=1.30).week_cap == 13.5
    assert mk_facts(avg4w_km=8.0, typical_km=5.5, growth=0.75).week_cap == 6.0


def test_hard_sessions_stay_near_a_fifth_of_the_week() -> None:
    raw = plan_json((0, "tempo", 6, "5:20"), (2, "easy", 5, "6:50"), (4, "intervals", 6, "5:00"))
    with pytest.raises(ValueError, match="over 20%"):
        check_plan(raw, mk_facts(avg4w_km=30.0))


def test_onboarding_rules_are_hard_rules() -> None:
    f = mk_facts(banned=frozenset({"intervals"}), max_runs=2)
    with pytest.raises(ValueError, match="asked to avoid"):
        check_plan(plan_json((0, "intervals", 5, "5:00")), f)
    with pytest.raises(ValueError, match="at most 2"):
        check_plan(plan_json(*((d, "easy", 5, "6:50") for d in (0, 2, 4))), f)
    assert len(fallback_plan(f)) == 2


async def test_first_plan_uses_their_usual_week_and_days(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    from jogga.planner import plan_out, sync_plan

    profile = {
        "days": [0, 2, 5],
        "runs_per_week": 3,
        "experience": "regular",
        "usual_week_km": 15,
        "consent": True,
    }
    assert (await client.put("/me/profile", json=profile, headers=auth)).status_code == 200
    user_id = await session.scalar(select(User.id))
    monday = datetime(2026, 10, 26, 7, tzinfo=UTC)
    out = plan_out(
        await sync_plan(session, user_id, "Europe/London", force=True, now=monday), monday
    )
    assert out is not None
    assert [s["weekday"] for s in out["sessions"]] == ["Mon", "Wed", "Sat"]
    assert {s["km"] for s in out["sessions"]} == {5.0}


async def test_profile_round_trips_and_shapes_the_plan(
    client: AsyncClient, auth: dict[str, str]
) -> None:
    assert (await client.get("/me/profile", headers=auth)).json() == {"onboarded": False}
    body = {
        "goal": "10k",
        "days": [5, 1, 1],
        "runs_per_week": 2,
        "experience": "regular",
        "usual_week_km": 15,
        "dislikes": ["track"],
        "niggles": "  Left knee  ",
        "blocker": "time",
        "heard_from": "event",
        "consent": True,
    }
    assert (await client.put("/me/profile", json=body, headers=auth)).status_code == 200
    got = (await client.get("/me/profile", headers=auth)).json()
    assert got["onboarded"] and got["days"] == [1, 5] and got["niggles"] == "Left knee"
    assert got["blocker"] == "time" and got["heard_from"] == "event"
    for wrong in ({"experience": "pro"}, {"blocker": "rain"}):
        bad = await client.put("/me/profile", json=wrong, headers=auth)
        assert bad.status_code == 422
    await client.post("/runs", json=run_payload(run_id=uuid.uuid4()), headers=auth)
    plan = (await client.get("/plan/current", headers=auth)).json()["plan"]
    planned = [s for s in plan["sessions"] if s["status"] == "planned"]
    assert all(date.fromisoformat(s["date"]).weekday() in (1, 5) for s in planned)
    assert all(s["kind"] != "intervals" for s in planned)
    assert len(planned) <= 2


async def test_onboarding_alone_gives_a_first_plan(
    client: AsyncClient, auth: dict[str, str]
) -> None:
    assert (await client.get("/plan/current", headers=auth)).json()["plan"] is None
    body = {
        "days": [0, 1, 2, 3, 4, 5, 6],
        "runs_per_week": 3,
        "experience": "regular",
        "usual_week_km": 12,
        "consent": True,
    }
    await client.put("/me/profile", json=body, headers=auth)
    plan = (await client.get("/plan/current", headers=auth)).json()["plan"]
    planned = [s for s in plan["sessions"] if s["status"] == "planned"]
    assert planned and all(s["km"] >= 3 for s in planned)
    await client.put("/me/profile", json={**body, "days": [6]}, headers=auth)
    plan = (await client.get("/plan/current", headers=auth)).json()["plan"]
    assert all(s["weekday"] == "Sun" for s in plan["sessions"] if s["status"] == "planned")
    assert plan["change"] == "Replanned around your training preferences."
