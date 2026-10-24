"""Unit tests for the Strava replay parser and grader."""

import asyncio
import csv
import gzip
import json
import math
import xml.etree.ElementTree as ET
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

from jogga.replay import endomondo
from jogga.replay.__main__ import (
    REPLAY_METADATA,
    _forecast_scores,
    _summary,
    regrade,
    replay,
)
from jogga.replay.endomondo import load_runner, read_workout, select_runners, workout_run
from jogga.replay.grade import grade
from jogga.replay.strava import ReplayRun, load_export, parse_gpx, route_run

GPX_NAMESPACE = "http://www.topografix.com/GPX/1/1"
EARTH_RADIUS_M = 6_371_000.0
SPEED_MPS = 3.0
ORIGIN_LATITUDE = 45.0
START = datetime(2026, 10, 1, 7, 46, 35, tzinfo=UTC)


def _endomondo_workout(
    workout_id: str,
    start_ts: float,
    *,
    speed_mps: float = 2.5,
    interval_s: float = 1.0,
) -> dict[str, Any]:
    timestamps = [start_ts + i * interval_s for i in range(500)]
    return {
        "id": workout_id,
        "timestamp": timestamps,
        "latitude": [
            ORIGIN_LATITUDE + math.degrees(i * speed_mps * interval_s / EARTH_RADIUS_M)
            for i in range(500)
        ],
        "longitude": [0.0] * 500,
        "altitude": [100.0] * 500,
    }


def _write_endomondo(
    tmp_path: Path, workouts_by_user: dict[int, list[dict[str, Any]]]
) -> tuple[Path, Path]:
    data_path = tmp_path / "endomondo.json"
    index_path = tmp_path / "index.jsonl"
    with data_path.open("wb") as data_file, index_path.open("w", encoding="utf-8") as index_file:
        for user, workouts in workouts_by_user.items():
            for workout in workouts:
                line = repr(workout).encode("utf-8") + b"\n"
                offset = data_file.tell()
                data_file.write(line)
                index_file.write(
                    json.dumps(
                        {
                            "u": user,
                            "id": workout["id"],
                            "t": workout["timestamp"][0],
                            "off": offset,
                            "len": len(line),
                        }
                    )
                    + "\n"
                )
    return data_path, index_path


def _gpx(
    steps: int,
    *,
    pause_after: int | None = None,
    jump_at: int | None = None,
    elevations: list[float] | None = None,
    start: datetime = START,
) -> str:
    if elevations is not None:
        assert len(elevations) == steps + 1

    root = ET.Element(
        f"{{{GPX_NAMESPACE}}}gpx",
        {"version": "1.1", "creator": "jogga replay tests"},
    )
    track = ET.SubElement(root, f"{{{GPX_NAMESPACE}}}trk")
    segment = ET.SubElement(track, f"{{{GPX_NAMESPACE}}}trkseg")
    for i in range(steps + 1):
        northing = i * SPEED_MPS + (500.0 if i == jump_at else 0.0)
        latitude = ORIGIN_LATITUDE + math.degrees(northing / EARTH_RADIUS_M)
        point = ET.SubElement(
            segment,
            f"{{{GPX_NAMESPACE}}}trkpt",
            {"lat": f"{latitude:.12f}", "lon": "0.0"},
        )
        elevation = elevations[i] if elevations is not None else 100.0
        ET.SubElement(point, f"{{{GPX_NAMESPACE}}}ele").text = str(elevation)
        offset = i + (59 if pause_after is not None and i >= pause_after else 0)
        timestamp = start + timedelta(seconds=offset)
        ET.SubElement(point, f"{{{GPX_NAMESPACE}}}time").text = timestamp.isoformat().replace(
            "+00:00", "Z"
        )
    return ET.tostring(root, encoding="unicode")


def _route(steps: int, **kwargs: Any) -> Any:
    run = route_run("synthetic-run", None, parse_gpx(_gpx(steps, **kwargs).encode()))
    assert run is not None
    return run


