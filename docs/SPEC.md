# Jogga — v0 spec

A calm, ad-free running app. It cares about exactly one thing: how fast you run the
standard distances (5K, 10K, Half, Marathon), how that is trending against your target,
and what to do on your next run. No segments, no leaderboards, no social feed.

## Scope (v0)

Sign in with Apple -> set a target -> record a GPS run -> run summary with splits ->
upload to server -> server builds a compact packet -> LLM (or heuristic fallback) returns
feedback + next-run suggestion -> shown in the app.

Explicitly out of scope (listed in README "Not yet"): onboarding flow, HealthKit write /
heart rate, Apple Watch app, Live Activity / lock-screen widget, miles, audio cues,
route sync to server (routes stay on device), social, monetisation.

## Repo layout

```
ios/                 XcodeGen project (project.yml) + generated Jogga.xcodeproj (committed)
  Jogga/             app sources
  JoggaTests/        unit tests (RunMath etc.)
server/              Python 3.12, FastAPI, SQLAlchemy 2 (async, asyncpg), Alembic, Postgres
  jogga/             package
  jogga/prompts/coach_system.md   (authored — do not rewrite)
  migrations/        alembic
  tests/             pytest
  docker-compose.yml postgres:16 for local dev
docs/SPEC.md
README.md
```

## Domain rules (shared by app and server)

- Units: metres, seconds internally; km + min/km in UI.
- Standard distances: `5k`=5000, `10k`=10000, `half`=21097.5, `marathon`=42195.
- **Effort**: for every standard distance a run reaches (distance_m >= D), the effort time is the
  moving time elapsed when cumulative distance first crossed D (linear interpolation between
  the two samples straddling D). It is "your 5K in this run", not a fastest-segment search.
- **Primary distance** of a run = largest standard distance it reached, else `null` ("free run").
- Splits: per full km, plus a final partial split if >= 50 m. Each split: `distance_m`, `moving_s`,
  `gain_m`, `loss_m`.
- Elevation: use `CLLocation.altitude` only when `verticalAccuracy` in (0, 10]; smooth with a
  hysteresis of 3 m (only count a climb/descent once the altitude has moved >= 3 m from the last
  anchor). This avoids GPS noise inflating gain.
- GPS filtering: drop samples with `horizontalAccuracy` < 0 or > 25 m, samples older than 10 s,
  and implied speed > 12 m/s. Paused time is excluded from moving time.
- Prediction (Riegel): `T2 = T1 * (D2/D1) ** 1.06`, using the best effort at the nearest other
  distance. Shown as "Predicted from your 5K".
- Required pace for a target = target_s / (D/1000) s/km.

## Server

FastAPI, Postgres. Session auth with opaque bearer tokens (store sha256 hash only).

Tables:
- `users(id uuid pk, apple_sub text unique null, display_name text null, created_at)`
- `sessions(token_hash text pk, user_id fk, created_at)`
- `targets(user_id fk, distance text, target_s int, updated_at, pk(user_id, distance))`
- `runs(id uuid pk [client-generated, idempotent upsert], user_id fk, started_at timestamptz,
  distance_m float, moving_s float, elapsed_s float, gain_m float, loss_m float,
  splits jsonb, efforts jsonb, created_at)`; index (user_id, started_at desc)
- `coach_notes(run_id pk fk, user_id fk, source text ['llm'|'heuristic'], model text null,
  payload jsonb, created_at)`

Endpoints (all JSON, all except auth require `Authorization: Bearer <token>`):
- `POST /auth/apple {identity_token, name?}` -> verify against Apple JWKS
  (`https://appleid.apple.com/auth/keys`, iss `https://appleid.apple.com`, aud = `JOGGA_APPLE_BUNDLE_ID`)
  -> `{token, user}`
- `POST /auth/dev {name}` -> only when `JOGGA_DEV_AUTH=1`, else 404. Used by the simulator.
- `GET /me` -> `{user, targets, stats}` where stats per distance = `{best_s, last_s, count, count_4w}`
- `PUT /targets/{distance} {target_s}` ; `DELETE /targets/{distance}`
- `POST /runs {run}` -> upsert run, build packet, run coach synchronously (LLM timeout 25 s,
  on any failure/timeout/invalid JSON fall back to heuristic), store note -> `{run, coach}`
- `GET /runs?limit=50` ; `GET /runs/{id}` -> `{run, coach}`
- `POST /runs/import {source: "strava", runs: [run + external_id]}` (≤200 per batch) -> store
  imported history, never coached; idempotent per `(user, source, external_id)`; runs within 3 min
  and 5% distance of a recorded Jogga run are skipped. Returns `{imported, ids, skipped}`.
