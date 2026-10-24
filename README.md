# Jogga

A calm, ad-free running app. It cares about exactly one thing: how fast you run
the standard distances (5K, 10K, Half, Marathon), how that is trending against
your target, and what to do on your next run. No segments, no leaderboards, no
social feed.

Sign in with Apple → set a target → record a GPS run → summary with splits →
upload → server builds a compact packet → an LLM (or a deterministic heuristic
fallback) returns feedback plus a next-run suggestion.

## Layout

```
ios/      SwiftUI app (XcodeGen project.yml, generated Jogga.xcodeproj committed)
server/   Python 3.12, FastAPI, SQLAlchemy 2 (async), Alembic, Postgres
docs/     SPEC.md — the authoritative v0 spec
          MUBIT_ENDOMONDO.md — Mubit adapter training data and evaluation
```

## Server

Requires Python 3.12 and Postgres 16.

```sh
# Postgres — either Homebrew…
brew install postgresql@16 && brew services start postgresql@16
createdb jogga && createdb jogga_test
# …or Docker
docker compose -f server/docker-compose.yml up -d

cd server
python3.12 -m venv .venv && source .venv/bin/activate
pip install -e '.[dev]'

export DATABASE_URL=postgresql+asyncpg://localhost:5432/jogga
alembic upgrade head

JOGGA_DEV_AUTH=1 uvicorn jogga.main:app --port 8000
```

- `JOGGA_DEV_AUTH=1` enables `POST /auth/dev` for the simulator. Without it the
  endpoint returns 404.
- `OPENROUTER_API_KEY` (optional) enables the LLM coach via OpenRouter; without
  it every run gets the deterministic heuristic coach. `JOGGA_LLM_MODEL`
  defaults to `deepseek/deepseek-v4.1-flash`. The coach requests OpenRouter
  structured outputs (`response_format` json_schema from
  `prompts/coach_schema.json`, strict, plus `provider.require_parameters`),
  so the model replies with validated fields: observation, result,
  a next run whose pace is a "m:ss" string, and a weekly frequency. The
  pacing label is computed server-side from hill-adjusted split paces and
  passed to the model as `run.shape` — the LLM describes it, it doesn't
  choose it. Any failure or out-of-range value falls back to the heuristic.
  Tunables: `JOGGA_LLM_MAX_TOKENS` (default 20000), `JOGGA_LLM_REASONING`
  ("" | on | off; anything else is ignored with a startup warning),
  `JOGGA_LLM_TIMEOUT_S` (default 40), `JOGGA_LLM_TOTAL_TIMEOUT_S` (default 50),
  `JOGGA_LLM_ATTEMPTS` (default 2), and `JOGGA_LLM_TEMPERATURE` (default 0.2;
  set to `off` to omit the temperature parameter).
- `MUBIT_API_KEY` (optional) routes coach requests through Mubit instead of
  OpenRouter directly; configure the OpenRouter key in the Mubit console.
- `JOGGA_MUBIT_URL` (optional) overrides Mubit’s OpenAI-compatible completion
  URL, which defaults to `https://api.mubit.ai/compat/openrouter/v1/chat/completions`.
- `POSTHOG_PROJECT_TOKEN` (optional) enables PostHog error tracking and AI
  observability of coach generations (prompt packet + response; the packet
  contains no GPS, heart-rate or HealthKit data); `POSTHOG_HOST` defaults to
  `https://eu.i.posthog.com`.
- `JOGGA_APPLE_BUNDLE_ID` (default `co.aliveindustries.jogga`) is the audience
  used when verifying Sign in with Apple identity tokens against Apple's JWKS.

Checks: `ruff check . && ruff format --check . && mypy jogga && pytest`
(tests run against `jogga_test`).

## App

```sh
cd ios && xcodegen
open Jogga.xcodeproj
```

Run on the simulator, tap "Continue without Apple" (DEBUG only) to sign in via
`/auth/dev` against the local server. The API URL defaults to
`http://localhost:8000` (`JOGGA_API_URL` in Info.plist, overridable in DEBUG
settings).

For a phone: set `JOGGA_API_URL` to your Mac's LAN IP or deployed URL and
`DEVELOPMENT_TEAM` (already `32NQ6XTXFN`) in `ios/project.yml`.

DEBUG launch arguments:

- `-seedDemo` seeds ~12 runs over 6 weeks (and queues them for upload) so every
  screen is populated.
- `-demoRun` skips sign-in and starts the active-run screen fed by a synthetic
  location stream, for screenshots without GPS.

Test: `xcodebuild -project ios/Jogga.xcodeproj -scheme Jogga \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test`

### On-device coach voice (Neuphonic)

The "Emily" coach voice runs a NeuTTS-2E backbone (llama.cpp) plus a NeuCodec
ONNX decoder entirely on-device. Before building with it:

