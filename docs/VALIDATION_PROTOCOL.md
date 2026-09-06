# Validation protocol

How NOOP is allowed to claim that a scoring change is an improvement.

This document is prescriptive. It exists because the project has repeatedly published accuracy
numbers that did not survive a second measurement. In one review, six separate findings reversed
when a fresh reader re-measured them instead of inheriting them: a contamination count, three
agreement statistics, the sign of a bias, and the direction of a stage error. One reversed finding
rested on a mechanism that could not physically occur, because a single transaction writes both of
the streams it claimed had diverged.

None of those were arithmetic mistakes. They were process failures, and the same six process
failures produce them again unless the process changes. Each rule below names the failure it
prevents.

---

## The rules

### R1 — Pre-register the prediction before measuring

Before running the harness, write down: the **prediction**, the **threshold**, the **direction**,
the **evaluation domain**, the **exclusion list**, the **stratum**, and the **n** you expect. Put it
in the PR description or a dated file, and do not edit it afterwards — append outcomes elsewhere.

**The evaluation domain is the part people forget, and it is the part that moves the number most.**
Scoring sleep/wake against the strap's band over one wearer's ~18-day window gives kappa 0.795 when
every band epoch is scored, and kappa 0.095 on the same nights, same reference, same predictor, when
only epochs *inside the detected sleep sessions* are scored. That is a 0.70 swing from a choice that
is easy to leave unstated — larger than most of the effects anyone is trying to measure.

