"""API tests: auth gating, upsert idempotency, /me stats, LLM fallback."""

import json
import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from pydantic import ValidationError
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from jogga import config
from jogga.coach import LLMResult, coach_run, parse_coach_output
from jogga.models import CoachNote, Run
from tests.conftest import run_payload

VALID_COACH_OUTPUT = {
    "went_well": "Splits stayed steady.",
    "work_on": "Start the next run more gently.",
    "result": "A solid effort.",
    "next": {
        "kind": "easy",
        "km": 4.0,
        "pace": "5:40",
        "detail": "Easy 4 km at 5:40/km.",
        "why": "Build your base.",
    },
    "frequency": {"runs_per_week": 3, "note": "Three runs per week."},
    "forecast": {"km": 4.0, "pace": "6:00"},
}


def _fake_llm_client() -> Any:
    class FakeClient:
        async def complete(self, system: str, user: str) -> LLMResult:
            return LLMResult(
                text=json.dumps(VALID_COACH_OUTPUT),
                prompt_tokens=100,
                completion_tokens=50,
                cost_usd=None,
                generation_id=None,
            )

    return FakeClient()


def _patch_counting_coach(monkeypatch: Any, llm_client: Any = None) -> list[uuid.UUID]:
    import jogga.main as main_mod

    calls: list[uuid.UUID] = []

    async def counted(db: AsyncSession, run: Run) -> Any:
        calls.append(run.id)
        return await coach_run(db, run, llm_client=llm_client)

    monkeypatch.setattr(main_mod, "coach_run", counted)
    return calls


async def test_health(client: AsyncClient) -> None:
    assert (await client.get("/health")).json() == {"status": "ok"}


async def test_unauthorized(client: AsyncClient) -> None:
    assert (await client.get("/me")).status_code == 401


async def test_dev_auth_gated(client: AsyncClient, monkeypatch: Any) -> None:
    monkeypatch.setattr(config, "DEV_AUTH", False)
    assert (await client.post("/auth/dev", json={"name": "x"})).status_code == 404


async def test_bad_token(client: AsyncClient) -> None:
    resp = await client.get("/me", headers={"Authorization": "Bearer nope"})
    assert resp.status_code == 401


