# HIIT App Exercise-Science Audit — Synthesis Report

## Bottom line

**Yes — your derived workout logic is fundamentally sound.** The audit checked ~25 distinct design decisions against the primary literature, and none of them required a redesign. Roughly half were **confirmed correct as-is** — including the choices that matter most: the protocols themselves (Norwegian 4x4 timing, 10-20-30 structure, classic work:rest ratios, hill climbs, pyramids), the heart-rate bands, the Tanaka HRmax formula, the work-speed defaults, the deload cadence, and the detraining model. The other half need **adjustment, not replacement**, and the adjustments cluster in five places:

1. **Recovery-interval speeds for advanced users** (the biggest genuine defect — see your question, answered below)
2. **The Norwegian 4x4's intensity targets** (work slightly under-dosed, recovery slightly under-dosed, warm-up too short)
3. **Warm-up and cool-down minimums** (both shorter than every studied protocol)
4. **Two missing guardrails**: nothing caps weekly speed progression, and nothing limits how much HIIT a user can stack in a week
5. **Post-session metrics** — what you measure today is fine, but the canonical "did this session actually work?" metric (time in the target heart-rate zone) is missing, and it's computable from data you already record

Throughout this report, percentages mean % of estimated maximum heart rate (HRmax = 208 − 0.7 × age).

---

## What the audit CONFIRMED correct (keep these — this matters as much as the fixes)

| Design decision | Verdict | Key source |
|---|---|---|
| Norwegian 4x4: 4 × 4:00 work / 3:00 active recovery | **Exact match** to the source study | Helgerud 2007, MSSE |
| 10-20-30: 5 × (30/20/10s), 2:00 between blocks, 2–4 blocks | **Faithful** — even the 2-block floor has direct literature cover | Gunnarsson & Bangsbo 2012; Bangsbo 2024 |
| 10-20-30 excluded from treadmill | **Correct** — belts can't hit a >90% sprint inside a 10s window; fall hazard | same |
| Classic ratios: 30/75 → 60/75 → 60/60 by level | **Matches ACSM guidance** ("recovery equal to or slightly longer than work"); rep caps fine as time-gated ceilings | ACSM H&FJ 2013; Buchheit & Laursen 2013 |
| Pyramid structure (~20–95s steps at 1:1) | **Within established HIIT parameter space** | Buchheit & Laursen 2013 |
| Hill climbs: 45–60s at ≥6%, ~72% belt speed, ~1:1.5 rest | **Inside the studied space** | Barnes 2013; Ferley 2013 |
| 1% incline on work intervals | **Standard evidence-based practice** (slight overshoot at beginner speeds is trivial) | Jones & Doust 1996 |
| Active recovery as the default between long intervals | **Well supported** — clears lactate, keeps time near VO2max high | Buchheit & Laursen 2013; Helgerud 2007 |
| Recovery HR band 60–75% HRmax | **Correct** — contains Helgerud's 70% target. Note: below-band recovery HR is harmless; never auto-raise speed for it | same |
| Work bands 75–88 / 82–92 / 85–95% | **Aligned with ACSM intensity taxonomy** | Garber 2011 |
| Tanaka HRmax (208 − 0.7×age) | **Best available age formula** — beats 220−age | Tanaka 2001, JACC |
| Work speeds 4.5 / 6.0 / 7.5 mph + health modifiers | **Sensibly graded** (7.8 / 9.3–9.8 / ~11.5 METs — all vigorous) | Ainsworth 2011 Compendium; Hreljac 1993 |
| Session lengths 8–60 min, presets | **Consistent with the 10–40 min effective-dose range** | Gibala 2012; Garber 2011 |
| Every ~6th session deload | **Within accepted periodization practice** | Bell 2022; Coleman 2024 |
| Detraining: 14-day grace, then −0.5 level/week | **Tracks measured VO2max-loss timelines**, errs conservative | Coyle 1984; Mujika & Padilla 2000 |
| 1-min HR recovery flag at <12 bpm | **Matches the validated clinical cutoff**, measured the same way (active cool-down) | Cole 1999, NEJM; Shetler 2001 |

