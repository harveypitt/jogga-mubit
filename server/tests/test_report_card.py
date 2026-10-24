"""Weekly report card: grading rules, summary validation and API."""

import json
import uuid
from datetime import UTC, date, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from jogga import weekly
from jogga.coach import LLMResult
from jogga.models import ReportCard, Run
from jogga.report_card import (
    Context,
    Row,
    Week,
    grade_balance,
    grade_consistency,
    grade_load,
    grade_pacing,
    grade_progress,
    grade_weeks,
    pacing_score,
)
from jogga.weekly import fallback_summary, parse_report_summary, report_packet
from jogga.weeks import local_week, week_end

from .conftest import run_payload


def split(s: float, gain: float = 0.0, loss: float = 0.0) -> dict[str, float]:
    return {"distance_m": 1000.0, "moving_s": s, "gain_m": gain, "loss_m": loss}


def mk_run(started: datetime, paces: list[float], **kw: Any) -> Run:
    splits = [split(p) for p in paces]
    return Run(
        id=uuid.uuid4(),
        user_id=kw.pop("user_id", uuid.uuid4()),
        started_at=started,
        distance_m=1000.0 * len(paces),
        moving_s=sum(paces),
        elapsed_s=sum(paces) + 30,
        gain_m=0.0,
        loss_m=0.0,
        splits=splits,
        efforts=kw.pop("efforts", {}),
        source=kw.pop("source", "jogga"),
        tz=kw.pop("tz", None),
        created_at=started,
    )


# --- local weeks -------------------------------------------------------------


def test_local_week_uses_runner_zone() -> None:
    # Monday 00:30 in Auckland is still Sunday in UTC: it belongs to the new week.
    t = datetime(2026, 10, 18, 11, 30, tzinfo=UTC)  # Mon 00:30 NZDT
    assert local_week(t, "UTC") == date(2026, 10, 12)
    assert local_week(t, "Pacific/Auckland") == date(2026, 10, 19)
    assert local_week(t, "Not/AZone") == date(2026, 10, 12)
    assert week_end(date(2026, 10, 12), "Europe/London") == datetime(
        2026, 10, 18, 23, 0, tzinfo=UTC
    )


# --- categories --------------------------------------------------------------


def test_consistency_capped_and_never_rewards_extra_runs() -> None:
    assert grade_consistency(3, 3, "coach", 5).grade == "A"
    extra = grade_consistency(6, 3, "coach", 5)
    assert extra.grade == "A" and extra.metric == "6 runs, 3 planned"
    assert grade_consistency(2, 3, "coach", 5).grade == "B"
    assert grade_consistency(1, 3, "coach", 5).grade == "C"
    assert grade_consistency(0, 3, "coach", 5).grade == "D"
    assert grade_consistency(2, None, None, 1).grade is None


def test_load_is_a_band_not_more_is_better() -> None:
    prev = [20.0, 20.0, 20.0, 20.0]
    grades = [grade_load(km, prev, 8, 8, 6, live=False).grade for km in (20, 24, 28, 32)]
    assert grades == ["A", "B", "C", "D"]
    # Cutback after a build is fine; a crash without a build is not an A.
    assert grade_load(13, [24, 22, 20, 18], 6, 8, 6, live=False).grade == "A"
    assert grade_load(13, prev, 6, 8, 6, live=False).grade == "B"
    # Mid-week low totals are not judged.
    assert grade_load(5, prev, 5, 8, 6, live=True).grade is None
    # Long-run jump drops a step.
    jump = grade_load(21, prev, 14, 8, 6, live=False)
    assert jump.grade == "B" and jump.inputs["long_run_jump"]
    assert grade_load(20, prev, 8, 8, 2, live=False).grade is None


def test_balance_more_hard_never_helps() -> None:
    mon = date(2026, 10, 19)
    day = lambda i: mon + timedelta(days=i)  # noqa: E731
    easy_week = [(day(0), "easy"), (day(2), "hard"), (day(4), "easy"), (day(6), "easy")]
    harder = [(day(0), "hard"), (day(2), "hard"), (day(4), "easy"), (day(6), "hard")]
    back_to_back = [
        (day(0), "easy"),
        (day(2), "hard"),
        (day(3), "hard"),
        (day(5), "easy"),
        (day(6), "easy"),
    ]
    a = grade_balance(easy_week, False, 5)  # type: ignore[arg-type]
    b = grade_balance(harder, False, 5)  # type: ignore[arg-type]
    c = grade_balance(back_to_back, False, 5)  # type: ignore[arg-type]
    assert a.grade == "A"
    assert b.grade is not None and b.grade > "A"
    assert c.grade == "B" and "back-to-back" in c.metric
    # Hard Sunday last week + hard Monday this week counts as back-to-back.
    monday_hard = [(day(0), "hard"), (day(2), "easy"), (day(4), "easy")]
    assert grade_balance(monday_hard, True, 5).grade == "B"  # type: ignore[arg-type]
    assert grade_balance(easy_week, False, 2).grade is None  # type: ignore[arg-type]