- `DELETE /runs?source=strava` -> remove that user's imported runs.
- `POST /coach/replan` -> re-coach the latest run once if imports landed since its note (else the
  existing note); null with no runs. Bounds import cost to one LLM call.
- `GET /coach/latest` -> latest coach note or null
- `GET /health`

Config (env): `DATABASE_URL`, `JOGGA_APPLE_BUNDLE_ID` (default `co.aliveindustries.jogga`),
`JOGGA_DEV_AUTH`, `OPENROUTER_API_KEY` (optional), `JOGGA_LLM_MODEL` (default `deepseek/deepseek-v4.1-flash`),
`JOGGA_LLM_MAX_TOKENS` (default 12000), `JOGGA_LLM_REASONING` ("" | on | off; invalid -> ignored with
a startup warning), `JOGGA_LLM_TIMEOUT_S` (default 30), `JOGGA_LLM_TEMPERATURE` (default 0.2).

The coach calls OpenRouter with structured outputs: `response_format =
{"type":"json_schema","json_schema": <prompts/coach_schema.json>}` (strict) plus
`provider.require_parameters=true` so routing only hits endpoints that support it.
The response is validated as `LLMCoachOutput` (observation, result,
next{kind,km,pace "m:ss",detail,why}, frequency) and normalised to `CoachOutput`:
`feedback` = observation + result, `next.pace` parsed to int seconds (120–1200,
else fallback), `km` in (0, 50], `runs_per_week` clamped to 1–7.
The pacing label is decided by the server, not the model: `fitness.run_shape`
classifies the splits on hill-adjusted pace (faded > 4 % slower second half,
sped_up > 4 % faster, uneven spread > 8 %, else steady) into `run.shape`,
which the prompt asks the model to describe, and which maps back to the app's
Pacing values (faded->positive, sped_up->negative, steady->even, uneven->erratic).

### Coach packet (sent to the LLM — keep it exactly this shape)

Built server-side from the DB. Short keys, no whitespace (`json.dumps(separators=(",",":"))`),
km rounded to 2 dp, metres to ints. All times and paces are pre-formatted strings
(`m:ss` under an hour, `h:mm:ss` above; signed deltas as `+m:ss`/`-m:ss`) — the LLM
never converts seconds itself. Typical size well under 1k tokens.

```json
{
  "v": 4,
  "u": {"km": "km", "t": "m:ss|h:mm:ss", "pace": "m:ss/km", "elev": "m"},
  "today": "2026-09-30",
  "hist": {"runs": 12, "first": "2026-07-12", "rest_d": 2},
  "goals": [
    {"d": "5k", "target": "25:00", "tpace": "5:00", "pb": "27:00", "pb_d": "2026-08-12", "last": "27:35", "n": 8, "n4w": 3}
  ],
  "fit": {
    "src": ["2026-09-24", "5k", 5.0, "27:00"],
    "pred": {"5k": "27:00", "10k": "56:12", "half": "2:04:00"},
    "zones": {"easy": ["6:29", "7:01"], "steady": "6:03", "tempo": "5:40", "intervals": "5:14"}
  },
  "load4w": {"runs": 9, "km": 48.2},
  "long4w": 12.4,
  "wk": {
    "cols": ["wk", "runs", "km"],
    "rows": [["2026-08-10", 1, 5.0], ["2026-08-17", 0, 0.0], ["2026-08-24", 1, 8.2],
             ["2026-08-31", 2, 11.4], ["2026-09-07", 2, 13.0], ["2026-09-14", 0, 0.0],
             ["2026-09-21", 1, 10.0], ["2026-09-28", 2, 10.6]]
  },
  "streak": 2,
  "day": {"runs": 1, "km": 5.04},
  "recent": {
    "cols": ["date", "d", "km", "t", "pace", "gain"],
    "rows": [["2026-09-28", "5k", 5.02, "27:35", "5:30", 42]]
  },
  "prev": {"plan": ["easy", 4.0, "6:20"], "did": [5.04, "5:25"]},
  "run": {
    "date": "2026-09-30", "d": "5k", "km": 5.04, "t": "27:20", "el": "28:00", "pace": "5:25",
    "gain": 38, "loss": 35,
    "shape": "steady",
    "eff": {"cols": ["d", "t", "vs_target", "vs_pb"], "rows": [["5k", "27:00", "+2:00", "-0:35"]]},
    "splits": {"cols": ["km", "t", "pace", "flat", "gain", "loss"],
               "rows": [[1, "5:18", "5:18", "5:12", 2, 5], [1, "5:31", "5:31", "5:20", 12, 1],
                        [0.04, "0:12", "5:00", "4:55", 0, 0]]}
  }
}
```
- `hist`: `runs` = logged runs before this one; `first` = date of the earliest; `rest_d` = days
  since the previous run (nulls when there are no earlier runs).
