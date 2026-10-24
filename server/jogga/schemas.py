"""Pydantic schemas for request/response bodies and coach output."""

import uuid
from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

STANDARD_DISTANCES: dict[str, float] = {
    "5k": 5000.0,
    "10k": 10000.0,
    "half": 21097.5,
    "marathon": 42195.0,
}

RunKind = Literal["easy", "steady", "tempo", "intervals", "long", "race"]
Pacing = Literal["even", "positive", "negative", "erratic"]
Shape = Literal["faded", "sped_up", "steady", "uneven"]


class Split(BaseModel):
    """One split of a run: a full km or a final partial >= 50 m."""

    distance_m: float
    moving_s: float
    gain_m: float
    loss_m: float


class RunIn(BaseModel):
    """Run body sent by the app."""

    id: uuid.UUID
    started_at: datetime
    distance_m: float
    moving_s: float
    elapsed_s: float
    gain_m: float = 0.0
    loss_m: float = 0.0
    splits: list[Split] = Field(default_factory=list)
    efforts: dict[str, float] = Field(default_factory=dict)
    mode: Literal["plan", "race", "free"] | None = None
    tz: str | None = Field(default=None, max_length=64)


class RunOut(RunIn):
    """Run as stored."""

    model_config = ConfigDict(from_attributes=True)

    source: str = "jogga"
    external_id: str | None = None


ImportSource = Literal["strava"]


class ImportRunIn(RunIn):
    """One imported run: a summary only, keyed by its id in the source service."""

    external_id: str = Field(min_length=1, max_length=64)


class RunImportIn(BaseModel):
    """Batch of imported runs. Never coached: imported history only adds context."""

    source: ImportSource
    runs: list[ImportRunIn] = Field(max_length=200)


class RunImportOut(BaseModel):
    """Import result: server ids per external id, plus duplicates of recorded runs."""

    imported: int
    ids: dict[str, uuid.UUID]
    skipped: list[str]


class NextRun(BaseModel):
    """Suggested next run."""

    km: float
    pace: int
    kind: RunKind
    detail: str
    why: str


class Frequency(BaseModel):
    """Suggested weekly frequency."""

    runs_per_week: int
    note: str


class LLMNext(BaseModel):
    """Next run as the structured-output schema returns it (pace is "m:ss")."""

    model_config = ConfigDict(extra="forbid")

    kind: RunKind
    km: float
    pace: str
    detail: str
    why: str


class LLMForecast(BaseModel):
    """Predicted next run as the structured-output schema returns it (pace is "m:ss")."""

    model_config = ConfigDict(extra="forbid")

    km: float
    pace: str


class Forecast(BaseModel):
    """What the coach expects the runner to actually run next (pace in s/km)."""

    km: float
    pace: int


class LLMCoachOutput(BaseModel):
    """Raw shape of the json_schema response, before pace/feedback normalisation."""

    model_config = ConfigDict(extra="forbid")

    went_well: str
    work_on: str
    result: str
    forecast: LLMForecast


class CoachOutput(BaseModel):
    """Validated coach payload, LLM or heuristic."""

    feedback: str
    pacing: Pacing
    # Only the rules-based coach still suggests a next run; the week plan does that now.
    next: NextRun | None = None
    frequency: Frequency | None = None
    went_well: str | None = None
    work_on: str | None = None
    result: str | None = None
    forecast: Forecast | None = None


class CoachNoteOut(BaseModel):
    """Coach note returned with a run."""

    model_config = ConfigDict(from_attributes=True)

    source: str
    model: str | None
    payload: CoachOutput
    created_at: datetime


class UserOut(BaseModel):
    """User as returned to the app."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    display_name: str | None


class DistanceStats(BaseModel):
    """Aggregate stats for one standard distance."""

    best_s: float | None
    last_s: float | None
    count: int
    count_4w: int


class AuthIn(BaseModel):
    """Sign in with Apple body."""

    identity_token: str
    name: str | None = None


class DevAuthIn(BaseModel):
    """Dev sign-in body (JOGGA_DEV_AUTH=1 only)."""

    name: str


class TargetIn(BaseModel):
    """Target body."""

    target_s: int


ReportCategory = Literal["consistency", "pacing", "balance", "load", "progress"]


class ReportFocus(BaseModel):
    model_config = ConfigDict(extra="forbid")

    category: ReportCategory
    action: str


class ReportSummary(BaseModel):
    """Weekly report-card text. Grades come from the server, never from here."""

    model_config = ConfigDict(extra="forbid")

    headline: str
    summary: str
    focus: ReportFocus


Difficulty = Literal["easy", "moderate", "hard", "max"]
CoachingRating = Literal["spot_on", "too_much", "too_little", "off"]
InjuryArea = Literal["foot", "calf", "knee", "hip", "back", "other"]
InjurySeverity = Literal["niggle", "sore", "stopped"]


class SurveyIn(BaseModel):
    """Post-run check-in. Injuries and notes stay in Postgres, never analytics."""

    model_config = ConfigDict(extra="forbid")

    difficulty: Difficulty | None = None
    coaching: CoachingRating | None = None
    injury: bool = False
    injury_area: InjuryArea | None = None
    injury_severity: InjurySeverity | None = None
    notes: str | None = Field(default=None, max_length=500)


Goal = Literal["5k", "10k", "half", "marathon", "fitness"]
Experience = Literal["new", "returning", "regular"]
Dislike = Literal["track", "intervals", "hills", "long_runs", "tempo"]


class ProfileIn(BaseModel):
    """Onboarding answers. Niggles stay in Postgres and the planner, never analytics."""

    model_config = ConfigDict(extra="forbid")

    goal: Goal | None = None
    race_date: date | None = None
    days: list[int] = Field(default_factory=list, max_length=7)
    runs_per_week: int | None = Field(default=None, ge=1, le=7)
    experience: Experience | None = None
    usual_week_km: float | None = Field(default=None, ge=0, le=300)
    dislikes: list[Dislike] = Field(default_factory=list, max_length=5)
    niggles: str | None = Field(default=None, max_length=300)
    consent: bool = False
