"""OpenRouter client: request shape, llm source, fallback on error."""

import asyncio
import json
import uuid
from datetime import UTC, datetime
from typing import Any

import httpx
import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession

from jogga import config
from jogga.coach import (
    LLMResult,
    OpenRouterClient,
    coach_run,
    load_response_schema,
    parse_coach_output,
    request_body,
)
from jogga.models import Run, User
from tests.conftest import run_payload

VALID_OUTPUT = {
    "went_well": "Splits held within 4 s/km on flat.",
    "work_on": "The first kilometre was too hot for the rest.",
    "result": "The 5K effort was 30 s off your best.",
    "next": {
        "kind": "easy",
        "km": 4.0,
        "pace": "5:40",
        "detail": "Easy 4 km at 5:40/km.",
        "why": "Base.",
    },
    "frequency": {"runs_per_week": 3, "note": "Three a week."},
}


def _run(user_id: uuid.UUID) -> Run:
    body = run_payload()
    return Run(
        id=uuid.uuid4(),
        user_id=user_id,
        started_at=datetime.now(UTC),
        distance_m=body["distance_m"],
        moving_s=body["moving_s"],
        elapsed_s=body["elapsed_s"],
        gain_m=body["gain_m"],
        loss_m=body["loss_m"],
        splits=body["splits"],
        efforts=body["efforts"],
    )


@pytest_asyncio.fixture
async def user(session: AsyncSession) -> User:
    u = User(display_name="R")
    session.add(u)
    await session.flush()
    return u


def _client(handler: Any) -> tuple[OpenRouterClient, httpx.AsyncClient]:  # noqa: ANN401
    transport = httpx.MockTransport(handler)
    http = httpx.AsyncClient(transport=transport)
    return OpenRouterClient("test-key", "anthropic/claude-sonnet-4.5", http=http), http


async def test_request_shape() -> None:
    seen: dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["auth"] = request.headers["authorization"]
        seen["title"] = request.headers["x-openrouter-title"]
        seen["json"] = json.loads(request.content)
        return httpx.Response(
            200,
            json={
                "id": "gen-123",
                "choices": [{"message": {"content": json.dumps(VALID_OUTPUT)}}],
                "usage": {
                    "prompt_tokens": 900,
                    "completion_tokens": 120,
                    "cost": 0.0042,
                },
            },
        )

    client, http = _client(handler)
    out = await client.complete("SYS", "PKT")
    await http.aclose()
    assert out.text == json.dumps(VALID_OUTPUT)
    assert out.prompt_tokens == 900
    assert out.completion_tokens == 120
    assert out.cost_usd == 0.0042
    assert out.generation_id == "gen-123"
    assert seen["url"] == config.OPENROUTER_URL
    assert seen["auth"] == "Bearer test-key"
    assert seen["title"] == "Jogga"
    body = seen["json"]
    assert body["model"] == "anthropic/claude-sonnet-4.5"
    assert body["response_format"] == {
        "type": "json_schema",
        "json_schema": load_response_schema(),
    }
    assert body["response_format"]["json_schema"]["strict"] is True
    assert body["provider"] == {"require_parameters": True}
    assert body["max_tokens"] == 20000
    assert body["temperature"] == 0.2
    assert "reasoning" not in body
    assert body["usage"] == {"include": True}
    assert body["messages"] == [
        {"role": "system", "content": "SYS"},
        {"role": "user", "content": "PKT"},
    ]


def test_request_body_reasoning(monkeypatch: Any) -> None:
    monkeypatch.setattr(config, "LLM_REASONING", "off")
    assert request_body("m", "s", "u")["reasoning"] == {"enabled": False}
    monkeypatch.setattr(config, "LLM_REASONING", "on")
    assert request_body("m", "s", "u")["reasoning"] == {"enabled": True}
    monkeypatch.setattr(config, "LLM_REASONING", "")
    assert "reasoning" not in request_body("m", "s", "u")


def test_request_body_temperature(monkeypatch: Any) -> None:
    assert request_body("m", "s", "u")["temperature"] == 0.2
    monkeypatch.setattr(config, "LLM_TEMPERATURE", 0.0)
    assert request_body("m", "s", "u")["temperature"] == 0.0


def test_shape_to_pacing_mapping() -> None:
    from jogga.coach import SHAPE_TO_PACING

    assert SHAPE_TO_PACING == {
        "faded": "positive",
        "sped_up": "negative",
        "steady": "even",
        "uneven": "erratic",
    }