- `goals`: one entry per distance that has a target OR any effort; `target`/`tpace`/`pb`/`last`
  may be null. `tpace` = pace required by `target`.
- `fit`: current fitness from the best effort among the last 10 runs plus any in the last 21 days,
  never older than 42 days (this run included), null if
  no candidate. `src` = the winning effort `[date, d, km, t]` (`d` null for a whole run >= 3 km);
  `pred` = Riegel predictions for 5k/10k/half; `zones` = training paces.
- `recent`: the last 10 runs before this one, newest first. `d` = primary distance or null.
- `prev`: the previous coach note's prescription vs what this run did, null when there is no
  usable earlier note.
- `splits`: `pace` = split moving pace; `flat` = flat-equivalent pace from climb/descent
  (`1 + 3.3*gain/d - 1.8*loss/d`, clamped to [0.85, 1.5]). Zero-length splits get "0:00".
- `run.el` = elapsed time (well above `t` means stops). `run.eff`: fastest time at each
  standard distance covered, vs target and previous best as signed deltas
  (negative `vs_pb` = new best). `run.shape` = server-computed label for the run's
  pacing shape (faded | sped_up | steady | uneven).
- `day`: the user's runs on the same UTC date as this run, this one included.
- `wk`: the last 8 ISO weeks (Monday start), oldest first, ending with this run's week;
  zero weeks are included. Runs counted up to and including this run.
- `streak`: consecutive weeks ending at this run's week with >= 1 run.
- `long4w`: longest run (km) in the 28 days up to and including this run.

### Coach output (validated with pydantic; invalid -> heuristic)

```json
{
  "feedback": "string, <= 2 sentences",
  "pacing": "even | positive | negative | erratic",
  "next": {"km": 5.0, "pace": 320, "kind": "easy | steady | tempo | intervals | long | race",
           "detail": "string, one short sentence, may describe reps e.g. 6x400m",
           "why": "string, one sentence"},
  "frequency": {"runs_per_week": 3, "note": "string, one sentence"}
}
```

### Heuristic coach (no API key, or LLM failure) — deterministic, `source: "heuristic"`

- pacing: split paces of full kms; cv = stdev/mean. If cv > 0.08 -> `erratic`; else compare mean
  of first half vs second half: second slower by > 2% -> `positive`, faster by > 2% -> `negative`,
  else `even`.
- goal = the target distance with the largest relative gap (current - target)/target, current =
  the `fit` prediction at that distance, else pb (or the only one).
  No targets -> suggest 5 km easy at current avg pace + 30 s/km.
- next run alternates by last run kind: if the previous coach note's `next.kind` was `easy` ->
  `tempo` (km = min(goal km, 5) * 0.8 rounded to 0.5, pace = target pace + 5); else `easy`
  (km = goal km * 0.8 rounded to 0.5, pace = target pace + 60). Never suggest pace faster than
  target pace - 10.
- frequency: gap <= 3% -> 3/wk, <= 8% -> 4/wk, else 4/wk plus note to add one easy run;
  note references n4w ("You've run 5K twice in 4 weeks; aim for 3 runs a week.").
- feedback: one sentence from pacing + one comparing run effort to pb (if beaten) or the best
  effort at that distance in the `fit` runs.

## iOS app

iOS 17+, SwiftUI, Swift 5 language mode, no third-party deps. `@Observable` stores injected via
`.environment`. Bundle id `co.aliveindustries.jogga`. Background mode `location`.
`NSLocationWhenInUseUsageDescription`: "Jogga uses your location to map and measure your runs."

Modules (files, roughly):
- `RunMath.swift` — pure, fully unit-tested: GPS filter, distance accumulation, splits, elevation
  hysteresis, efforts, primary distance, Riegel, required pace, formatters (`26:40`, `1:52:07`,
  `5:19 /km`, `5.02 km`).
- `RunRecorder.swift` — CLLocationManager (`activityType = .fitness`, best accuracy,
  `distanceFilter = 3`, `allowsBackgroundLocationUpdates = true`,
  `pausesLocationUpdatesAutomatically = false`, `showsBackgroundLocationIndicator = true`).
  States: idle / countdown / running / paused / finished. Publishes elapsed, distance, current pace
  (rolling last 30 s), gain, route coordinates, completed splits. Km-split haptic.
- `RunStore.swift` — local JSON persistence (Application Support), pending-upload queue retried on
  launch + foreground.
