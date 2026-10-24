# Jogga planner: evidence review and proposed rule changes

Scope: the weekly plan rules in `server/jogga/planner.py`, the pace zones in `fitness.py`, and the planner and coach prompts.

For each rule, the review gives the evidence behind it, how strong that evidence is, and a recommendation.
- **Strong:** randomised trials or consistent cohort studies.
- **Moderate:** cohort studies, but with mixed results.
- **Convention:** coaching practice with little direct trial evidence.

## 1. How much the week may grow (current rule: +10%, now with a floor of "average + one usual run")

**Evidence**
- **Buist et al. 2008** (*Am J Sports Med*, GRONORUN RCT, 532 novice runners): a graded programme that kept increases near 10% a week had no fewer running injuries than a faster standard programme. *Strong (one RCT, novices only).*
- **Nielsen et al. 2014** (*JOSPT*, cohort of 873 novices): runners who increased weekly distance by more than about 30% had more overuse injuries of certain kinds (for example patellofemoral pain and IT band problems) than those who increased it by under 10%. Increases between 10% and 30% were not clearly riskier. *Moderate.*
- **Damsted et al. 2018** (*IJSPT*, systematic review): limited and conflicting evidence linking changes in training load to running injuries. No single safe percentage has been shown. *Moderate.*
- **Acute:chronic workload ratio** (Gabbett 2016, *BJSM*): its "sweet spot" of 0.8 to 1.3 is widely used. However, **Impellizzeri et al. 2020** (*IJSPP*) showed that the ratio has statistical problems, including mathematical coupling and spurious correlation, and it should not be used as a hard injury threshold. *Use it to describe load, not as a rule.*

**Conclusion:** a flat 10% cap is not evidence-based, and it is too tight for low-mileage runners, where 10% of 8 km is less than 1 km. The best-supported guidance is to avoid big jumps (more than about 30% a week) and to progress gradually from a stable base.

**Proposed rule:** the week's ceiling is the 4-week average × a growth factor, with a floor of "average + one usual run".

| Situation | Growth factor |
|---|---|
| Recent check-ins easy or comfortable, no pain | up to 1.25 (novice) or 1.30 (experienced) |
| Mostly "hard" or no check-ins | 1.10 |
| Any "max", or pain in the last 7 days | 1.00 (hold) |
| "Sore" or "stopped" | 0.70 to 0.80 (reduce) |

## 2. Your example: "a comfortable 10 km at 5:30, so is 15 km the week's target?"

This is partly right, with some nuance.

- One comfortable 10 km shows your aerobic fitness can handle 10 km. Your heart and lungs adapt within weeks. Bone, tendon and cartilage adapt over months, and repeated volume is what loads them. This is why injury studies look at *weekly* change rather than single runs (Nielsen 2014).
- A long run of about 30 to 50% of the week is typical for runners doing 3 runs a week (*convention*). A 10 km long run therefore suits a week of about 20 to 30 km in the long term, but you don't get there in one jump from an 8 km average.

**Proposed handling:**
1. A comfortable long run raises the *target* for the coming weeks to about 1.5 to 2 × that run. For you that's about 15 to 20 km a week.
2. The weekly ceiling still grows by the factor in section 1, so you reach the target over 2 to 4 weeks. From 8 km a week that's roughly 10 → 12.5 → 15 km, sooner if check-ins stay comfortable.
3. The plan text says this plainly, for example "Building toward 15 km weeks. This week 12 km."

## 3. How hard the week is (current rule: at most 1 hard session for beginners, 2 for everyone else, never on back-to-back days)

**Evidence**
- **Seiler and Kjerland 2006** (*Scand J Med Sci Sports*) and **Stöggl and Sperlich 2014** (*Front Physiol*, RCT): endurance athletes do about 80% of their training at low intensity, and a polarised approach does as well as or better than threshold-heavy training. *Strong for trained athletes, moderate for recreational runners.*
- Hard/easy alternation, with about 48 hours between hard sessions, is long-standing coaching practice (Bowerman, Daniels). *Convention, physiologically sound.*

**Recommendation:** keep the current rule. Add a check that hard sessions make up at most about 20% of the week's planned *time* (not just a count), so one long tempo run can't take over a short week.

## 4. Using "how it felt" (not used for load at the moment)