def test_route_distance_moving_time_splits_and_efforts() -> None:
    steps = 734
    expected_distance = steps * SPEED_MPS
    run = _route(steps)

    assert run.distance_m == pytest.approx(expected_distance, rel=0.01)
    assert run.moving_s == pytest.approx(steps)
    assert len(run.splits) == 3
    assert run.splits[0]["distance_m"] == pytest.approx(1000)
    assert run.splits[1]["distance_m"] == pytest.approx(1000)
    assert run.splits[2]["distance_m"] >= 50
    assert sum(split["distance_m"] for split in run.splits) == pytest.approx(run.distance_m)
    assert "5k" not in run.efforts


def test_route_records_5k_effort_at_crossing_time() -> None:
    run = _route(1700)

    assert run.efforts["5k"] == pytest.approx(5000 / SPEED_MPS, abs=2)


def test_pause_gap_is_excluded_from_moving_time_and_included_in_elapsed_time() -> None:
    steps = 734
    run = _route(steps, pause_after=367)

    assert run.moving_s == pytest.approx(steps - 1)
    assert run.elapsed_s == pytest.approx(steps + 59)


def test_pause_gap_can_be_extended_without_changing_the_default() -> None:
    points = [
        (ORIGIN_LATITUDE, 0.0, 100.0, START),
        (
            ORIGIN_LATITUDE + math.degrees(3 / EARTH_RADIUS_M),
            0.0,
            100.0,
            START + timedelta(seconds=1),
        ),
        (
            ORIGIN_LATITUDE + math.degrees(6 / EARTH_RADIUS_M),
            0.0,
            100.0,
            START + timedelta(seconds=21),
        ),
    ]

    default_run = route_run("default-gap", None, points)
    endomondo_run = route_run("endo-gap", None, points, pause_gap_s=30.0)

    assert default_run is not None and endomondo_run is not None
    assert default_run.moving_s == pytest.approx(1)
    assert default_run.elapsed_s == pytest.approx(21)
    assert endomondo_run.moving_s == pytest.approx(21)
    assert endomondo_run.elapsed_s == pytest.approx(21)


def test_speed_filter_drops_a_single_gps_jump() -> None:
    steps = 734
    run = _route(steps, jump_at=367)

    assert run.distance_m == pytest.approx(steps * SPEED_MPS, rel=0.01)


def test_elevation_hysteresis_ignores_small_wiggles_and_counts_climb() -> None:
    elevations = [100.0, 101.0, 99.0, 100.0, 110.0, 111.0, 109.0, 110.0] + [110.0] * 13
    run = _route(20, elevations=elevations)

    assert run.gain_m == pytest.approx(10)
    assert run.loss_m == pytest.approx(0)