- `APIClient.swift` — async/await URLSession, bearer token in Keychain. Base URL from Info.plist
  `JOGGA_API_URL` (default `http://localhost:8000`), overridable in DEBUG settings.
- `AuthStore.swift` — Sign in with Apple (`SignInWithAppleButton`) -> `/auth/apple`. In DEBUG a
  small "Continue without Apple" text button -> `/auth/dev`.
- Seed data: DEBUG-only launch arg `-seedDemo` fills ~12 plausible runs over 6 weeks (5K and 10K)
  so every screen can be screenshotted in the simulator.

### Screens

1. **Sign in** — full-bleed, near-empty. App wordmark "jogga" (SF Rounded, heavy, large, accent),
   one line underneath "Run the distance. Beat the time.", Sign in with Apple button pinned bottom
   (black in light, white in dark). Nothing else.
2. **Set target** (sheet, shown automatically when user has no targets; also reachable from
   Progress) — segmented distance picker, wheel time picker (h m s), live "That's 5:00 /km" line
   in large rounded numerals, current best shown if any. One accent "Set target" button.
3. **Run (home tab)** — large title date-ish header ("Wednesday"), then:
   - "Next run" coach card: huge "5 km" + "at 5:20 /km", a small kind capsule ("Tempo"),
     one-line why. Empty state: "Go for a run and I'll plan the next one."
   - Goal rows: per target — distance, target, best, a thin capsule progress bar (best vs
     target, accent), "12 runs".
   - A large circular accent Start button (~96 pt, `figure.run` glyph) pinned near the bottom
     with a soft shadow. Tap -> 3-2-1 countdown -> Active run.
4. **Active run** (full-screen cover) — full-bleed SwiftUI `Map` (`.standard(pointsOfInterest:
   .excludingAll)`, `UserAnnotation`, `MapPolyline` in accent, 6 pt, round caps). Bottom panel on
   `.ultraThinMaterial`, continuous corner radius 32: elapsed time huge (rounded, ~72 pt,
   monospaced digits, `.contentTransition(.numericText())`), beneath a 3-up row: Distance / Pace /
   Elevation with small uppercase labels. Controls: Pause/Resume circle, and a "Hold to finish"
   circle with a ring that fills over 1 s (prevents accidental stops). Paused state dims the map
   and shows "Paused". Countdown = fullscreen accent with giant numerals + haptic per tick.
5. **Run summary** (after finish, also from History) — route map card (non-interactive), headline
   stats grid (distance, time, avg pace, elevation gain), effort badges ("5K · 26:40 · Best"),
   splits list: km, pace, horizontal bar showing pace relative to run average (faster = longer,
   accent), and ↑/↓ elevation for that km in secondary colour. Coach card: feedback, pacing tag,
   next run. Shows a gentle loading state while the coach responds; if offline: "Coach will reply
   once you're back online."
6. **Progress tab** — segmented distance picker; hero best time (huge), target + gap ("1:40 to
   go"), Swift Charts line/point chart of efforts over time with dashed `RuleMark` at target,
   stats row (runs, last 4 weeks, last time), "Predicted from your 10K: 24:58" (Riegel),
   frequency advice from latest coach note. Button "Edit target".
7. **History tab** — plain grouped list by month; row: day+date, distance, time, pace. Tap ->
   summary. Swipe to delete (local + server delete is out of scope -> local only, note it).
8. **Settings** (gear in Run tab toolbar) — name, sign out, DEBUG server URL. Nothing else.

### Visual language — "Apple minimalism, but beautiful"

- One accent colour only: brand blue `#0E71FE` (dark mode `#3D8BFF`), matching the logo, in the asset catalog as
  `AccentColor`. Everything else is system greys/labels. No gradients except the countdown and the
  app icon.
- Numbers are the hero: `.system(size:, weight: .semibold, design: .rounded).monospacedDigit()`.
  Labels are small: `.caption.weight(.semibold)`, uppercase, `.secondary`, slight tracking.
- Surfaces: `systemGroupedBackground` page, cards `secondarySystemGroupedBackground`,
  `RoundedRectangle(cornerRadius: 24, style: .continuous)`, 20 pt padding, 16 pt spacing. No
  borders, no heavy shadows (only the Start button).
- Motion: springs (`.snappy`/`.smooth`), numeric text transitions, `.sensoryFeedback` for start,
  pause, km split, finish, target set. Respect Reduce Motion.
- Full Dark Mode support; Dynamic Type on all text except the giant live numerals (use
  `minimumScaleFactor`). Accessibility labels on all icon buttons and stats.
- SF Symbols only. App icon: accent background, simple white rounded glyph.