**Evidence**
- **Session RPE (Foster et al. 2001, *J Strength Cond Res*):** load = duration × perceived effort (0 to 10). It is validated against heart-rate methods and is the standard way to measure training load without a heart-rate monitor. *Strong.*
- **The talk test (Persinger, Foster et al. 2004, *MSSE*):** being able to talk comfortably matches being below the first ventilatory threshold, which is easy running. *Strong.*

**Proposal:** map the check-in answers to RPE values and store a session load (minutes × RPE).

| Answer | RPE | Meaning |
|---|---|---|
| Easy ("could chat the whole way") | 3 | talk test passed |
| Comfortable | 5 | |
| Hard ("short sentences only") | 7 | |
| Flat out | 9 | |

Session load feeds the growth factor in section 1. An easy run that felt "hard" also slows the next easy paces (already built) and holds the next week's growth at 1.10.

## 5. Pace zones (current: Riegel prediction from the best recent effort, zones as multiples of predicted 5K pace)

**Evidence**
- **Riegel 1981** (*American Scientist*): T2 = T1 × (D2 / D1)^1.06. It works well for 5 km to half marathon for trained runners. It tends to be **too optimistic** for the marathon and for novices, whose endurance lags their speed. *Moderate.*
- **Daniels' VDOT tables** (*Daniels' Running Formula*): easy pace is about 59 to 74% of VO2max, which in practice is roughly 5K pace + 60 to 120 s/km. Threshold is about the pace you could race for an hour. *Convention backed by lab data, the coaching standard.*

**Recommendation:**
- Check our `ZONE_*` multipliers against Daniels' tables for 5K times of 20:00 to 35:00. Move the easy zone so its slow end is at least 5K pace + 90 s/km for slower runners.
- Lower the confidence in Riegel predictions when the source effort is older than 6 weeks or comes from a novice (already partly handled by the recency rule).

## 6. Shortest worthwhile run (just added: 3 km, or 60% of the usual run)

Health guidance counts a "bout" as anything from about 10 minutes (ACSM, WHO 2020 removed the minimum). For training adaptation, coaches rarely prescribe easy runs under 20 to 30 minutes (*convention*). **Proposal:** set the minimum by **duration**, at least 20 minutes at easy pace, with a floor of 3 km. For you at about 6:15/km that's about 3.2 km, close to today's rule but scaled to pace.

## 7. Pain (just added: any pain rules out hard sessions, "sore" ×0.75 longest run, "stopped" ×0.5)

**Evidence**
- **Pain-monitoring model (Silbernagel et al. 2007**, *Am J Sports Med*, Achilles tendinopathy RCT): continuing to train with pain up to about 5/10, which settles by the next morning, did as well as rest. *Strong for tendinopathy, sensible elsewhere.*
- Pain that changes how you run, or makes you stop, is the usual "rest and get assessed" signal. *Convention.*

**Proposal:** map the answers onto that model and add "see a physio" when pain is reported on 2 or more runs in 14 days.

| Answer | Treated as | Plan response |
|---|---|---|
| Niggle | about 2 to 3/10 | keep running, easy only, recheck at the next check-in |
| Sore | about 4 to 5/10 | volume × 0.7 and no hard runs until a pain-free check-in |
| Had to stop | more than 5/10 | 2 or more rest days, then at most 2 short easy runs, and a physio prompt if it comes back |

The app never diagnoses.

## 8. Changes to the prompts
- **Planner:** explain the growth factor, the "building toward X km weeks" target, the 80/20 time check and the pain model in plain words. Give the LLM `cap.target_km` as well as `cap.week_km`, so it can tell the runner where the build is heading.
- **Coach:** no change. It reviews the run and doesn't plan.

## What I'd build (about half a day)
1. Store the RPE mapping and a session load for each check-in. Compute the week's growth factor from check-ins and pain.
2. Set the weekly ceiling from the growth factor and the long-run-based target. Set the minimum run by duration.
3. Add the 20% hard-time check. Check the zone multipliers against Daniels.
4. Update the prompts. Add tests for every rule above, including your 10 km example.
5. Replay the planner over your history to show week-by-week targets before and after.

## Caveats
Most running-injury evidence comes from novices and observational cohorts. No rule here prevents injury on its own, and individual tolerance varies a lot. Check-ins and pain reports give Jogga individual feedback, which matters more than any population average.