Also confirmed: your RPE-based progression gating, the 95%-HRmax veto, and the DNF regression are all well aligned with guidance. The **only progression defect is the missing weekly cap** (below).

---

## Rest-interval speeds (your specific question)

**Beginner (2.8 mph) and intermediate (3.4 mph) walking recoveries are correct — keep them.** Both sit comfortably in the ACSM/AHA moderate-walking range.

**The advanced 4.2 mph flat recovery is the app's clearest defect.** Humans naturally switch from walking to running at about 4.3–4.9 mph (mean ~4.6 mph; Hreljac 1993). 4.2 mph sits at the bottom edge of that "dead zone": an uncomfortably fast walk for many users and an awkwardly slow jog for others — and the +0.05 mph/level ramp marches users straight through the middle of it. Perceived effort while walking rises steeply in this zone, defeating the purpose of a recovery interval.

**The fix is to make gait explicit rather than pick one number:**

- **Beginner:** walk 2.8 mph (range 2.5–3.0). No level scaling.
- **Intermediate:** walk 3.4 mph (HR-driven range 3.0–3.8, hard cap 3.8–4.0). No level scaling.
- **Advanced:** default **jog recovery at 5.0 mph** (range 4.8–5.2, floor 4.8) for Classic 60/60, Pyramid, hill climbs, Norwegian 4x4 — with a **walk toggle at 3.6–3.8 mph** (optionally +1–2% incline) for users who prefer walking.
- **Never prescribe 4.2–4.7 mph flat without a stated gait.** (4.0 mph and below as a walk is fine — the audit explicitly refuted banning it.)
- **Remove the +0.05 mph/level recovery ramp entirely.** Recovery intervals exist to enable quality in the next work bout; the literature prescribes them by physiology (%HRmax / talk test), never as a progressively overloaded stimulus. A 2024 systematic review (24 RCTs) found recovery intensity is not the adaptation driver. Adjust recovery speed ±0.1–0.2 mph from measured recovery-phase HR instead.

**One special case — the advanced 20s-sprint/40s-recover variant:** after near-maximal sprints with only 40s relief, a 4.2+ mph jog actively hurts. Dupont 2004 found active recovery *more than halved* time-to-exhaustion in short-relief sprint work (427s vs 962s) because jogging steals oxygen from the muscles' energy resynthesis. Use a **slow walk at 2.0–2.5 mph** here — the safe treadmill equivalent of passive rest (never have users straddle the belt). The 10-20-30 protocol is unchanged: its 30s easy phase is part of the validated design.

**Warm-up interaction:** if advanced jog-recovery is adopted, do **not** derive warm-up as jog−0.4 (= 4.6 mph, in the dead zone). Keep warm-ups walk-based (3.4–3.8 mph) and build to a 4.8+ mph jog only in the final "building" portion.

---

## The Norwegian 4x4 — right skeleton, slightly under-dosed

The 4×4:00/3:00 structure is exact and the −0.6 mph pacing offset is sensible. Three tune-ups:

1. **Work intensity:** your 85–95% band matches one published formulation, but its floor equals your generic advanced work band — so your marquee VO2max protocol can deliver no more stimulus than an ordinary interval. The source study prescribed 90–95%. Fix: **target 90–95% HRmax evaluated over the final 1–2 min of each rep**, accepting ≥85% during the first ~2 min (HR-lag data show that ramp is unavoidable). Keep the RPE-7 cue.
2. **Recovery intensity:** the source prescribes recovery jogging at ~70% HRmax; your 2.8–3.4 mph walk speeds drop most users well below that, which measurably shrinks time-in-zone in the next rep. Fix: **band 65–75%, speed = max(easy + 0.8 mph, 60% of Norwegian work speed)**; brisk walk at 2–4% incline for beginners who can't jog. Keep 3:00.
3. **Warm-up:** the source used ~10 min; you use 5. Fix: **8 min minimum**, with the building portion finishing near 70% HRmax. At 26–29-min sessions, fund this by allowing 3 reps — don't raise the ≥26-min gate, which would remove the protocol from those users.