def test_parse_pacing_in_reply_rejected() -> None:
    # The schema no longer asks for pacing; an LLM that adds one is refused.
    out = {**VALID_OUTPUT, "pacing": "steady"}
    try:
        parse_coach_output(json.dumps(out), "even")
    except Exception:
        pass
    else:
        raise AssertionError("extra pacing key should fail")


def test_parse_coach_output_llm() -> None:
    out = parse_coach_output(json.dumps(VALID_OUTPUT), "positive")
    assert out.feedback == (
        "Splits held within 4 s/km on flat. The first kilometre was too hot for the rest. "
        "The 5K effort was 30 s off your best."
    )
    assert out.went_well == "Splits held within 4 s/km on flat."
    assert out.work_on == "The first kilometre was too hot for the rest."
    assert out.result == "The 5K effort was 30 s off your best."
    assert out.next.pace == 340 and out.next.kind == "easy"
    assert out.pacing == "positive"  # server-decided, passed in


def test_parse_uses_passed_pacing() -> None:
    assert parse_coach_output(json.dumps(VALID_OUTPUT), "erratic").pacing == "erratic"


def test_parse_em_dash_normalised() -> None:
    out = {
        **VALID_OUTPUT,
        "went_well": "You opened at 5:35 — then faded — a genuine fade.",
        "result": "30:51 sits 3:51 off target—solid baseline.",
    }
    parsed = parse_coach_output(json.dumps(out), "even")
    assert parsed.went_well == "You opened at 5:35, then faded, a genuine fade."
    assert parsed.result == "30:51 sits 3:51 off target, solid baseline."
    assert "—" not in parsed.feedback


def test_parse_en_dash_range_kept() -> None:
    out = {
        **VALID_OUTPUT,
        "next": {**VALID_OUTPUT["next"], "detail": "4 km easy at 7:24–8:01/km."},
    }
    parsed = parse_coach_output(json.dumps(out), "even")
    assert parsed.next.detail == "4 km easy at 7:24–8:01/km."


def test_parse_pace_with_units() -> None:
    out = {**VALID_OUTPUT, "next": {**VALID_OUTPUT["next"], "pace": "8:01"}}
    assert parse_coach_output(json.dumps(out), "even").next.pace == 481
    out["next"]["pace"] = "7:24/km"
    assert parse_coach_output(json.dumps(out), "even").next.pace == 444


def test_parse_pace_bad_values() -> None:
    for bad in ("fast", "481", "7:61", "1:30"):  # 1:30 under the 120 s floor
        out = {**VALID_OUTPUT, "next": {**VALID_OUTPUT["next"], "pace": bad}}
        try:
            parse_coach_output(json.dumps(out), "even")
        except ValueError:
            pass
        else:
            raise AssertionError(f"pace {bad!r} should fail")


def test_parse_km_zero() -> None:
    out = {**VALID_OUTPUT, "next": {**VALID_OUTPUT["next"], "km": 0}}
    try:
        parse_coach_output(json.dumps(out), "even")
    except ValueError:
        pass
    else:
        raise AssertionError("km 0 should fail")


def test_parse_frequency_clamped() -> None:
    out = {**VALID_OUTPUT, "frequency": {"runs_per_week": 12, "note": "n"}}
    assert parse_coach_output(json.dumps(out), "even").frequency.runs_per_week == 7


def test_parse_old_format_rejected() -> None:
    old = {
        "feedback": "f",
        "pacing": "even",
        "next": {"km": 5.0, "pace": 320, "kind": "easy", "detail": "d", "why": "w"},
        "frequency": {"runs_per_week": 3, "note": "n"},
    }
    try:
        parse_coach_output(json.dumps(old), "even")
    except Exception:
        pass
    else:
        raise AssertionError("v1 output should fail")


def test_parse_observation_shape_rejected() -> None:
    # The previous schema (single observation field) must not validate.
    out = {
        "observation": "o",
        "result": "r",
        "next": VALID_OUTPUT["next"],
        "frequency": VALID_OUTPUT["frequency"],
    }
    try:
        parse_coach_output(json.dumps(out), "even")
    except Exception:
        pass
    else:
        raise AssertionError("observation shape should fail")


def test_schema_matches_llm_models() -> None:
    from typing import get_args

    from jogga.schemas import Frequency, LLMCoachOutput, LLMNext, RunKind

    schema = load_response_schema()["schema"]

    def check(model: Any, node: dict[str, Any]) -> None:
        assert list(node["properties"]) == list(model.model_fields)
        assert node["required"] == list(node["properties"])
        assert node["additionalProperties"] is False

    check(LLMCoachOutput, schema)
    check(LLMNext, schema["properties"]["next"])
    check(Frequency, schema["properties"]["frequency"])
    assert schema["properties"]["next"]["properties"]["kind"]["enum"] == list(get_args(RunKind))


