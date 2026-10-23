"""Unit tests for the Strava replay parser and grader."""

import csv
import gzip
import json
import math
import xml.etree.ElementTree as ET
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest

from jogga.replay.__main__ import _forecast_scores
from jogga.replay.grade import grade
from jogga.replay.strava import load_export, parse_gpx, route_run

GPX_NAMESPACE = "http://www.topografix.com/GPX/1/1"
EARTH_RADIUS_M = 6_371_000.0
SPEED_MPS = 3.0
ORIGIN_LATITUDE = 45.0
START = datetime(2026, 10, 1, 7, 46, 35, tzinfo=UTC)


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


def test_tone_rules_flag_gap_acronym_but_not_the_word_gap() -> None:
    note = _note()
    note["work_on"] = "Close the gap to your 5k best with easy running."
    assert _grade(source="llm", note=note)["tone_rules"] is True

    note["work_on"] = "Your GAP was 5:40/km."
    assert _grade(source="llm", note=note)["tone_rules"] is False
