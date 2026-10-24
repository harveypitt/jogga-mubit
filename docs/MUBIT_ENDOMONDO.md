# Training a Mubit coach adapter on Endomondo history

This explains how we produced training data for a small Mubit adapter of the
Jogga coach, and how we judged the result. All code lives in `server/jogga/replay/`.

## What Mubit does and what we do

Mubit is a proxy in front of OpenRouter. Every coach call that goes through
`https://api.mubit.ai/compat/openrouter/v1/chat/completions` is answered by the
provider model (the "teacher") and recorded. Calls that share the model, system
prompt and output schema form one Mubit task. Once a task has enough kept
examples, Mubit fine-tunes a small open model (Qwen3-4B) to copy the teacher's
answers and scores it on held-out cases in its console.

The fine-tuning itself runs inside Mubit, and there is no public training API.
So the code in this repo covers the parts we control:

1. turning a public running dataset into realistic coach calls,
2. sending them through Mubit in the order a real runner would have logged them,
3. keeping held-out runners out of Mubit's training data, and
4. grading every answer against Jogga's coaching rules and the runner's real next run.

## Data

[FitRec / Endomondo](https://cseweb.ucsd.edu/~jmcauley/datasets/fitrec.html)
(`endomondoHR_proper.json`, 4.9 GB) holds 253k workouts with per-point GPS,
altitude, heart rate and timestamps. It is for academic use only and may not be
redistributed, so it is never committed. Download it yourself.

Each workout is resampled to 500 points, so samples are about 7–13 s apart.
The Endomondo replay therefore treats gaps of up to 30 s as moving time
(`ENDO_PAUSE_GAP_S`), instead of the 10 s pause the iOS app uses for 1 Hz GPS.
Everything else (accuracy filters, splits, elevation hysteresis, best efforts)
uses the same maths as the iOS importer (`jogga/replay/strava.py`).

## Pipeline

```sh
cd server
# 1. Byte-offset index of every running workout (70,591 runs, 807 runners)
python -m jogga.replay.endomondo --data endomondoHR_proper.json --index index.jsonl --build-index
# 2. Deterministic runner selection (seed 20261023)
python -m jogga.replay.endomondo --data endomondoHR_proper.json --index index.jsonl --out selection.json
# 3. Chronological replay through Mubit
JOGGA_LLM_MODEL=openai/gpt-6.1-sol JOGGA_LLM_TEMPERATURE=off \
JOGGA_LLM_TIMEOUT_S=90 JOGGA_LLM_TOTAL_TIMEOUT_S=200 JOGGA_LLM_ATTEMPTS=3 \
MUBIT_API_KEY=... \
python -m jogga.replay --endomondo selection.json --data endomondoHR_proper.json \
  --coach mubit --holdout-coach mubit-norecord --out replay_out/endo-sol
# Re-score saved notes without new calls
python -m jogga.replay --regrade --out replay_out/endo-sol
```

**Selection** (`_build_selection`): from runners with at least 40 indexed runs,
sample 30 with `random.Random(20261023)`. Parse every run and drop any under
1 km or outside 2:30–15:00 /km moving pace. Keep each runner's latest 40 valid
runs, and skip runners left with fewer than 30. Stop at 20 runners. The first 4
selected become the **holdout** split, the other 16 the **train** split. The
split is by whole runner, so the adapter is tested on people it never saw.

**Replay** (`jogga/replay/__main__.py`): each runner gets an empty throwaway
Postgres database. Their runs are inserted oldest first, through the same code
path as an app upload (`mode="free"`). After each insert, the coach is called
exactly as in production, so the packet only holds history from before that run.
Runners run concurrently (`--concurrency`), but each runner's own runs stay
strictly sequential.

**Keeping holdout out of training:** train runners use `--coach mubit`
(recorded). Holdout runners use `mubit-norecord`, which sends
`x-middleware-record: off`, so Mubit keeps neither the request nor the answer.

## Grading

`jogga/replay/grade.py` checks every note against the rules in
`prompts/coach_system.md`. It never checks whether the runner followed the
advice, because the runs happened before the notes existed.

| Check | Rule |
|---|---|
| `llm_used` | a real model answer, not the built-in fallback |
| `pace_in_zone` | next-run pace within 10 s/km of the runner's zone for that session type |
| `distance_cap` | next-run distance ≤ 1.25 × the 4-week long run + 0.1 km |
| `no_hard_after_hard` | no quality session the day after a hard effort |
| `easy_after_double` | easy run after a two-run day |
| `length_limits` | the word limits set for each field |
| `tone_rules` | no banned phrases, exclamation marks or em dashes |

**Forecast:** every note also predicts the distance and pace of the runner's
next logged run. `_forecast_scores` compares that with the run that actually
came next, and with two model-free baselines: repeat the last run, and the
median of the last 5 runs.

## Results

### Choosing the teacher

The adapter can only be as good as the model it copies. So before the full
replay we ran a bake-off: each candidate coached the 4 holdout runners'
first 10 runs (40 notes per model, recording off).

| Model | Rules (pace, cap, no hard after hard) | Length limits | Forecast error, distance / pace | Cost per note | Median latency |
|---|---|---|---|---|---|
| DeepSeek V4.1 Flash | all pass | 35/40 | 2.83 km / 42 s | $0.008 | 9 s |
| GPT-6.1 Sol | all pass | 35/35 | 2.28 km / 42 s | $0.010 | 17 s |
| Claude Sonnet 5.5 | all pass | 10/40 | 2.68 km / 43 s | $0.028 | 13 s |
| Claude Haiku 5.5 | 1 miss | 13/40 | 2.77 km / 46 s | $0.002 | 13 s |
| GPT-6 Luna | all pass | 40/40 | 2.42 km / 44 s | $0.001 | 19 s |
| Median of last 5 runs | | | 1.98 km / 39 s | | |

Sol ran out of OpenRouter credit on 5 notes, so it has 35. Anthropic and OpenAI
models reject `temperature`, so these runs set `JOGGA_LLM_TEMPERATURE=off`.
We picked GPT-6.1 Sol as the teacher: it costs about the same as DeepSeek and
was the only model that kept every rule and limit.

### Full replay (GPT-6.1 Sol teacher, 20 runners, 798 notes)

| Check | Train (16 runners) | Holdout (4 runners) |
|---|---|---|
| `llm_used` | 637/638 | 160/160 |
| `pace_in_zone` | 637/638 | 160/160 |
| `distance_cap` | 638/638 | 160/160 |
| `no_hard_after_hard` | 127/127 | 35/35 |
| `easy_after_double` | 6/6 | 6/6 |
| `length_limits` | 637/637 | 160/160 |
| `tone_rules` | 637/637 | 160/160 |

The one failure was a 1:57 /km pace that the app's own validator rejected, so
that note fell back to the built-in coach. Cost was $7.81 ($6.32 for the 638
recorded training calls) and the median call took 17 s.

**Forecast**, mean absolute error against the next real run:

| Split | Transitions | Coach | Repeat last run | Median of last 5 |
|---|---|---|---|---|
| Train | 621 | 3.83 km / 32.4 s | 4.94 km / 41.1 s | 3.89 km / 32.7 s |
| Holdout | 156 | 2.68 km / 30.6 s | 3.20 km / 37.1 s | 2.71 km / 32.1 s |

We ran a paired bootstrap (10,000 resamples of transitions, seed 7) on
median-of-5 error minus coach error. On holdout the gap is 0.04 km
(95% interval −0.13 to 0.21) and 1.5 s/km (−0.6 to 3.5); on train it is
0.06 km (−0.09 to 0.20) and 0.3 s/km (−1.1 to 1.7). Every interval includes
zero. The coach easily beats "repeat your last run" but only ties the median of
the last 5. Next-run distance mostly reflects what a runner decides to do that
day, which the history can't predict. We don't claim forecasting skill.

### What Mubit did with it

Mubit grouped the Sol calls into a new task ("Jogga's running coach 3", 641
calls, all `openai/gpt-6.1-sol`). It kept 34 of them as examples, since Mubit
chooses which recorded calls to keep, and started training adapter v1 on
Qwen3-4B. We'll add v1's test results here once Mubit has scored it.

### Earlier attempt: one runner, DeepSeek teacher

Before Endomondo we replayed one runner's own Strava history (66 runs) with
DeepSeek as the teacher. Mubit trained two Qwen3-4B adapters from it. Neither
was ready: the plain coach adapter matched 41.7% of DeepSeek's answers and
broke the length limits on 7 of 11 test cases. The coach-with-forecast adapter
produced valid JSON on only 2 of 12. About 50 examples from one person is too
little, which is why we moved to 20 runners and 638 training calls.

## What this does and doesn't show

- The replay checks the teacher, and it holds up: on 160 notes for runners
  Mubit never recorded, it passed every rule.
- Mubit scores the adapter by how closely it matches the teacher, not by
  coaching quality. Judge an adapter by running its answers through
  `jogga/replay/grade.py` as well.
- Personalisation comes from each runner's packet (history, zones, efforts),
  not from per-user weights. One runner logs far too few runs to train their own
  adapter.