async def test_result_without_usage() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"choices": [{"message": {"content": json.dumps(VALID_OUTPUT)}}]}
        )

    client, http = _client(handler)
    out = await client.complete("SYS", "PKT")
    await http.aclose()
    assert out.text == json.dumps(VALID_OUTPUT)
    assert out.prompt_tokens is None
    assert out.cost_usd is None
    assert out.generation_id is None


async def test_llm_source_stored(session: AsyncSession, user: User) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "id": "gen-123",
                "choices": [{"message": {"content": json.dumps(VALID_OUTPUT)}}],
                "usage": {
                    "prompt_tokens": 900,
                    "completion_tokens": 120,
                    "cost": 0.0042,
                },
            },
        )

    client, http = _client(handler)
    run = _run(user.id)
    session.add(run)
    await session.flush()
    note = await coach_run(session, run, llm_client=client)
    await http.aclose()
    assert note.source == "llm"
    assert note.payload["pacing"] == "even"
    assert note.prompt_tokens == 900
    assert note.completion_tokens == 120
    assert note.cost_usd == 0.0042
    assert note.generation_id == "gen-123"
    assert note.latency_ms is not None and note.latency_ms >= 0
    assert note.error is None
    assert note.packet is not None and json.loads(note.packet)["v"] == 6


async def test_llm_retries_after_max_tokens_failure(
    session: AsyncSession, user: User, monkeypatch: Any
) -> None:
    class RetryClient:
        calls = 0

        async def complete(self, system: str, user: str) -> LLMResult:
            self.calls += 1
            if self.calls == 1:
                raise ValueError("OpenRouter response hit max_tokens before any content")
            return LLMResult(
                text=json.dumps(VALID_OUTPUT),
                prompt_tokens=10,
                completion_tokens=20,
                cost_usd=0.01,
                generation_id="gen-retry",
            )

    monkeypatch.setattr(config, "LLM_ATTEMPTS", 2)
    monkeypatch.setattr(config, "LLM_TOTAL_TIMEOUT_S", 50)
    monkeypatch.setattr(config, "LLM_TIMEOUT_S", 40)
    monkeypatch.setattr(config, "LLM_MIN_RETRY_S", 10)
    run = _run(user.id)
    session.add(run)
    await session.flush()

    client = RetryClient()
    note = await coach_run(session, run, llm_client=client)

    assert note.source == "llm"
    assert note.error is None
    assert client.calls == 2
    assert note.generation_id == "gen-retry"
    assert note.prompt_tokens == 10 and note.completion_tokens == 20


async def test_llm_retries_invalid_output_then_falls_back(
    session: AsyncSession, user: User, monkeypatch: Any
) -> None:
    class InvalidClient:
        calls = 0

        async def complete(self, system: str, user: str) -> LLMResult:
            self.calls += 1
            return LLMResult(
                text="not json" if self.calls == 1 else "{}",
                prompt_tokens=None,
                completion_tokens=None,
                cost_usd=None,
                generation_id=None,
            )

    monkeypatch.setattr(config, "LLM_ATTEMPTS", 2)
    monkeypatch.setattr(config, "LLM_TOTAL_TIMEOUT_S", 50)
    monkeypatch.setattr(config, "LLM_TIMEOUT_S", 40)
    monkeypatch.setattr(config, "LLM_MIN_RETRY_S", 10)
    run = _run(user.id)
    session.add(run)
    await session.flush()

    client = InvalidClient()
    note = await coach_run(session, run, llm_client=client)

    assert note.source == "heuristic"
    assert client.calls == 2
    assert note.error is not None
    assert note.error.startswith("ValidationError:")
    assert "LLMCoachOutput" in note.error


