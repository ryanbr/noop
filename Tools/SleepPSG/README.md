# SleepPSG — scoring `SleepStagerV2` against polysomnography

`Tools/SleepBench` replays NOOP's sleep stagers against the references a wearer's own database happens to
carry: their manual restages, the strap's band `sleep_state`, Apple Health. Every one of those is either the
recipe's own output handed back to it, or another vendor's black box. None of them is truth, and the sleep
work has repeatedly had to say so in its own commit messages.

This tool supplies the missing reference. It replays the **shipped** `SleepStagerV2` over PhysioNet
`sleep-accel` — wrist accelerometer and heart rate recorded alongside **human-scored PSG hypnograms** — and
scores it epoch-for-epoch against those hypnograms.

Everything here is read-only. The dataset is never committed, never modified, and is always a command-line
argument. No NOOP database is opened and no wearer's health data is involved at any point.

---

## Get the dataset

~577 MB compressed. Put it anywhere **outside** this repository.

```bash
mkdir -p ~/datasets && cd ~/datasets
curl -L -o sleep-accel.zip \
  https://physionet.org/static/published-projects/sleep-accel/motion-and-heart-rate-from-a-wrist-worn-wearable-and-labeled-sleep-from-polysomnography-1.0.0.zip
unzip -q sleep-accel.zip
```

The archive expands to a long-named directory containing `labels/`, `heart_rate/`, `motion/` and `steps/`.
Pass either that directory or its parent — `--dataset` finds the level with `labels/` in it.

## DREAMT — the second dataset, with beat-to-beat intervals

`sleep-accel` has no R-R, so the recipe's RSA respiration term is silent on it. DREAMT (PhysioNet, v2.2.0:
100 adults, an Empatica E4 on the wrist beside PSG, human-scored 30 s stages) has the E4's inter-beat
intervals, so on it every input of the recipe runs. It is **restricted-access**: each user signs the
PhysioNet Restricted Health Data Use Agreement 1.5.0 and downloads it themselves. It is never committed,
and this tool prints only cohort aggregates and per-stratum counts from it. Only `data_64Hz/` (~14 GB) and
`participant_info.csv` are read:

```bash
swift run -c release sleeppsg --dataset ~/datasets/dreamt            # every section, plus section 8
swift run -c release sleeppsg --dataset ~/datasets/dreamt --section rsa
```

It is a **sleep-clinic cohort** (median AHI 13.5 events/hour; 26 subjects under 5): more wake and far less
N3 than a healthy night (truth: wake 25 %, deep 3.4 % of the night). #348 fitted priors to it and #437
reverted that within 48 h, because the cohort's base rates had become a prior applied to everyone. So the
DREAMT report stratifies by AHI and by how many beats the E4 kept, and it is used here for one question the
priors do not touch: what the RSA term does when it is live.

## Run it

```bash
cd Tools/SleepPSG
swift run -c release sleeppsg --dataset ~/datasets/motion-and-heart-rate-*-1.0.0
```

| flag | meaning |
|---|---|
| `--dataset PATH` | the extracted `sleep-accel` root, or the DREAMT folder holding `data_64Hz/`. Required for every section except `port`. |
| `--section S` | `all` (default), or one of `port`, `baseline`, `strata`, `rem`, `variants`, `priors`, `rsa` (DREAMT only). |
| `--subjects N` | score only the first N subject ids — a fast smoke run. |
| `--csv PATH` | write the per-variant table as CSV. |
| `--seed N` | the port-validation corpus seed. |

`--section port` needs no dataset at all: it is the equivalence check described below, and it is also what
`swift test` runs.

---

## Attribution — required by both licences

**Dataset.** Walch O, Huang Y, Forger D, Goldstein C. *Sleep stage prediction with raw acceleration and
photoplethysmography heart rate data derived from a consumer wearable device.* **SLEEP** 42(12), zsz180
(2019). Distributed on PhysioNet as `sleep-accel` v1.0.0 under the **Open Data Commons Attribution License
v1.0**, which permits use and redistribution and *requires* attribution.

**Companion code.** `ojwalch/sleep_classifiers`, **MIT**. Not vendored here; cited because it is the
reference implementation of the dataset's own baselines, and because anyone reproducing this work will want
it. The comparison models in section 5 of the report are written from scratch in this tool and are not
derived from that code.

**PhysioNet.** Goldberger AL et al. *PhysioBank, PhysioToolkit, and PhysioNet.* Circulation 101(23):e215
(2000).

---

## What the report contains

### 1. Port validation — why you can trust the variant rows

Every **baseline** number comes from `StrandAnalytics.SleepStagerV2.stageSession` directly: the file that
ships in the app, compiled from `Packages/`, with no reimplementation in between.