def test_pacing_rewards_even_and_flags_fast_start() -> None:
    t = datetime(2026, 10, 20, 7, tzinfo=UTC)
    even = mk_run(t, [330, 330, 328, 326, 325])
    bolted = mk_run(t, [290, 335, 345, 355, 365])
    s_even = pacing_score(even, "steady", None)
    s_bolt = pacing_score(bolted, "steady", None)
    assert s_even is not None and s_bolt is not None
    assert s_even["score"] == 1.0
    assert s_bolt["fast_start"] and s_bolt["score"] < 0.5
    assert pacing_score(mk_run(t, [330, 330]), "easy", None) is None
    assert pacing_score(even, "intervals", None) is None
    row = grade_pacing([(even, s_even), (bolted, s_bolt)], "UTC")
    assert row.grade == "C"
    assert row.metric.startswith("1 of 2 runs evenly paced · first km")
    assert grade_pacing([], "UTC").grade is None


def test_pacing_uses_hill_adjusted_splits() -> None:
    t = datetime(2026, 10, 20, 7, tzinfo=UTC)
    hilly = mk_run(t, [320, 320, 320, 320, 360])
    hilly.splits[-1] = split(360, gain=40)
    s = pacing_score(hilly, "steady", None)
    assert s is not None and s["shape"] != "faded"


def test_progress_needs_a_trend() -> None:
    assert grade_progress([None, None, 1500, 1490], "5k", None, True, None).grade is None
    faster = grade_progress([1560, 1540, 1525, 1500], "5k", 1440, True, None)
    assert faster.grade == "A" and "1:00 faster over 4 weeks" in faster.metric
    assert "1:00 to target" in faster.metric
    slower = grade_progress([1500, 1520, 1540, 1560], "5k", None, True, None)
    assert slower.grade == "D"
    carried = grade_progress([1500, 1520, 1540, 1560], "5k", None, False, faster)
    assert carried.grade == "A" and carried.inputs["carried_over"]


def _week(**grades: str | None) -> Week:
    rows = {c: Row(c, grades.get(c), "m") for c in weekly.CATEGORIES}
    return Week(date(2026, 10, 19), False, [], 10.0, {}, rows, 1, [], 3, None)


def test_focus_is_lowest_grade_with_safety_tie_break() -> None:
    assert _week(consistency="B", pacing="C", load="A").focus() == "pacing"
    assert _week(pacing="C", load="C", balance="C").focus() == "load"
    assert _week(pacing="B", consistency="B").focus() == "pacing"
    assert _week().focus() == "consistency"
    assert _week(consistency="A", pacing="C").composite == 3.0


# --- whole weeks -------------------------------------------------------------


def test_new_runner_gets_consistency_and_pacing_only() -> None:
    now = datetime(2026, 10, 22, 18, tzinfo=UTC)
    runs = [
        mk_run(now - timedelta(days=2), [330] * 5, efforts={"5k": 1650}),
        mk_run(now - timedelta(days=1), [325] * 5, efforts={"5k": 1625}),
    ]
    ctx = Context(runs, "UTC", now, plans=[(runs[0].started_at, 3)], targets={})
    week = grade_weeks(ctx)[local_week(now, "UTC")]
    graded = {c: r.grade for c, r in week.rows.items()}
    assert graded["consistency"] == "B" and graded["pacing"] == "A"
    assert graded["balance"] is graded["load"] is graded["progress"] is None
    assert week.rows["load"].metric == "Building · 3 more weeks"


def test_rest_week_is_not_graded_and_skipped_for_trends() -> None:
    now = datetime(2026, 10, 22, 18, tzinfo=UTC)
    runs = [mk_run(now - timedelta(days=d), [330] * 5) for d in (15, 1)]
    ctx = Context(runs, "UTC", now, plans=[(runs[0].started_at, 3)], targets={})
    weeks = grade_weeks(ctx)
    rest = weeks[local_week(now, "UTC") - timedelta(weeks=1)]
    assert rest.runs == [] and all(r.grade is None for r in rest.rows.values())
    assert weeks[local_week(now, "UTC")].rows["consistency"].trend == "same"