async def test_llm_does_not_retry_when_total_budget_is_spent(
    session: AsyncSession, user: User, monkeypatch: Any
) -> None:
    class SlowClient:
        calls = 0

        async def complete(self, system: str, user: str) -> LLMResult:
            self.calls += 1
            await asyncio.sleep(1)
            return LLMResult(
                text=json.dumps(VALID_OUTPUT),
                prompt_tokens=None,
                completion_tokens=None,
                cost_usd=None,
                generation_id=None,
            )

    monkeypatch.setattr(config, "LLM_ATTEMPTS", 2)
    monkeypatch.setattr(config, "LLM_TOTAL_TIMEOUT_S", 0.3)
    monkeypatch.setattr(config, "LLM_TIMEOUT_S", 0.2)
    monkeypatch.setattr(config, "LLM_MIN_RETRY_S", 0.2)
    run = _run(user.id)
    session.add(run)
    await session.flush()

    client = SlowClient()
    note = await coach_run(session, run, llm_client=client)

    assert client.calls == 1
    assert note.source == "heuristic"
    assert note.error is not None and "TimeoutError" in note.error


async def test_generation_capture_includes_trace_and_content(
    session: AsyncSession, user: User, monkeypatch: Any
) -> None:
    captured: list[tuple[str, str, dict[str, Any]]] = []

    class FakePostHog:
        def capture(self, event: str, *, distinct_id: str, properties: dict[str, Any]) -> None:
            captured.append((event, distinct_id, properties))

    monkeypatch.setattr("jogga.coach.get_posthog_client", lambda: FakePostHog())

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "id": "gen-123",
                "choices": [{"message": {"content": json.dumps(VALID_OUTPUT)}}],
                "usage": {
                    "prompt_tokens": 900,
                    "completion_tokens": 120,
                    "cost": 0.0042,
                },
            },
        )

    client, http = _client(handler)
    run = _run(user.id)
    session.add(run)
    await session.flush()
    note = await coach_run(session, run, llm_client=client)
    await http.aclose()

    assert len(captured) == 1
    event, distinct_id, properties = captured[0]
    assert event == "$ai_generation"
    assert distinct_id == str(user.id).upper()
    assert "$ai_model" in properties
    assert properties["$ai_trace_id"] == str(run.id)
    assert properties["$ai_session_id"] is None
    packet = properties["$ai_input"][1]["content"]
    assert note.packet == packet
    forbidden_keys = {
        "route",
        "lat",
        "lon",
        "lng",
        "latitude",
        "longitude",
        "coords",
        "hr",
        "heart_rate",
        "heartRate",
    }

    def has_forbidden_key(value: Any) -> bool:
        if isinstance(value, dict):
            return bool(forbidden_keys.intersection(value)) or any(
                has_forbidden_key(item) for item in value.values()
            )
        if isinstance(value, list):
            return any(has_forbidden_key(item) for item in value)
        return False

    assert not has_forbidden_key(json.loads(packet))
    assert properties["$ai_output_choices"][0]["content"] == json.dumps(VALID_OUTPUT)


async def test_server_error_falls_back(session: AsyncSession, user: User) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "boom"})

    client, http = _client(handler)
    run = _run(user.id)
    session.add(run)
    await session.flush()
    note = await coach_run(session, run, llm_client=client)
    await http.aclose()
    assert note.source == "heuristic"
    assert note.error is not None and "500" in note.error
    assert note.latency_ms is not None
    assert note.packet is not None


async def test_no_key_path(session: AsyncSession, user: User) -> None:
    run = _run(user.id)
    session.add(run)
    await session.flush()
    note = await coach_run(session, run)  # conftest pops OPENROUTER_API_KEY
    assert note.source == "heuristic"
    assert note.error == "no api key"
    assert note.packet is None
    assert note.latency_ms is None


async def test_failed_rerun_keeps_llm_note(session: AsyncSession, user: User) -> None:
    def ok(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"choices": [{"message": {"content": json.dumps(VALID_OUTPUT)}}]}
        )

    def truncated(request: httpx.Request) -> httpx.Response:
        choice = {"message": {"content": None}, "finish_reason": "length"}
        return httpx.Response(200, json={"choices": [choice]})

    run = _run(user.id)
    session.add(run)
    await session.flush()
    client, http = _client(ok)
    first = await coach_run(session, run, llm_client=client)
    await http.aclose()
    client, http = _client(truncated)
    second = await coach_run(session, run, llm_client=client)
    await http.aclose()
    assert second.source == "llm" and second.payload == first.payload


async def test_truncated_response_error(session: AsyncSession, user: User) -> None:
    def truncated(request: httpx.Request) -> httpx.Response:
        choice = {"message": {"content": None}, "finish_reason": "length"}
        return httpx.Response(200, json={"choices": [choice]})

    run = _run(user.id)
    session.add(run)
    await session.flush()
    client, http = _client(truncated)
    note = await coach_run(session, run, llm_client=client)
    await http.aclose()
    assert note.source == "heuristic"
    assert note.error is not None and "max_tokens" in note.error