The **variant** rows cannot work that way. `SleepStagerV2` holds its constants as `static let`s and keeps
`Epoch`/`features()` internal to `StrandAnalytics`, so asking "what would this recipe score with one
transition row changed?" means either rebuilding the app for each question or restating the recipe with its
knobs exposed. This tool does the second, in `RecipePort.swift`.

That is the classic way a benchmark quietly starts measuring something else — someone edits the shipped
file, nobody edits the port. So equivalence is not reviewed, it is **measured, on every build**:

- 48 randomised nights (varying length, off-grid window starts, channel dropout, arousals, motion bursts,
  unsorted input, R-R present on most so the RSA term is exercised — the PhysioNet data cannot exercise it)
- plus 7 degenerate cases: all-HR-missing, zero-variance HR, 1-epoch, 2-epoch, saturated motion gate,
  no-coverage-at-all, and motion-absent
- both paths stage every night; **every epoch label must agree**

`swift test` runs this, so CI runs it, with no dataset present. When `RecipeConfig.shipped` and
`SleepStagerV2.swift` diverge, the test fails and names the night and epoch. **A failure here is never
flakiness.** It means the two have drifted and the fix is to update `RecipeConfig.shipped`.

### 2–3. Dataset summary, and the shipped recipe against PSG

Four-class agreement (wake / light / deep / REM, with N1+N2 → light and N3 → deep), per-stage
precision/recall/F1, and **stage fractions as a first-class result**.

Stage fractions are not an appendix here, for a specific reason: **kappa does not constrain them.** PR #348
improved kappa on all three of its benchmarks and was reverted 48 hours later for re-scoring a healthy night
from 6 % to 23 % awake — *"kappa doesn't guard stage-fraction calibration."* A harness that reported only
kappa could not have seen that regression, and this one is built so it cannot repeat the mistake.

**Two conventions, both printed, and a percentage here is meaningless without naming which.** Every stage
fraction in this tool divides by **all scored epochs of the night, wake included** — that part never varies.
What varies is how the 31 subjects are combined:

| convention | what it is | deep, shipped recipe |
|---|---|---|
| **pooled over all scored epochs** | one denominator of 26 773 epochs for the whole cohort; a long night carries more weight than a short one | predicted **15.09 %**, truth **13.76 %**, bias **+1.32 pp** |
| **mean of per-subject percentages** | each subject's own % of their own night, then averaged over 31 subjects; every subject counts once | predicted **15.16 %**, truth **14.76 %**, bias **+0.40 pp** |

Those are the recipe with the deep prior at 0.15 (section 7). With the deep prior at its former 0.18 (the
`deep prior 0.18 (before)` row) they were 18.94 % / 19.24 %, bias +5.18 / +4.48 pp.

Section 3 prints both tables, one above the other, each labelled. They are the same epochs and the same
denominator *within* a night; the ~1 pp gap between them is the weighting across subjects, nothing else.
The pooled convention is what a cohort-level "% of night" means and is the one section 6's variant table
and every bias column use. The per-subject mean is what a clinician comparing individuals would use, and it
is the one the self-check below is stated in, because it is the convention the previous harness reported.
**Quote either, never both interchangeably, and always say which.**

`SleepStagerV2` fits nothing to data — every coefficient is fixed a priori — so there is no train/test split
to make for the recipe itself. The leave-one-subject-out machinery exists for the fitted comparison models
in section 5, which do need it.

### 4. Stratified by night length

