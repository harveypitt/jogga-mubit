"""Pure fitness maths: GAP paces, Riegel predictions, zones, clamping."""

from datetime import date

import pytest

from jogga.fitness import (
    best_effort,
    fitness,
    fmt_delta,
    fmt_dur,
    gap_pace,
    parse_pace,
    riegel,
    run_shape,
)


def test_fmt_dur() -> None:
    assert fmt_dur(326) == "5:26"
    assert fmt_dur(1851) == "30:51"
    assert fmt_dur(59) == "0:59"
    assert fmt_dur(0) == "0:00"
    assert fmt_dur(3853) == "1:04:13"
    assert fmt_dur(8514) == "2:21:54"
    assert fmt_dur(-12) == "0:00"
    assert fmt_dur(90.6) == "1:31"  # rounds first


def test_fmt_delta() -> None:
    assert fmt_delta(231) == "+3:51"
    assert fmt_delta(-12) == "-0:12"
    assert fmt_delta(0) == "+0:00"
    assert fmt_delta(3700) == "+1:01:40"
    assert fmt_delta(-0.4) == "+0:00"


def test_parse_pace() -> None:
    assert parse_pace("5:26") == 326
    assert parse_pace("8:01") == 481
    assert parse_pace(" 6:09 ") == 369
    assert parse_pace("7:24/km") == 444
    assert parse_pace("0:00") == 0


def test_parse_pace_rejects() -> None:
    for bad in ("fast", "481", "7:61", "7:5", "1:2:34", "+5:00", ""):
        with pytest.raises(ValueError):
            parse_pace(bad)


def test_parse_pace_range_takes_slower_end() -> None:
    assert parse_pace("7:24–8:01") == 481
    assert parse_pace("7:30-8:00/km") == 480
    assert parse_pace("7:24/km – 8:01/km") == 481
    assert parse_pace("8:01–7:24") == 481  # order doesn't matter, slower wins
    assert parse_pace("7:30 to 8:00") == 480


def test_run_shape_production_run_is_faded() -> None:
    splits = [
        {"distance_m": 1000, "moving_s": 335, "gain_m": 18, "loss_m": 18},
        {"distance_m": 1000, "moving_s": 359, "gain_m": 38, "loss_m": 6},
        {"distance_m": 1000, "moving_s": 353, "gain_m": 0, "loss_m": 40},
        {"distance_m": 1000, "moving_s": 359, "gain_m": 16, "loss_m": 7},
        {"distance_m": 1000, "moving_s": 444, "gain_m": 22, "loss_m": 24},
        {"distance_m": 710, "moving_s": 288, "gain_m": 10, "loss_m": 10},
    ]
    assert run_shape(splits) == "faded"


def test_gap_pace_climb() -> None:
    # Split 2 of the sanity run: 359.20 s/km with 38.41 m up, 6.15 m down.
    assert abs(gap_pace(1000, 359.20, 38.41, 6.15) - 322) <= 1


def test_gap_pace_downhillish() -> None:
    # Split 5: 444.20 s/km, 21.57 up, 23.57 down.
    assert abs(gap_pace(1000, 444.20, 21.57, 23.57) - 432) <= 1


def test_gap_pace_zero_distance() -> None:
    assert gap_pace(0, 100, 0, 0) == 0


def test_gap_clamped_steep() -> None:
    # Very steep climb: factor would be >1.5 -> clamped.
    steep = gap_pace(1000, 600, 500, 0)
    assert steep >= round(600 / 1.5)


def test_riegel_5k_to_10k() -> None:
    assert abs(riegel(1850.75, 5.0, 10.0) - 3859) <= 3


def test_fitness_zones_and_pred() -> None:
    fit = fitness((date(2026, 9, 30), "5k", 5.0, 1850.75))
    assert fit["src"] == ["2026-09-30", "5k", 5.0, 1851]
    zones = fit["zones"]
    assert abs(zones["easy"][0] - 444) <= 1
    assert abs(zones["easy"][1] - 481) <= 1
    assert abs(zones["tempo"] - 389) <= 1
    assert abs(zones["intervals"] - 359) <= 1
    pred = fit["pred"]
    assert abs(pred["10k"] - 3859) <= 3
    assert abs(pred["5k"] - 1851) <= 2
    assert pred["half"] > pred["10k"]


def test_best_effort_picks_fastest_5k_equivalent() -> None:
    # A slow whole run vs a fast 5K effort on a different day.
    slow = (date(2026, 9, 1), None, 8.0, 4000.0)  # t5 ~= 2981
    fast = (date(2026, 9, 20), "5k", 5.0, 1500.0)
    assert best_effort([slow, fast]) == fast


def test_best_effort_tie_latest_date() -> None:
    a = (date(2026, 9, 1), "5k", 5.0, 1500.0)
    b = (date(2026, 9, 20), "5k", 5.0, 1500.0)
    assert best_effort([a, b]) == b


def test_best_effort_empty() -> None:
    assert best_effort([]) is None