async def test_run_upsert_idempotent(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    rid = uuid.uuid4()
    payload = run_payload(run_id=rid)
    r1 = await client.post("/runs", json=payload, headers=auth)
    assert r1.status_code == 200
    payload["moving_s"] = 1700.0
    r2 = await client.post("/runs", json=payload, headers=auth)
    assert r2.status_code == 200
    count = await session.scalar(select(func.count()).select_from(Run).where(Run.id == rid))
    assert count == 1
    assert r2.json()["run"]["moving_s"] == 1700.0
    notes = await session.scalar(
        select(func.count()).select_from(CoachNote).where(CoachNote.run_id == rid)
    )
    assert notes == 1


async def test_unchanged_llm_run_is_not_recoached(
    client: AsyncClient, auth: dict[str, str], monkeypatch: Any
) -> None:
    calls = _patch_counting_coach(monkeypatch, _fake_llm_client())
    payload = run_payload()

    first = await client.post("/runs", json=payload, headers=auth)
    second = await client.post("/runs", json=payload, headers=auth)

    first_coach = first.json()["coach"]
    second_coach = second.json()["coach"]
    assert first.status_code == second.status_code == 200
    assert len(calls) == 1
    assert first_coach["source"] == second_coach["source"] == "llm"
    assert first_coach["payload"] == second_coach["payload"]


async def test_changed_run_is_recoached(
    client: AsyncClient, auth: dict[str, str], monkeypatch: Any
) -> None:
    calls = _patch_counting_coach(monkeypatch, _fake_llm_client())
    payload = run_payload()

    await client.post("/runs", json=payload, headers=auth)
    payload["moving_s"] = 1700.0
    response = await client.post("/runs", json=payload, headers=auth)

    assert response.status_code == 200
    assert len(calls) == 2


async def test_unchanged_heuristic_run_is_recoached(
    client: AsyncClient, auth: dict[str, str], monkeypatch: Any
) -> None:
    calls = _patch_counting_coach(monkeypatch)
    payload = run_payload()

    first = await client.post("/runs", json=payload, headers=auth)
    second = await client.post("/runs", json=payload, headers=auth)

    assert first.json()["coach"]["source"] == second.json()["coach"]["source"] == "heuristic"
    assert len(calls) == 2


async def test_run_mode_is_validated_persisted_and_returned(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    payload = run_payload()
    payload["mode"] = "free"
    response = await client.post("/runs", json=payload, headers=auth)
    assert response.status_code == 200
    assert response.json()["run"]["mode"] == "free"
    run = await session.get(Run, uuid.UUID(payload["id"]))
    assert run is not None and run.mode == "free"

    payload["mode"] = "unsanctioned"
    response = await client.post("/runs", json=payload, headers=auth)
    assert response.status_code == 422


async def test_run_upsert_cross_user_blocked(client: AsyncClient, auth: dict[str, str]) -> None:
    rid = uuid.uuid4()
    await client.post("/runs", json=run_payload(run_id=rid), headers=auth)
    other = await client.post("/auth/dev", json={"name": "Other"})
    other_auth = {"Authorization": f"Bearer {other.json()['token']}"}
    resp = await client.post("/runs", json=run_payload(run_id=rid), headers=other_auth)
    assert resp.status_code == 409
    # Original run is untouched.
    check = await client.get(f"/runs/{rid}", headers=auth)
    assert check.json()["run"]["moving_s"] == 1600.0


async def test_run_delete(client: AsyncClient, auth: dict[str, str], session: AsyncSession) -> None:
    rid = uuid.uuid4()
    await client.post("/runs", json=run_payload(run_id=rid), headers=auth)
    resp = await client.delete(f"/runs/{rid}", headers=auth)
    assert resp.json() == {"deleted": True}
    assert (await client.get(f"/runs/{rid}", headers=auth)).status_code == 404
    notes = await session.scalar(
        select(func.count()).select_from(CoachNote).where(CoachNote.run_id == rid)
    )
    assert notes == 0


async def test_run_delete_idempotent(client: AsyncClient, auth: dict[str, str]) -> None:
    rid = uuid.uuid4()
    await client.post("/runs", json=run_payload(run_id=rid), headers=auth)
    await client.delete(f"/runs/{rid}", headers=auth)
    resp = await client.delete(f"/runs/{rid}", headers=auth)
    assert resp.json() == {"deleted": False}


async def test_run_delete_other_user(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    rid = uuid.uuid4()
    await client.post("/runs", json=run_payload(run_id=rid), headers=auth)
    other = await client.post("/auth/dev", json={"name": "Other"})
    other_auth = {"Authorization": f"Bearer {other.json()['token']}"}
    resp = await client.delete(f"/runs/{rid}", headers=other_auth)
    assert resp.json() == {"deleted": False}
    check = await client.get(f"/runs/{rid}", headers=auth)
    assert check.status_code == 200


async def test_me_stats(client: AsyncClient, auth: dict[str, str]) -> None:
    await client.put("/targets/5k", json={"target_s": 1500}, headers=auth)
    await client.post("/runs", json=run_payload(days_ago=1, efforts={"5k": 1600.0}), headers=auth)
    await client.post("/runs", json=run_payload(days_ago=40, efforts={"5k": 1700.0}), headers=auth)
    me = (await client.get("/me", headers=auth)).json()
    assert me["targets"] == {"5k": 1500}
    stats = me["stats"]["5k"]
    assert stats["best_s"] == 1600.0
    assert stats["last_s"] == 1600.0
    assert stats["count"] == 2
    assert stats["count_4w"] == 1


async def test_get_run_and_latest_coach(client: AsyncClient, auth: dict[str, str]) -> None:
    rid = uuid.uuid4()
    await client.post("/runs", json=run_payload(run_id=rid), headers=auth)
    resp = await client.get(f"/runs/{rid}", headers=auth)
    assert resp.status_code == 200
    assert resp.json()["coach"]["source"] == "heuristic"
    latest = await client.get("/coach/latest", headers=auth)
    assert latest.json()["payload"]["pacing"] == "even"


async def test_llm_invalid_output_falls_back(
    client: AsyncClient, auth: dict[str, str], monkeypatch: Any
) -> None:
    class BadClient:
        async def complete(self, system: str, user: str) -> LLMResult:
            return LLMResult(
                text="not json at all",
                prompt_tokens=None,
                completion_tokens=None,
                cost_usd=None,
                generation_id=None,
            )

    import jogga.main as main_mod
    from jogga.coach import coach_run

    async def patched(db: Any, run: Any, **kwargs: Any) -> Any:
        return await coach_run(db, run, llm_client=BadClient())

    monkeypatch.setattr(main_mod, "coach_run", patched)
    resp = await client.post("/runs", json=run_payload(), headers=auth)
    assert resp.status_code == 200
    coach = resp.json()["coach"]
    assert coach["source"] == "heuristic"
    assert coach["payload"]["pacing"] in ("even", "positive", "negative", "erratic")


def test_parse_coach_output_garbage() -> None:
    with pytest.raises(ValueError):
        parse_coach_output("no object here", "even")


def test_parse_coach_output_wrapped() -> None:
    out = parse_coach_output(
        'sure! {"went_well":"w","work_on":"x","result":"r",'
        '"next":{"kind":"easy","km":5.0,"pace":"5:20","detail":"d","why":"w"},'
        '"frequency":{"runs_per_week":3,"note":"n"},'
        '"forecast":{"km":4.0,"pace":"6:00"}}',
        "even",
    )
    assert out.pacing == "even" and out.next.pace == 320


def test_parse_coach_output_old_shape_rejected() -> None:
    with pytest.raises(ValidationError):
        parse_coach_output(
            '{"feedback":"f","pacing":"steady","next":{"km":5.0,"pace":320,'
            '"kind":"easy","detail":"d","why":"w"},'
            '"frequency":{"runs_per_week":3,"note":"n"}}',
            "even",
        )


def import_payload(**kwargs: Any) -> dict[str, Any]:
    external_id = kwargs.pop("external_id")
    return {**run_payload(**kwargs), "external_id": external_id}


async def test_import_runs_not_coached(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    runs = [import_payload(external_id=str(i), days_ago=30 + i) for i in range(3)]
    resp = await client.post("/runs/import", json={"source": "strava", "runs": runs}, headers=auth)
    assert resp.status_code == 200
    body = resp.json()
    assert body["imported"] == 3 and body["skipped"] == []
    assert body["ids"] == {r["external_id"]: r["id"] for r in runs}
    assert await session.scalar(select(func.count()).select_from(CoachNote)) == 0
    listed = (await client.get("/runs", headers=auth)).json()
    assert {r["source"] for r in listed} == {"strava"}
    me = (await client.get("/me", headers=auth)).json()
    assert me["stats"]["5k"]["count"] == 3


async def test_import_idempotent_by_external_id(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    first = import_payload(external_id="42", days_ago=40)
    r1 = await client.post("/runs/import", json={"source": "strava", "runs": [first]}, headers=auth)
    # Reinstall: same Strava activity, new client id.
    again = {**first, "id": str(uuid.uuid4())}
    r2 = await client.post("/runs/import", json={"source": "strava", "runs": [again]}, headers=auth)
    assert r2.json() == {"imported": 0, "ids": {"42": r1.json()["ids"]["42"]}, "skipped": []}
    assert await session.scalar(select(func.count()).select_from(Run)) == 1


async def test_import_skips_recorded_duplicates(client: AsyncClient, auth: dict[str, str]) -> None:
    recorded = run_payload(days_ago=1, distance_m=5020.0)
    await client.post("/runs", json=recorded, headers=auth)
    dupe = import_payload(external_id="7", days_ago=1 + 60 / 86400, distance_m=5100.0)
    other = import_payload(external_id="8", days_ago=2)
    resp = await client.post(
        "/runs/import", json={"source": "strava", "runs": [dupe, other]}, headers=auth
    )
    assert resp.json()["imported"] == 1
    assert resp.json()["skipped"] == ["7"]


async def test_import_rejects_unknown_source(client: AsyncClient, auth: dict[str, str]) -> None:
    runs = [import_payload(external_id="1")]
    resp = await client.post("/runs/import", json={"source": "garmin", "runs": runs}, headers=auth)
    assert resp.status_code == 422


async def test_delete_imported_runs(client: AsyncClient, auth: dict[str, str]) -> None:
    await client.post("/runs", json=run_payload(), headers=auth)
    runs = [import_payload(external_id=str(i), days_ago=10 + i) for i in range(2)]
    await client.post("/runs/import", json={"source": "strava", "runs": runs}, headers=auth)
    resp = await client.delete("/runs?source=strava", headers=auth)
    assert resp.json() == {"deleted": 2}
    listed = (await client.get("/runs", headers=auth)).json()
    assert [r["source"] for r in listed] == ["jogga"]


async def test_coach_replan_once_per_import(
    client: AsyncClient, auth: dict[str, str], session: AsyncSession
) -> None:
    assert (await client.post("/coach/replan", headers=auth)).json() is None
    runs = [import_payload(external_id=str(i), days_ago=3 + i) for i in range(2)]
    await client.post("/runs/import", json={"source": "strava", "runs": runs}, headers=auth)
    first = await client.post("/coach/replan", headers=auth)
    assert first.status_code == 200 and first.json()["payload"]["next"]["km"] > 0
    second = await client.post("/coach/replan", headers=auth)
    assert second.json() == first.json()
    assert await session.scalar(select(func.count()).select_from(CoachNote)) == 1
