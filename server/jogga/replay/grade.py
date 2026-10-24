"""Grade one coach note against the coaching rules in prompts/coach_system.md.

Prescriptions are judged only by those rules, never by what the runner did next:
the replayed runs happened before any of these notes existed.
Each check returns True (pass), False (fail) or None (rule does not apply).
"""

import json
import re
from typing import Any

from ..fitness import parse_pace

QUALITY = {"steady", "tempo", "intervals"}
ZONE_TOLERANCE_S = 10
DISTANCE_GROWTH = 1.25
DISTANCE_SLACK_KM = 0.1
HARD_EFFORT_MARGIN = 1.02
WORD_LIMITS = {"went_well": 25, "work_on": 30, "result": 25}
NEXT_WORD_LIMITS = {"detail": 15, "why": 25}
BANNED = [
    "solid baseline",
    "solid first marker",
    "tells the story",
    "it's worth noting",
    "journey",
    "crush it",
    "great job",
    "the key is",
    "grade-adjusted",
    "flat-equivalent",
]


def _words(text: str) -> int:
    return len(text.split())


def _texts(note: dict[str, Any]) -> list[str]:
    nxt = note.get("next") or {}
    freq = note.get("frequency") or {}
    keys = ("went_well", "work_on", "result")
    return [
        str(v)
        for v in [*(note.get(k) for k in keys), nxt.get("detail"), nxt.get("why"), freq.get("note")]
        if v
    ]


def grade(packet_json: str, note: dict[str, Any], source: str) -> dict[str, bool | None]:
    packet: dict[str, Any] = json.loads(packet_json)
    # Prescription checks only apply to notes that carry a next run (old notes, the
    # rules-based coach); the week plan prescribes runs now.
    nxt: dict[str, Any] = note.get("next") or {}
    kind = str(nxt.get("kind", ""))
    pace = int(nxt.get("pace", 0))
    km = float(nxt.get("km", 0.0))
    fit = packet.get("fit")
    run = packet["run"]
    checks: dict[str, bool | None] = {"llm_used": source == "llm"}

    zone_ok: bool | None = None
    if nxt and fit is not None and kind != "race":
        zones = fit["zones"]
        if kind in ("easy", "long"):
            fast, slow = parse_pace(zones["easy"][0]), parse_pace(zones["easy"][1])
            zone_ok = fast - ZONE_TOLERANCE_S <= pace <= slow + ZONE_TOLERANCE_S
        else:
            zone_ok = abs(pace - parse_pace(zones[kind])) <= ZONE_TOLERANCE_S
    checks["pace_in_zone"] = zone_ok

    checks["distance_cap"] = (
        km <= DISTANCE_GROWTH * float(packet["long4w"]) + DISTANCE_SLACK_KM if nxt else None
    )

    checks["easy_after_double"] = kind == "easy" if nxt and packet["day"]["runs"] > 1 else None

    hard_today: bool | None = None
    if fit is not None:
        pred = {d: parse_pace(t) if t.count(":") == 1 else _hms(t) for d, t in fit["pred"].items()}
        eff = {row[0]: row[1] for row in run["eff"]["rows"]}
        hard_today = any(
            d in pred and _to_s(t) <= pred[d] * HARD_EFFORT_MARGIN for d, t in eff.items()
        )
    checks["no_hard_after_hard"] = (kind not in QUALITY | {"race"}) if hard_today and nxt else None

    if source == "llm":
        lengths_ok = all(_words(str(note.get(k) or "")) <= n for k, n in WORD_LIMITS.items())
        lengths_ok &= all(_words(str(nxt.get(k) or "")) <= n for k, n in NEXT_WORD_LIMITS.items())
        lengths_ok &= _words(str((note.get("frequency") or {}).get("note") or "")) <= 25
        checks["length_limits"] = lengths_ok
        raw = " ".join(_texts(note))
        joined = raw.lower()
        checks["tone_rules"] = not (
            any(p in joined for p in BANNED)
            or "!" in joined
            or "—" in joined
            or re.search(r"\bGAP\b", raw) is not None
        )
    else:
        checks["length_limits"] = None
        checks["tone_rules"] = None
    return checks


def _hms(text: str) -> int:
    h, m, s = (int(x) for x in text.split(":"))
    return h * 3600 + m * 60 + s


def _to_s(text: str) -> int:
    return _hms(text) if text.count(":") == 2 else parse_pace(text)