Restricting evaluation to the predictor's own positive windows conditions on the thing being tested
and discards the true negatives, so it cannot be compared against a full-coverage figure. Both are
legitimate; they answer different questions ("how good is the wake detection inside a night I already
found" versus "how good is sleep/wake overall"). State which one, every time. Note that SleepBench's
section C is the **in-session** domain, so its kappa is not comparable to a whole-record kappa.

A prediction chosen after seeing the output is not a test of anything. This is the failure behind
"better on 6 of 7 nights": the exclusion list, the stratum, and the metric were all selected once
the data was visible, and the analysis moved with the hypothesis.

Specifically forbidden: introducing a subgroup ("the healthy nights", "excluding the travel week")
after the pooled result disappoints. If a stratum matters, name it before you look.

### R2 — Never score against a reference the scorer produced

NOOP pre-populates a hypnogram with machine stages and the wearer edits it. A lightly-edited night
is therefore mostly scorer output. Scoring the scorer against it is self-comparison, and it inflates
agreement toward 1.0.

`Tools/SleepBench` already detects this. Its `E.-1 SELF-COMPARISON AUDIT` replays the current stager
against each stage-locked reference night and reports any night matching at >= 99.9% (byte-exact) or
>= 95% (near-exact), then prints a ready-to-paste `--exclude <startTs>,<startTs>,...` line.

- Run the audit **every time**, on the DB you are actually about to use.
- Use the exclusion list **it prints**. Never a list copied from a previous run, a doc, or a commit
  message — the set changes whenever the stager changes, which is exactly when you are measuring.
- If fewer than 5 reference nights survive exclusion, the correct output is
  **"cannot be measured on this reference set"**, not a number with a caveat.

`userEdited = 1` does not mean a human authored the stages; it is also set when the wearer only
adjusted the bed/wake bounds, which re-derives machine stages. The stage-lock cursor is the gate,
and only `E.-1` applies it correctly.

### R3 — Re-derive; never cite

Every number that enters a decision ships with the **command that regenerates it** and the **date and
input it was run against**. If it cannot be regenerated, it is not evidence and may not be quoted.

The tree has already paid this liability down once, and the payoff is the model to copy: the
benchmark justifying the shipped sleep-staging default existed only as a numeric claim inside a
source comment until `Tools/SleepPSG` (#991) landed the harness that regenerates it — replaying the
shipped `SleepStagerV2` over PhysioNet `sleep-accel` and scoring it epoch-for-epoch against
human-scored PSG hypnograms. A stage-accuracy claim now has a regenerating command
(`swift run sleeppsg --dataset …`), which is exactly the shape R3 requires of every number: not
"this was measured once", but "this is how anyone re-measures it". A number with no runnable
provenance is a rumour with a decimal point.

Corollaries:
- Numbers in code comments are documentation, not evidence.
- Numbers in a previous PR description are not evidence either. Re-run them.
- Do not copy a statistic between documents. Copy the command.

### R4 — Match the instrument to the question

Most reversals came from asking one statistic a question it does not answer.

| Question | Instrument | Not this |
|---|---|---|
| Did behaviour change at all? | replay old vs new on identical input; epoch agreement | agreement vs a reference |
| Is a stage fraction right? | per-stage fraction and **signed bias in percentage points** | Cohen's kappa |
| Is sleep/wake timing right? | onset and final-wake error in **minutes**; the strap's own band | 4-class kappa |
| Is it better than chance? | kappa, **printed next to the class marginals** | raw % agreement |
| Is a day's data complete? | coverage (samples observed / samples expected) and the device fault log | any statistical outlier test |
| Is a value plausible? | cross-source corroboration against an **empirically re-derived** band | a remembered "should be N-M times" rule |

The last two rows are not stylistic preferences; they were measured. On one wearer's 19-day window,
a coverage test (1 Hz samples banked / 86400) separated a genuinely truncated day from 18 complete
ones with **zero false positives** — complete days sat at 99.5-100% and the truncated day at 36%.
On the same days, statistical outlier tests on the scored value flagged 23-32% of all days, and the
better-specified of the two still missed the truncated day entirely. Completeness is a property of
the input; asking the output about it is asking the wrong instrument.

Equally, a remembered cross-source ratio is not an invariant. A "wrist ticks should be 2-6x phone
steps" rule, re-derived on 30 qualifying days, held on 57% of them, and every violation was on the
low side — the upper bound never bound at all. Used as an alarm it would fire on 43% of normal days
while failing to isolate the day it was remembered for. Re-derive the band from the data, publish the
percentile it covers, and re-derive it again when the hardware or the wearer changes.

Kappa is a chance-corrected agreement statistic. It is not a fraction estimator, and it moves with
the class marginals, so a change in how much of the night is called wake will move kappa without
telling you which stage moved or in which direction. "Deep is under-called" and "deep is over-called"
are indistinguishable in kappa and unambiguous in a signed per-stage bias. Report the bias.

Raw percentage agreement is worse still: on a mostly-asleep night, a predictor that says "asleep"
for every epoch scores very high. Any raw-agreement figure must be published next to the score of
that constant predictor on the same epochs, or not published.

### R5 — Hold out a temporal split

A wearable's data is a time series and its failure modes are temporal — firmware changes, a new
strap, a season, a supplement protocol. Random splits leak; temporal splits do not.

Calibrate on an **early** window, report the headline number on a **later** window that was untouched
during development. Report both, and report the gap. A large in-sample gain with a small held-out gain
is an overfit, and must be described as one.

Where a parameter is fitted, report the value fitted on each half. A parameter that moves a lot
between halves is not a constant of physiology.

This is not hypothetical for wearables. A one-parameter heart-rate threshold detector, fitted on the
early half of a single wearer's 18-day window and tested on the later half, lost 5.7 pp of balanced
accuracy — and the threshold that was optimal on the late half differed from the early one by more
than 10 bpm, inside three weeks, on one person. Carrying the early parameter forward cost 8.9 pp
against what the later window would have chosen for itself. Resting heart rate drifts with training,
illness, travel, and supplementation, and the class balance drifts with it: sleep was 24% of scored
epochs in the early half and 37% in the late half. Any threshold tuned once and never re-checked is
decaying silently, and only a temporal split makes that visible.

### R6 — Check the base rate, and check the mechanism is possible

Before a mechanism is believed:

1. **Could it happen at all?** Read the code path. The claim that two streams diverged was
   architecturally impossible because one transaction writes both. Thirty seconds of reading would
   have retired it.
2. **How often does the signal occur anyway?** A fault event that coincides with a bad day means
   something if it is rare and nothing if it is daily. Count it over the whole era before
   attributing anything to it.
3. **What else explains it?** A physiological story that fits the data is not evidence until the
   ordinary explanations — load, sleep debt, travel, a known supplement protocol, incomplete capture
   — have been measured and excluded.

### R7 — Definitions travel with the number

Every reported figure carries: **n**, the **instrument**, the **units or scale**, and whether it was
**measured now or inherited**. A metric that exists on two scales must never be reported as a bare
number.

This is not pedantry, and the vocabulary is not currently clean. A state-enum mapping circulated in
inverted form and was used to interpret real nights. A term meaning "shares a definition with" was
read as "was copied from". Both cost a full re-measurement. The stored hypnogram vocabulary presently
contains **both `wake` and `awake`** as distinct stage strings across the same wearer's nights, so any
consumer written as `stage == "wake"` silently misfiles the other spelling as sleep. Normalise at the
boundary, assert the closed set in a test, and never let a stage string be compared by literal in more
than one place.

Mark every claim CONFIRMED (measured by the author, this run) or INFERRED (reasoned, not measured).
Never blend them in one sentence.

### R8 — A negative result is a result

"This cannot be measured on the available data" is a complete, publishable answer and is preferred to
a number with an apology attached.

Some quantities have no reference in this project at all. Where no ground truth exists for a stage,
claims about that stage are unfalsifiable, and the protocol requires saying so rather than
substituting a different consumer device's opinion and calling it truth. Two devices agreeing are two
estimates, not a measurement.

---

## PR checklist

Paste into any PR that changes scoring, and fill it in:

```
Validation
- [ ] R1 Pre-registered prediction, threshold, exclusion list, stratum (link/quote, written before measuring)
- [ ] R2 E.-1 self-comparison audit run on THIS db; exclusion list taken from its output; N nights survived
- [ ] R3 Every number below has its regenerating command and run date
- [ ] R4 Instrument matches question; stage claims report signed per-stage bias, not only kappa
- [ ] R5 Temporal held-out split; in-sample and held-out both reported, with the gap
- [ ] R6 Base rate of any invoked mechanism counted over the full era; mechanism confirmed reachable in code
- [ ] R7 Every figure carries n, instrument, units, and measured-vs-inherited
- [ ] R8 Anything unmeasurable on this data is stated as unmeasurable

Command(s):
Date run / input:
Prediction (pre-registered):
Outcome (confirmed / falsified):
```

A PR that changes a scoring output and reports no held-out number has not been validated. That is
not a blocker on merging an experiment behind a flag; it is a blocker on describing it as an
improvement, in the changelog, in a release note, or in a source comment.

---

## Where the harness lives

`Tools/SleepBench` is the sleep-scoring accuracy harness. It is a single run that prints all
sections; there are no subcommands.

```bash
cd Tools/SleepBench
swift run sleepbench --db /path/to/a/copy/of/the.sqlite            # all sections, incl. E.-1
swift run sleepbench --db /path/to/copy.sqlite --exclude <ts>,<ts> # after reading E.-1's output
swift test                                                          # metric unit tests, no DB
```

Always pass a **copy** of the database. The harness opens it read-only, but a live app writing
underneath a measurement makes the measurement unreproducible, which violates R3.

Databases and hypnograms are personal health data. They are excluded by `.gitignore` and must never
be committed, quoted at row level in a PR, or pasted into an issue.