Pooling hides couplings. `SleepStagerV2` has been observed to emit more REM as a fraction of sleep the
longer the night runs (corr +0.579 on one wearer's nights), traced to the REM-latency guard being a fixed
60-minute penalty — a third of a short night, a tenth of a long one. Subjects are split into terciles by
scored night length, and the correlation is reported for the prediction **and for PSG truth**: a coupling
truth also carries is physiology, one only the prediction carries is an artefact.

### 5. Is REM detection physiology, or is it the clock?

REM rises through the night in every population, so a model given nothing but "how far into the night is it"
already scores respectably. If NOOP's REM output were mostly that, the honest description of the feature
would change.

Three models — clock features alone, physiology features alone, both — fit **leave-one-SUBJECT-out**.

**Never an epoch-level split.** Consecutive 30 s epochs from one night are about as independent as
consecutive frames of a film; a random epoch split puts a subject's 02:14 epoch in train and their 02:14:30
epoch in test, and every model then scores near-perfectly by memorising the subject. Each fold holds out one
whole subject. The decision threshold is chosen on the *training* folds and applied unchanged to the
held-out subject — REM is a ~20 % minority class, so a fixed 0.5 would under-predict it unequally across
three models with different calibration, and tuning on the test fold would be the leak the design exists to
avoid.

### 6. Recipe variants

Each row is the shipped recipe with **one** named change: PR #987's awake-transition row, and each of PR
#348's seven components measured alone, plus all seven together. Reported with kappa **and** the stage-
fraction biases, because a component is an improvement only if it wins the first without wrecking the
second. **Every percentage and every `bias pp` in this table is pooled over all 26 773 scored epochs** —
so the incumbent's deep bias reads +1.32 pp here, not the +0.40 pp the per-subject mean gives.

`deep prior 0.18 (before)` is the deep prior as it stood before section 7's evidence moved it to 0.15.

The last row is not a candidate. `pre-#930 REM guard (provenance)` runs the REM-latency guard as it stood
before PR #930 — a hard `c < 0.12 ? 3.0 : 0.0` step in the session-fraction domain — and exists to explain
the self-check below.

### 7. Base priors, subject by subject

The variant table pools 26 773 epochs, so a few long nights can carry a row. `--section priors` scores each
of the 31 subjects once: their own kappa, and how far each stage's share of their night is from their own
PSG, and counts the subjects a variant improves. This is the evidence the deep prior moved on:

| deep prior | mean per-subject κ | subjects with κ higher at 0.15 | mean \|deep bias\| | subjects with \|deep bias\| lower at 0.15 | wake, REM |
|---|---|---|---|---|---|
| 0.18 (before) | 0.351 | — | 8.86 pp | — | — |
| **0.15** | **0.357** | 21 / 31 | **7.99 pp** | 19 / 31 | unchanged, epoch for epoch |

Pooled, deep goes from 18.94 % to 15.09 % of the night against 13.76 % true, light from 50.47 % to 54.33 %
against 55.19 %, kappa 0.363 → 0.371; deep F1 0.498 → 0.484 (precision 0.430 → 0.463, recall 0.592 → 0.507).
0.15 is #348's value, not a fit to this cohort. #348's awake half (0.10 → 0.34) is not taken: it brings the
pooled wake share to truth (4.15 % → 9.39 % against 9.07 %) but worsens the mean per-subject wake error
(5.50 → 5.55 pp) by over-calling wake for the subjects it does not fix, which is the #437 failure. The R-R
stream is empty here, so the RSA term is silent in all of this; on a WHOOP night it is live.

### 8. The RSA term (DREAMT only)

The recipe turns the R-R series into a breathing-regularity score per epoch (the spectral peakedness of the
0.15–0.40 Hz band), z-scores it over the night, and adds `respWeight · z` to the deep emission and
subtracts it from REM — regular breathing → deep, irregular → REM — leaving light alone. Section 8 runs the
shipped `SleepStagerV2.stageSession` with the R-R stream and without it, then asks two separate questions.

**Is the feature informative?** Yes, and in the direction the term assumes. Grouped by the PSG stage of the
epoch, the mean z is +0.29 in deep, +0.06 in light, −0.09 in wake and −0.25 in REM; the AUC for "a deep
epoch scores higher than a REM epoch" is 0.658, light against REM 0.597, and per subject NREM against REM
has a median AUC of 0.559, above 0.5 for 50 of 71 subjects.

**Is it weighted right?** It was not at 0.6, and `respWeight` is now 0.3 on this evidence. Light epochs sit
near z = 0 with the same spread as every other stage, so a symmetric ±0.6·z moved light epochs into deep on
one side and into REM on the other. At 0.6, with R-R live against withheld: pooled κ 0.217 → 0.208,
per-subject κ lower for 55 subjects and higher for 38, REM 16.2 → 19.9 % of the night (truth 10.5 %), deep
10.7 → 12.8 % (truth 3.4 %). Per subject, against the recipe at 0.6 (section 8 now prints the same rows
against the shipped 0.3):

| RSA term | mean κ | κ better / worse than 0.6 | mean \|deep bias\| | mean \|REM bias\| | REM % of sleep (truth 14.0) |
|---|---|---|---|---|---|
| symmetric 0.6 (before) | 0.204 | — | 10.60 | 11.16 | 21.4 |
| symmetric 0.45 | 0.207 | 58 / 30 | 10.27 | 10.47 | 20.0 |
| **symmetric 0.3 (shipped)** | **0.216** | **61 / 28** | **9.76** | **9.74** | **18.4** |
| symmetric 0.2 | 0.217 | 58 / 35 | 9.51 | 9.57 | 17.6 |
| off | 0.216 | 55 / 38 | 9.18 | 9.77 | 17.4 |
| regular breathing only (max(z, 0)), 0.6 | 0.190 | 38 / 54 | 13.23 | 7.78 | 14.2 |
| REM side only, 0.6 | 0.218 | 59 / 30 | 9.16 | 11.13 | 21.3 |

The same ordering holds with AHI under 5 (n = 26: 0.3 better for 16, worse for 7) and where the E4 kept at
least 80 % of the beats (n = 41: 31 / 10). The measured separation says the same thing independently: for
two equal-variance classes a unit of z is worth d′ log-odds, and d′ = √2·Φ⁻¹(AUC) is 0.58 for deep against
REM (the term's slope there is 2 × respWeight) and 0.35 for light against REM (slope respWeight), i.e. a
weight of about 0.29–0.35, not 0.6. "Regular breathing only" fixes the REM share but floods deep; "REM side
only" keeps the REM over-call. sleep-accel has no R-R, so every other section is unchanged by the weight.

---

## The self-check, and what it found

This tool replaces one that was deleted. Section 3 prints its measured values beside the figures that
harness reported on this same dataset, so anyone can see at a glance whether the rebuild is the same
instrument. **Nothing here is tuned to those numbers**, and where they disagree the disagreement is
reported rather than closed.

**Every percentage in this section is the mean of per-subject percentages**, because that is the convention
the previous harness reported in; the pooled figures for the same quantities are ~1 pp away and are printed
directly above it in section 3. The tool labels both tables, and the self-check block repeats the
convention in its own header so a figure copied out of it carries its denominator with it.

Every **truth-side** figure reproduces exactly: 31 subjects, **26 773** PSG-scored epochs, deep **14.76 %**
of each subject's own night averaged over the 31 (pooled: 13.76 %), truth median first-REM latency
**88.5 min**. Predicted deep, with the deep prior at the 0.18 that harness measured (the `deep prior 0.18
(before)` row), lands at **19.24 %** on the same convention against a reported 19.25 % (pooled: 18.94 %), and
four-class kappa at **0.356** against a reported 0.349.

The prediction side of REM does not match: more REM (**26.96 %** per-subject mean, against a reported
20.8 %), REM F1 0.569 vs 0.515, and a first REM period arriving much earlier (median 91.5 min vs 142.0).

**The obvious explanation was tested and is wrong.** PR #930 replaced a fraction-domain `c < 0.12 ? 3.0 : 0`
step with a graded penalty measured in minutes from sleep onset, and the old figures were reported while
#930 was the candidate — so the incumbent they describe is the recipe *before* it. That predicts exactly
this pattern. The `pre-#930` variant runs that guard, and it moves nothing: kappa 0.356 → 0.356, REM F1
0.569 → 0.569, REM 27.02 % → 26.97 % (pooled — section 6's table, like every variant row, is pooled).
On 8-hour lab nights the guard barely binds either way. The
hypothesis is falsified, and it is recorded here rather than deleted because the variant is what falsified
it.

What the residual is remains **unresolved**, and the tool is not tuned to close it. Two constraints on any
future explanation, both from the table above:

- It cannot be the session window. `clock` drives the deep prior and the REM ramp alike; predicted deep at
  the 0.18 prior reproduces to 0.01 pp (19.24 % measured against 19.25 % reported, per-subject mean), so
  `clock` is the same quantity in both harnesses.
- It is REM-specific and it is not the latency guard, which the variant just ruled out.

One suggestive coincidence, offered as an observation and not a conclusion: the previously reported "REM
F1 0.515" is exactly this harness's measured REM **precision** (0.515), against a measured F1 of 0.569.

---

## What this benchmark is not entitled to claim

- **The R-R stream is empty.** `sleep-accel` carries no beat-to-beat intervals, so `respRegularity` returns
  nil on every epoch, `zrg` collapses to a constant 0, and the recipe's RSA respiration term contributes
  exactly 0.0 to every emission. Five of the recipe's six inputs are live here; the sixth is silent. Results
  are a lower bound on the same recipe with an R-R stream present.
- **Different hardware.** This is an Apple Watch's ~50 Hz raw accelerometer collapsed to a per-second mean,
  not a WHOOP gravity decode. The absolute scale differs — which is precisely the thing `SleepStagerV2` was
  built not to depend on, since every motion threshold is a multiple of the night's own median per-second
  jerk. A benchmark on foreign hardware is a test of that claim, not a violation of it.
- **Staging only.** The session window handed to the stager is the labelled span. NOOP's own session
  detection is not exercised, and nothing here says anything about it.
- **n = 31 subjects**, in a sleep-lab setting, wearing a device on the wrist alongside PSG leads. That is
  more independent subjects than any other reference NOOP has, and it is still 31 people.
- **DREAMT is not a WHOOP either, and not a healthy cohort.** Its R-R comes from the E4's PPG, which drops
  beats it is unsure of (median 73 % kept over sleep) and quantises intervals to 1/64 s. On one wearer's six
  WHOOP 5.0 nights, rounding the WHOOP R-R to 1/64 s moved the six-night mean deep and REM by under 1 pp of
  sleep (single nights by up to 4 pp), where switching the term off moved each by about 4.5 pp, so the
  quantisation is not what section 8 measures. Its stage fractions are a clinical population's: section 8
  reads them per stratum and per subject, and nothing in the recipe is fitted to DREAMT's base rates.