```sh
export HF_TOKEN=…   # needs access to neuphonic/neutts-2e and neucodec-onnx-decoder-int8
ios/scripts/fetch_voice_models.sh
```

The script is idempotent and fetches `ios/Vendor/llama.xcframework` (pinned to
llama.cpp b11000) plus the model files into `ios/Jogga/VoiceModels/` — both
gitignored. Without it the app builds normally and uses the system voice. The
xcframework ships no simulator slice upstream; `ios/Vendor/llama.xcframework`
includes a locally-built `ios-arm64-simulator` slice so tests can run.

## Architecture

- **App** — `RunMath` (pure, unit-tested: GPS filter, splits, elevation
  hysteresis, efforts, Riegel), `RunRecorder` (CLLocationManager, background
  updates, km-split haptic), `RunStore` (local JSON + pending-upload queue),
  `APIClient` (bearer in Keychain, base URL from Info.plist), `AuthStore`
  (Sign in with Apple, DEBUG dev sign-in).
- **Server** — opaque bearer sessions (sha256-hashed tokens), idempotent run
  upsert keyed on the client-generated UUID, packet builder, coach (LLM via the
  OpenRouter client with heuristic fallback). The LLM system prompt is
  `server/jogga/prompts/coach_system.md`, loaded verbatim at runtime.

### Coach packet example

```json
{"v":4,"u":{"km":"km","t":"m:ss|h:mm:ss","pace":"m:ss/km","elev":"m"},
 "today":"2026-09-30","hist":{"runs":12,"first":"2026-07-12","rest_d":2},
 "goals":[{"d":"5k","target":"25:00","tpace":"5:00","pb":"27:00","last":"27:35","n":8,"n4w":3}],
 "fit":{"src":["2026-09-24","5k",5.0,"27:00"],
   "pred":{"5k":"27:00","10k":"56:12","half":"2:04:00"},
   "zones":{"easy":["6:29","7:01"],"steady":"6:03","tempo":"5:40","intervals":"5:14"}},
 "load4w":{"runs":9,"km":48.2},"long4w":12.4,"streak":2,"day":{"runs":1,"km":5.04},
 "recent":{"cols":["date","d","km","t","pace","gain"],
   "rows":[["2026-09-28","5k",5.02,"27:35","5:30",42]]},
 "prev":{"plan":["easy",4.0,"6:20"],"did":[5.04,"5:25"]},
 "run":{"date":"2026-09-30","d":"5k","km":5.04,"t":"27:20","el":"28:00","pace":"5:25",
   "gain":38,"loss":35,
   "eff":{"cols":["d","t","vs_target","vs_pb"],"rows":[["5k","27:00","+2:00","-0:35"]]},
   "splits":{"cols":["km","t","pace","flat","gain","loss"],
   "rows":[[1,"5:18","5:18","5:12",2,5],[1,"5:31","5:31","5:20",12,1],[0.04,"0:12","5:00","4:55",0,0]]}}}
```

Every coach note also stores telemetry (token counts, cost, latency,
generation id, fallback `error`, and the exact `packet` sent). Inspect recent
notes with:

```sh
cd server && python -m jogga.report [--limit 20]
```

## Deploy

The server deploys to Fly.io (app `jogga-api`, region `lhr`) via `server/fly.toml`:

```sh
cd server
fly deploy                                  # builds the Dockerfile remotely
fly secrets set OPENROUTER_API_KEY=sk-or-…  # LLM coach key
```

`DATABASE_URL` comes from the attached Fly Postgres app `jogga-db`
(`fly postgres attach jogga-db`; switch to `fly mpg` for managed backups) and is
normalised for asyncpg/psycopg2 automatically (`jogga.config.db_url`).
Migrations run on each release via the `release_command`. `JOGGA_DEV_AUTH`
must not be set in production.

Release builds of the app point at `https://jogga-api.fly.dev` automatically
(`configs: Release` override in `ios/project.yml`); Debug stays on
`http://localhost:8000`. For a phone on local dev, set `JOGGA_API_URL` to your
Mac's LAN IP and `DEVELOPMENT_TEAM` to your Team ID.

## Not yet

Per SPEC out-of-scope, plus v0 simplifications:

- Onboarding flow; the target sheet appears automatically instead. Onboarding
  should ask about prior running (runs per week, typical distance and pace) so
  the coach has a baseline before the first run.
- HealthKit write / heart rate.
- Apple Watch app.
- Live Activity / lock-screen widget.
- Miles (km only).
- Audio cues.
- Route sync to server — routes stay on device.
- Server-side run deletion — History swipe-delete is local only.
- Social features and monetisation.
- Refresh tokens / session expiry — sessions are long-lived opaque tokens.
- Device-to-device sync beyond run upload (targets live on the server; run
  history screens read the local store).