def test_since_returns_only_recent_weeks() -> None:
    now = datetime(2026, 10, 22, 18, tzinfo=UTC)
    runs = [mk_run(now - timedelta(days=d), [330] * 5) for d in range(1, 120, 3)]
    ctx = Context(runs, "UTC", now, plans=[], targets={})
    this = local_week(now, "UTC")
    full = grade_weeks(ctx)
    recent = grade_weeks(ctx, since=this - timedelta(weeks=2))
    assert sorted(recent) == [this - timedelta(weeks=i) for i in (2, 1, 0)]
    assert recent[this].grades_json() == full[this].grades_json()


# --- summary validation --------------------------------------------------------


def _packet_week() -> tuple[Week, str]:
    w = _week(consistency="A", pacing="C", load="B")
    w.km = 21.4
    return w, report_packet(w, None)


def _summary(**kw: Any) -> str:
    body = {
        "headline": "A solid week with room to settle",
        "summary": "You ran 21.4 km and hit every planned run. Starting easier will help.",
        "focus": {"category": "pacing", "action": "Run the first kilometre gently."},
    }
    body.update(kw)
    return json.dumps(body)


def test_summary_accepts_good_text() -> None:
    _, packet = _packet_week()
    out = parse_report_summary(_summary(), packet, "pacing")
    assert out.focus.category == "pacing"


@pytest.mark.parametrize(
    ("override", "why"),
    [
        ({"summary": "You got a B for pacing this week."}, "grade"),
        ({"summary": "Your pacing grade slipped."}, "grade"),
        ({"summary": "You ran 25 km this week."}, "not in the packet"),
        ({"headline": " ".join(["word"] * 11)}, "words"),
        ({"focus": {"category": "load", "action": "Ease off."}}, "focus"),
        ({"focus": {"category": "pacing", "action": "Aim for 180 spm."}}, "cadence"),
        ({"headline": "Great week!"}, "exclamation"),
    ],
)
def test_summary_rejects(override: dict[str, Any], why: str) -> None:
    _, packet = _packet_week()
    with pytest.raises(ValueError, match=why):
        parse_report_summary(_summary(**override), packet, "pacing")


def test_fallback_exists_for_every_category_and_is_valid() -> None:
    _, packet = _packet_week()
    for c in weekly.CATEGORIES:
        text = json.dumps(fallback_summary(c))
        assert parse_report_summary(text, packet, c).focus.category == c


# --- API -----------------------------------------------------------------------


class FakeLLM:
    def __init__(self) -> None:
        self.calls = 0

    async def complete(self, system: str, user: str) -> LLMResult:
        self.calls += 1
        focus = json.loads(user)["focus"]
        body = {
            "headline": "A good week of running",
            "summary": "You kept things moving this week. Keep the easy runs easy.",
            "focus": {"category": focus, "action": "Keep next week calm and steady."},
        }
        return LLMResult(json.dumps(body), 10, 10, 0.0001, "gen-1")


@pytest.fixture
def fake_llm(monkeypatch: pytest.MonkeyPatch) -> FakeLLM:
    fake = FakeLLM()
    monkeypatch.setattr(weekly, "report_llm_client", lambda: fake)
    return fake


def _days_into_week(days: float, tz: str = "UTC") -> float:
    """days_ago for a run ``days`` into last week, so it never lands in this week."""
    now = datetime.now(UTC)
    last_monday = week_end(local_week(now, tz) - timedelta(weeks=2), tz)
    return (now - (last_monday + timedelta(days=days))).total_seconds() / 86400