def test_load_export_reads_routes_fallbacks_gzip_and_duplicate_columns(tmp_path: Path) -> None:
    header = [
        "Activity ID",
        "Activity Date",
        "Activity Type",
        "Elapsed Time",
        "Moving Time",
        "Elapsed Time",
        "Distance",
        "Distance",
        "Elevation Gain",
        "Elevation Loss",
        "Filename",
    ]
    rows = [
        [
            "route-run",
            "Oct 2, 2026, 7:46:35 AM",
            "Run",
            "295",
            "290",
            "300",
            "0.9",
            "900",
            "12",
            "3",
            "route.gpx",
        ],
        [
            "summary-run",
            "Oct 1, 2026, 7:46:35 AM",
            "Run",
            "1790",
            "1700",
            "1800",
            "5.2",
            "5207",
            "24",
            "5",
            "",
        ],
        [
            "ride",
            "Oct 3, 2026, 7:46:35 AM",
            "Ride",
            "600",
            "580",
            "610",
            "15.0",
            "15000",
            "100",
            "100",
            "ride.gpx",
        ],
        [
            "gzip-run",
            "Oct 4, 2026, 7:46:35 AM",
            "Trail Run",
            "400",
            "390",
            "410",
            "1.2",
            "1200",
            "8",
            "2",
            "compressed.gpx.gz",
        ],
    ]
    with (tmp_path / "activities.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(rows)
    (tmp_path / "route.gpx").write_text(
        _gpx(100, start=datetime(2026, 10, 2, 7, 46, 35, tzinfo=UTC)), encoding="utf-8"
    )
    (tmp_path / "compressed.gpx.gz").write_bytes(
        gzip.compress(_gpx(120, start=datetime(2026, 10, 4, 7, 46, 35, tzinfo=UTC)).encode())
    )

    runs, counts = load_export(tmp_path)

    assert counts == {
        "activities": 4,
        "runs": 3,
        "with_route": 2,
        "summary_only": 1,
        "unreadable": 0,
    }
    assert [run.external_id for run in runs] == ["summary-run", "route-run", "gzip-run"]
    summary = runs[0]
    assert summary.distance_m == pytest.approx(5207)
    assert summary.moving_s == pytest.approx(1700)
    assert summary.gain_m == pytest.approx(24)
    assert summary.loss_m == pytest.approx(5)
    assert not summary.from_route
    assert runs[1].from_route and runs[2].from_route


FIT: dict[str, Any] = {
    "zones": {
        "easy": ["5:00", "6:00"],
        "steady": "4:45",
        "tempo": "4:30",
        "intervals": "4:00",
    },
    "pred": {"5k": "0:25:00"},
}


def _packet(
    *,
    fit: dict[str, Any] | None = FIT,
    long4w: float = 20,
    runs: int = 1,
    effort_rows: list[list[str]] | None = None,
) -> dict[str, Any]:
    return {
        "fit": fit,
        "long4w": long4w,
        "day": {"runs": runs},
        "run": {"eff": {"rows": effort_rows or []}},
    }


def _note(kind: str = "easy", pace: int = 330, km: float = 5) -> dict[str, Any]:
    return {
        "went_well": "The effort stayed controlled.",
        "work_on": "Keep the first kilometres relaxed.",
        "result": "A useful aerobic session.",
        "next": {
            "kind": kind,
            "pace": pace,
            "km": km,
            "detail": "Run at a relaxed pace.",
            "why": "This supports consistent training.",
        },
        "frequency": {"note": "Keep a steady weekly routine."},
    }


def _grade(
    *,
    kind: str = "easy",
    pace: int = 330,
    km: float = 5,
    source: str = "heuristic",
    packet: dict[str, Any] | None = None,
    note: dict[str, Any] | None = None,
) -> dict[str, bool | None]:
    actual_packet = packet if packet is not None else _packet()
    actual_note = note if note is not None else _note(kind, pace, km)
    return grade(json.dumps(actual_packet), actual_note, source)


@pytest.mark.parametrize(
    ("kind", "pace", "fit", "expected"),
    [
        ("easy", 290, FIT, True),
        ("easy", 370, FIT, True),
        ("easy", 289, FIT, False),
        ("tempo", 280, FIT, True),
        ("tempo", 281, FIT, False),
        ("race", 300, FIT, None),
        ("easy", 300, None, None),
    ],
)
def test_pace_in_zone(
    kind: str, pace: int, fit: dict[str, Any] | None, expected: bool | None
) -> None:
    assert (
        _grade(
            kind=kind,
            pace=pace,
            packet=_packet(fit=fit),
        )["pace_in_zone"]
        is expected
    )


@pytest.mark.parametrize(("km", "expected"), [(25.1, True), (25.11, False)])
def test_distance_cap_includes_growth_and_slack(km: float, expected: bool) -> None:
    assert _grade(km=km, packet=_packet(long4w=20))["distance_cap"] is expected


@pytest.mark.parametrize(
    ("kind", "runs", "expected"),
    [("easy", 2, True), ("tempo", 2, False), ("easy", 1, None)],
)
def test_easy_after_double(kind: str, runs: int, expected: bool | None) -> None:
    assert _grade(kind=kind, packet=_packet(runs=runs))["easy_after_double"] is expected


@pytest.mark.parametrize(
    ("kind", "effort", "expected"),
    [
        ("easy", "25:30", True),
        ("tempo", "25:30", False),
        ("tempo", "25:31", None),
    ],
)
def test_no_hard_after_hard_uses_prediction_margin(
    kind: str, effort: str, expected: bool | None
) -> None:
    packet = _packet(effort_rows=[["5k", effort]])
    assert _grade(kind=kind, packet=packet)["no_hard_after_hard"] is expected


def test_no_hard_after_hard_is_not_applicable_without_fitness() -> None:
    assert (
        _grade(packet=_packet(fit=None, effort_rows=[["5k", "20:00"]]))["no_hard_after_hard"]
        is None
    )


def test_length_and_tone_checks_are_only_applied_to_llm_notes() -> None:
    checks = _grade(source="heuristic")

    assert checks["length_limits"] is None
    assert checks["tone_rules"] is None


def test_length_limits_pass_and_fail() -> None:
    assert _grade(source="llm")["length_limits"] is True

    note = _note()
    note["went_well"] = " ".join(["word"] * 26)
    assert _grade(source="llm", note=note)["length_limits"] is False


@pytest.mark.parametrize("text", ["An excellent session!", "An excellent session — keep going."])
def test_tone_rules_reject_exclamation_and_em_dash(text: str) -> None:
    note = _note()
    note["work_on"] = text

    assert _grade(source="llm", note=note)["tone_rules"] is False


def test_tone_rules_accept_plain_language() -> None:
    assert _grade(source="llm")["tone_rules"] is True


def test_forecast_scores_compare_coach_and_baselines() -> None:
    rows = [
        {"km": 4.0, "pace_s": 360, "note": {"forecast": {"km": 5.0, "pace": 330}}},
        {"km": 5.0, "pace_s": 300, "note": {"forecast": {"km": 6.0, "pace": 270}}},
        {"km": 4.0, "pace_s": 390, "note": {"forecast": {"km": 4.0, "pace": 360}}},
    ]

    assert _forecast_scores(rows) == {
        "n": 2,
        "mae": {
            "coach": {"km": 1.0, "pace_s": 75.0},
            "last_run": {"km": 1.0, "pace_s": 75.0},
            "median_last_5": {"km": 0.75, "pace_s": 60.0},
        },
    }


def test_workout_run_filters_distance_and_pace() -> None:
    assert workout_run(_endomondo_workout("short", START.timestamp(), speed_mps=1.5)) is None
    assert (
        workout_run(_endomondo_workout("slow", START.timestamp(), speed_mps=1.0, interval_s=2.5))
        is None
    )
    assert workout_run(_endomondo_workout("fast", START.timestamp(), speed_mps=9.0)) is None

    run = workout_run(_endomondo_workout("plausible", START.timestamp()))

    assert run is not None
    assert run.external_id == "endo:plausible"
    assert run.started_at == START
    assert run.distance_m == pytest.approx(499 * 2.5, rel=0.01)
    assert run.moving_s == pytest.approx(499)
    assert run.moving_s / (run.distance_m / 1000) == pytest.approx(400, rel=0.01)


def test_read_workout_round_trips_dict_literal_offsets(tmp_path: Path) -> None:
    first = _endomondo_workout("first", START.timestamp())
    second = _endomondo_workout("second", START.timestamp() + 1000)
    data_path, _ = _write_endomondo(tmp_path, {1: [first, second]})
    second_line = (repr(second) + "\n").encode("utf-8")
    offset = len((repr(first) + "\n").encode("utf-8"))

    assert read_workout(data_path, offset, len(second_line)) == second


def test_select_runners_is_deterministic_and_applies_selection_rules(
    tmp_path: Path, monkeypatch: Any
) -> None:
    monkeypatch.setattr(endomondo, "MIN_INDEX_WORKOUTS", 3)
    monkeypatch.setattr(endomondo, "CANDIDATE_COUNT", 4)
    monkeypatch.setattr(endomondo, "MIN_VALID_WORKOUTS", 3)
    monkeypatch.setattr(endomondo, "MAX_WORKOUTS_PER_RUNNER", 3)
    monkeypatch.setattr(endomondo, "QUALIFYING_RUNNERS", 2)
    monkeypatch.setattr(endomondo, "HOLDOUT_RUNNERS", 1)

    base = START.timestamp()
    workouts_by_user = {
        user: [
            _endomondo_workout(
                f"{user}-{i}",
                base + i * 86_400,
                speed_mps=2.5 if user != 30 or i < 2 else 1.5,
            )
            for i in range(count)
        ]
        for user, count in ((10, 5), (20, 5), (30, 5), (40, 5), (50, 2))
    }
    data_path, index_path = _write_endomondo(tmp_path, workouts_by_user)

    selection = select_runners(data_path, index_path)

    assert selection == select_runners(data_path, index_path)
    assert selection["seed"] == 20261023
    assert selection["pause_gap_s"] == 30.0
    assert len(selection["runners"]) == 2
    assert [runner["split"] for runner in selection["runners"]] == ["holdout", "train"]
    assert 30 not in [runner["user"] for runner in selection["runners"]]
    assert 50 not in [runner["user"] for runner in selection["runners"]]
    for runner in selection["runners"]:
        assert [workout["id"] for workout in runner["workouts"]] == [
            f"{runner['user']}-{i}" for i in (2, 3, 4)
        ]
        runs = load_runner(data_path, runner)
        assert [run.external_id for run in runs] == [
            f"endo:{runner['user']}-{i}" for i in (2, 3, 4)
        ]


def test_forecast_scores_do_not_cross_runner_boundaries() -> None:
    rows = [
        {
            "runner": 1,
            "i": 0,
            "km": 4.0,
            "pace_s": 360,
            "note": {"forecast": {"km": 5.0, "pace": 330}},
        },
        {
            "runner": 1,
            "i": 1,
            "km": 5.0,
            "pace_s": 300,
            "note": {"forecast": {"km": 6.0, "pace": 270}},
        },
        {
            "runner": 2,
            "i": 0,
            "km": 10.0,
            "pace_s": 600,
            "note": {"forecast": {"km": 12.0, "pace": 540}},
        },
        {
            "runner": 2,
            "i": 1,
            "km": 11.0,
            "pace_s": 540,
            "note": {"forecast": {"km": 13.0, "pace": 500}},
        },
    ]

    assert _forecast_scores(rows) == {
        "n": 2,
        "mae": {
            "coach": {"km": 0.5, "pace_s": 15.0},
            "last_run": {"km": 1.0, "pace_s": 60.0},
            "median_last_5": {"km": 1.0, "pace_s": 60.0},
        },
    }


def test_multi_runner_summary_reports_split_and_runner_counts() -> None:
    rows = [
        {
            "runner": 1,
            "split": "train",
            "i": 0,
            "km": 4.0,
            "pace_s": 360,
            "note": {"forecast": None},
            "checks": {"tone": True},
            "source": "heuristic",
            "latency_ms": None,
            "cost_usd": None,
        },
        {
            "runner": 2,
            "split": "holdout",
            "i": 0,
            "km": 5.0,
            "pace_s": 300,
            "note": {"forecast": None},
            "checks": {"tone": False},
            "source": "heuristic",
            "latency_ms": None,
            "cost_usd": None,
        },
    ]

    summary = _summary(
        rows,
        {"runners": 2, "workouts": 2},
        "heuristic",
        multi_runner=True,
        holdout_coach="heuristic",
    )

    assert summary["notes"] == 2
    assert summary["by_split"]["train"]["notes"] == 1
    assert summary["by_split"]["holdout"]["notes"] == 1
    assert summary["by_split"]["train"]["checks"]["tone"]["rate"] == 1.0
    assert summary["by_split"]["holdout"]["checks"]["tone"]["rate"] == 0.0
    assert summary["runners"] == {"1": 1, "2": 1}


def test_replay_persists_completed_rows_before_coach_failure(
    tmp_path: Path, monkeypatch: Any
) -> None:
    class FakeConnection:
        async def run_sync(self, callback: Any) -> None:
            pass

    class FakeEngineContext:
        async def __aenter__(self) -> FakeConnection:
            return FakeConnection()

        async def __aexit__(self, *args: Any) -> None:
            pass

    class FakeEngine:
        def begin(self) -> FakeEngineContext:
            return FakeEngineContext()

        async def dispose(self) -> None:
            pass

    class FakeSession:
        def add(self, row: Any) -> None:
            pass

        async def flush(self) -> None:
            pass

        async def commit(self) -> None:
            pass

        async def __aenter__(self) -> Any:
            return self

        async def __aexit__(self, *args: Any) -> None:
            pass

    runs = [
        ReplayRun(
            external_id=f"run-{i}",
            started_at=START + timedelta(days=i),
            distance_m=5000.0,
            moving_s=1600.0,
            elapsed_s=1630.0,
            gain_m=10.0,
            loss_m=8.0,
        )
        for i in range(3)
    ]
    output = tmp_path / "partial"
    output.mkdir()
    notes_path = output / "notes.jsonl"
    notes_path.write_text("stale row\n", encoding="utf-8")

    async def fake_ensure_db(_url: str) -> None:
        pass

    monkeypatch.setattr(
        "jogga.replay.__main__._ensure_db",
        fake_ensure_db,
    )
    monkeypatch.setattr(
        "jogga.replay.__main__.create_async_engine",
        lambda *_args, **_kwargs: FakeEngine(),
    )
    monkeypatch.setattr(
        "jogga.replay.__main__.async_sessionmaker",
        lambda *_args, **_kwargs: lambda: FakeSession(),
    )
    monkeypatch.setattr(
        "jogga.replay.__main__.load_export",
        lambda _path: (runs, {"activities": 3, "runs": 3}),
    )

    async def fake_build_packet(_db: Any, _run: Any) -> str:
        return json.dumps(_packet())

    calls = 0

    async def failing_coach(_db: Any, _run: Any, *, llm_client: Any) -> SimpleNamespace:
        nonlocal calls
        calls += 1
        if calls > 2:
            raise RuntimeError("stub coach failure")
        return SimpleNamespace(
            payload=_note(),
            source="heuristic",
            model=None,
            latency_ms=None,
            cost_usd=None,
            error=None,
        )

    monkeypatch.setattr("jogga.replay.__main__.build_packet", fake_build_packet)
    monkeypatch.setattr("jogga.replay.__main__.coach_run", failing_coach)
    args = SimpleNamespace(
        endomondo=None,
        export=tmp_path,
        limit=0,
        coach="heuristic",
        holdout_coach="mubit-norecord",
        db="unused",
        out=output,
        concurrency=1,
        target=[],
    )

    with pytest.raises(RuntimeError, match="stub coach failure"):
        asyncio.run(replay(args))

    rows = [json.loads(line) for line in notes_path.read_text(encoding="utf-8").splitlines()]
    assert [row["i"] for row in rows] == [0, 1]


def test_regrade_sorts_partial_rows_and_allows_missing_trailing_rows(tmp_path: Path) -> None:
    output = tmp_path / "partial"
    output.mkdir()

    def row(
        runner: int, i: int, km: float, pace_s: float, forecast: dict[str, Any]
    ) -> dict[str, Any]:
        note = _note()
        note["forecast"] = forecast
        return {
            "runner": runner,
            "split": "train" if runner == 1 else "holdout",
            "i": i,
            "km": km,
            "pace_s": pace_s,
            "source": "heuristic",
            "model": None,
            "latency_ms": None,
            "cost_usd": None,
            "error": None,
            "note": note,
            "packet": _packet(),
        }

    rows = [
        row(2, 0, 10.0, 600, {"km": 12.0, "pace": 540}),
        row(1, 1, 5.0, 300, {"km": 6.0, "pace": 270}),
        row(1, 0, 4.0, 360, {"km": 4.5, "pace": 330}),
    ]
    (output / "notes.jsonl").write_text(
        "".join(json.dumps(saved) + "\n" for saved in rows), encoding="utf-8"
    )
    (output / REPLAY_METADATA).write_text(
        json.dumps(
            {
                "export": {"runners": 2, "workouts": 5},
                "coach": "mubit",
                "model": "test-model",
                "multi_runner": True,
                "holdout_coach": "mubit-norecord",
            }
        ),
        encoding="utf-8",
    )

    regrade(output)

    saved = [
        json.loads(line)
        for line in (output / "notes.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    summary = json.loads((output / "summary.json").read_text(encoding="utf-8"))
    assert [(entry["runner"], entry["i"]) for entry in saved] == [(1, 0), (1, 1), (2, 0)]
    assert summary["notes"] == 3
    assert summary["forecast"]["n"] == 1
    assert summary["forecast"]["mae"]["coach"] == {"km": 0.5, "pace_s": 30.0}
    assert summary["by_split"]["train"]["notes"] == 2
    assert summary["by_split"]["holdout"]["notes"] == 1
    assert not (output / REPLAY_METADATA).exists()


def test_tone_rules_flag_gap_acronym_but_not_the_word_gap() -> None:
    note = _note()
    note["work_on"] = "Close the gap to your 5k best with easy running."
    assert _grade(source="llm", note=note)["tone_rules"] is True

    note["work_on"] = "Your GAP was 5:40/km."
    assert _grade(source="llm", note=note)["tone_rules"] is False