---

## Missing guardrails

- **Weekly progression cap:** today a comfortable user can gain +0.6 mph/week (~13% for a beginner) with no ceiling — the riskiest configuration for the most injury-prone tier, since joints and tendons adapt slower than the heart (Nielsen 2014: >30% volume progression over 2 weeks ≈ 1.6× injury risk). The HR veto won't catch an under-challenged user. Fix: **cap net progression at +1 level (+0.2 mph) per rolling 7 days**; beginners spend the first 4–6 weeks progressing reps/duration at held speed (per ACSM: duration before intensity).
- **Weekly HIIT load guard:** nothing stops a user stacking daily HIIT. Landmark trials used ~3×/week with ≥48h between; Flockhart 2021 found ~152 min/week of HIIT caused measurable metabolic harm while ~90 min/week was well tolerated. Fix: when (i) <48h since the last hard session, (ii) ≥3 hard sessions in 7 days, or (iii) >~150 min total HIIT time in 7 days, **suggest a Zone-2/deload session instead — overridable, never a hard block**. (Important correction from the audit: WHO's 150 vigorous min/week is a health *floor*, not a ceiling — never present it as a budget.)

## Warm-ups and cool-downs

- **Warm-up floor → 3:00** even in ≤12-min sessions (shrink the core, not the warm-up); 4:00–5:00 standard. Your 60/40 very-easy/building split is confirmed correct. Before sprint protocols, end the building portion with 2–3 × 10–15s pickups near work speed (Bishop 2003).
- **Cool-down:** the audit confirmed you should *not* lengthen cool-downs "for recovery" (they don't aid it — Van Hooren & Peake 2018). But stopping abruptly after an all-out finish risks blood-pressure drops (ACSM recommends 5–10 min of light activity). Fix: **≥3:00 when the final work interval is hard with no steady block after it; 4:00–5:00 after Norwegian or sprint-heavy sessions**; 1:30–2:30 stays fine when a Zone-2 block precedes cool-down. This also standardizes the window for your HRR measurement.

## Post-session HR metrics — what to add, with thresholds

Your current measurements are fine but incomplete. Recommended objective set:

1. **Time-in-zone (the canonical HIIT dose metric — add this first).** Accumulate seconds with HR ≥ the user's work-band floor (75/82/85% by tier; also track ≥90% for advanced/Norwegian). **Session dose MET when time-in-zone ≥ 60% of prescribed work seconds** (correct 4x4 execution yields ~81%; rep 1 alone runs ~68%, so 60% is a fair floor). Absolute anchors: **Norwegian ≥10 min at 85–95%**; other sessions with ≥10 min prescribed work: **≥7 min in zone**; pro-rate (0.6×) below that. Treat near-misses within ~2 %HRmax points as met (HRmax is estimated).
2. **Per-interval attainment (replaces grading on average work HR, which blends in the ramp and understates dose).** An interval ≥60s is **ACHIEVED if HR enters the band (or above) at any point before it ends**. Session intensity ACHIEVED if **≥75% of gradeable intervals** achieved (3 of 4 in the 4x4) OR aggregate in-band work time ≥65% after excluding the first 60–90s of interval 1. 50–75% = "partially achieved"; <50% = "missed". Never require the *average* to sit in-band.
3. **Short-bout policy (critical to avoid false failures):** HR lags 20–50s at effort onset and peaks *after* a sprint ends, so a 10–30s rep can be maximal while HR never enters the band. **Never grade an individual <60s rep on HR alone.** For short-bout protocols, grade at block level: time above the band floor across the whole block + peak session HR reaching the band + RPE ≥7. Reserve the ≥90% peak check for advanced users only. For bouts ≥60s, ignore the first 30s (60–90s for interval 1).
4. **1-min HRR — confirmed, keep the <12 bpm flag** (validated: Cole 1999, 2–4× mortality signal). Phrase as "worth mentioning to a doctor if persistent," not a diagnosis. Optional display tiers: 12–20 below average, 20–25 average, 25–35 good, >35 excellent.
5. **Between-interval recovery drop — grade only recoveries ≥120s** (measured data show *no HR drop is physiologically normal* in recoveries ≤75s, which covers your classic/pyramid/10-20-30/surge formats). For ≥120s: PASS if HR ≤75% HRmax at any point in the final 30s; PARTIAL if ≤80%; note-but-don't-fail above. Label "consistent with guidelines," not "validated threshold."

## Bike

Cadences (75/90 rpm) are supported; **"% of max resistance" is not** — it has no physiological meaning and varies arbitrarily across bike brands. Keep 55/65/75% only as a first-session guess, then calibrate per bike using signals you already collect (nudge resistance until work HR lands in band and RPE settles near 7; persist per equipment profile). Scale surge cadence by level (~95/100/110 rpm) — fixed 105 rpm is a coordination challenge for novices.

## Smaller confirmed-with-option items

- 10-20-30: optionally default to 3 blocks when time allows (3–4 blocks produced the published gains).
- HRmax: let a cleanly observed, sustained session max above the Tanaka estimate override the formula (filter single-sample optical spikes).
- Optional user-facing recovery cue: "RPE 2–3 / can speak full sentences."
- Duration suggester: the audit endorsed an auto-suggest algorithm built from your existing machinery (bases 15/25/30 min by tier, +5 min per ~3 levels rate-limited to +5/2 weeks, long day every 3rd–4th hard session, deload at 60–70%, reductions after DNF/RPE 9–10/HRR<12) — details in the change list.
- Housekeeping: the Gibala 2012 citation URL in your docs points to a different paper; cite doi 10.1113/jphysiol.2011.224725 directly.
---

## Implementation status (August 2026)

Applied in the app alongside this audit:

- Gait-explicit recovery speeds — advanced jog recovery at 5.0 mph, "Walk during
  recoveries" toggle (≤3.7 mph), the +0.05 mph/level recovery ramp removed, warm-ups
  capped at walking pace, and near-passive 2.2 mph walks after all-out sprints.
- Norwegian 4×4: 90–95% work band, ~70% (65–75%) recovery band with jog-or-brisk-walk
  speeds, 8-minute warm-up, 4-minute cool-down. With the honest warm-up the protocol now
  needs a 30-minute session (3×4) or ~37 minutes (4×4).
- Warm-up floors raised to 3:00/4:00/5:00 (plus 90s of sprint pickups before 10-20-30 and
  cadence surges); cool-downs raised to 3:00 after hard finishes, 4:00 after sprint-heavy
  or 4×4 sessions, keeping 2:30 after a Zone-2 steady finish.
- Weekly progression cap: net +1 level per rolling 7 days, per equipment.
- Weekly load guard: an overridable "make it easy" suggestion after <48h gaps, ≥3
  sessions, or >150 interval minutes in 7 days.
- Post-session objectives from live HR: time-in-zone dose (60%-of-work / 7-min anchors),
  per-interval attainment for ≥60s efforts only, ≥120s recovery-quality checks, and the
  1-minute HRR flag — using the thresholds in this report.
- Bike: sprint cadence now scales 95/100/110 rpm by level; resistance fractions documented
  as first-session guesses calibrated by the user's mid-workout overrides.

Deferred (candidates for future work): HR-driven closed-loop recovery/resistance nudging,
observed-max-HR override of the Tanaka estimate, beginner duration-before-intensity
progression (partially covered by the weekly cap), and the ≥90% advanced dose display.