async def test_current_card_updates_after_upload(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    empty = await client.get("/report-card/current", headers=auth)
    assert empty.status_code == 200 and empty.json() == {"card": None}
    payload = {**run_payload(days_ago=0), "tz": "Europe/London"}
    assert (await client.post("/runs", json=payload, headers=auth)).status_code == 200
    stored = (await session.scalars(select(ReportCard))).all()
    assert [c.status for c in stored] == ["live"] and stored[0].tz == "Europe/London"
    card = (await client.get("/report-card/current", headers=auth)).json()["card"]
    assert card["status"] == "live" and card["kind"] == "report"
    assert card["tz"] == "Europe/London" and card["runs"] == 1
    assert [r["category"] for r in card["rows"]] == [
        "consistency",
        "pacing",
        "balance",
        "load",
        "progress",
    ]
    assert card["summary"] is None
    pacing = card["rows"][1]
    assert pacing["grade"] == "A" and pacing["how"]
    assert pacing["details"][0][1] == "Even"


async def test_latest_closed_calls_llm_once(
    client: AsyncClient, auth: dict[str, str], fake_llm: FakeLLM
) -> None:
    for d in (0.3, 2.3, 4.3):
        await client.post("/runs", json=run_payload(days_ago=_days_into_week(d)), headers=auth)
    first = (await client.get("/report-card/latest-closed", headers=auth)).json()["card"]
    again = (await client.get("/report-card/latest-closed", headers=auth)).json()["card"]
    assert fake_llm.calls == 1
    assert first["status"] == "closed" and first["kind"] == "report"
    assert first["source"] == "llm"
    assert first["summary"]["headline"] == "A good week of running"
    assert first["summary"]["focus"]["category"] == first["focus"]
    assert again["summary"] == first["summary"]


async def test_latest_closed_falls_back_on_bad_llm_output(
    client: AsyncClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    class Bad(FakeLLM):
        async def complete(self, system: str, user: str) -> LLMResult:
            return LLMResult('{"headline":"You got an A"}', None, None, None, None)

    monkeypatch.setattr(weekly, "report_llm_client", lambda: Bad())
    await client.post("/runs", json=run_payload(days_ago=_days_into_week(1)), headers=auth)
    card = (await client.get("/report-card/latest-closed", headers=auth)).json()["card"]
    assert card["source"] == "fallback"
    assert card["summary"] == fallback_summary(card["focus"])


async def test_rest_week_has_no_report(
    client: AsyncClient, auth: dict[str, str], fake_llm: FakeLLM
) -> None:
    await client.post("/runs", json=run_payload(days_ago=_days_into_week(-6)), headers=auth)
    card = (await client.get("/report-card/latest-closed", headers=auth)).json()["card"]
    assert card["kind"] == "rest" and card["summary"] is None and card["runs"] == 0
    assert fake_llm.calls == 0


async def test_imported_weeks_backfill_without_llm(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession, fake_llm: FakeLLM
) -> None:
    runs = [
        {**run_payload(days_ago=_days_into_week(1) + 7 * w), "external_id": str(w)}
        for w in range(6)
    ]
    resp = await client.post("/runs/import", json={"source": "strava", "runs": runs}, headers=auth)
    assert resp.json()["imported"] == 6
    stored = (await session.scalars(select(ReportCard))).all()
    assert len(stored) == 6
    assert {(c.status, c.source) for c in stored} == {("closed", "backfill")}
    assert all(c.summary is None for c in stored)
    card = (await client.get("/report-card/latest-closed", headers=auth)).json()["card"]
    assert card["kind"] == "imported" and card["summary"] is None
    assert fake_llm.calls == 0
    history = (await client.get("/report-card/history?weeks=8", headers=auth)).json()["weeks"]
    # Starts at the first week with a run, newest first.
    assert len(history) == 7
    assert history[0]["status"] == "live" and history[0]["kind"] == "rest"
    assert [w["kind"] for w in history[1:7]] == ["imported"] * 6
    load = {r["category"]: r for r in history[1]["rows"]}["load"]
    assert load["grade"] == "A"


async def test_late_run_regrades_closed_week(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession, fake_llm: FakeLLM
) -> None:
    await client.post("/runs", json=run_payload(days_ago=_days_into_week(1)), headers=auth)
    first = (await client.get("/report-card/latest-closed", headers=auth)).json()["card"]
    assert first["runs"] == 1
    await client.post("/runs", json=run_payload(days_ago=_days_into_week(3)), headers=auth)
    late = (await client.get("/report-card/latest-closed", headers=auth)).json()["card"]
    assert late["runs"] == 2 and fake_llm.calls == 1
    assert await session.scalar(select(func.count()).select_from(ReportCard)) == 2


async def test_history_validates_weeks(client: AsyncClient, auth: dict[str, str]) -> None:
    assert (await client.get("/report-card/history?weeks=0", headers=auth)).status_code == 422
    assert (await client.get("/report-card/history", headers=auth)).json() == {"weeks": []}
