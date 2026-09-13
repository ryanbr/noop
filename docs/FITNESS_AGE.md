# Fitness Age

**Status:** shipped. A weekly number you can read at a glance.

## What it is

Fitness Age is a **fitness comparison**, not a biological or clinical age. It answers one question:
*"How does my cardiorespiratory fitness compare to the typical person, expressed in years?"* If your
Fitness Age is below your real age, your estimated fitness is better than average for someone your age;
if it's above, it's worse. That's the whole claim — it is **not** a measure of how old your body, cells,
or organs are, and it carries no medical meaning.

It is computed **on-device**, weekly, from data NOOP already has. Nothing is sent anywhere.

## Where the number comes from

The estimate is built on the **Nes 2011 non-exercise VO₂max model** from the HUNT3 fitness study — the
same family of equations behind the "Fitness Age" feature popularised by NTNU/CERG. We use the
**waist-circumference variant** (confirmed coefficients):

```
Men:    VO₂max = 100.27 − 0.296·age + 0.226·PA − 0.369·waist(cm) − 0.155·RHR     SEE 5.70
Women:  VO₂max =  74.74 − 0.247·age + 0.198·PA − 0.259·waist(cm) − 0.114·RHR     SEE 5.14
```

- **RHR** is resting heart rate (a rolling 7-day median from the strap).
- **PA** is a physical-activity index (see below).
- **waist** is waist circumference in cm, from the profile if the user enters it.
- **SEE** is the model's standard error of estimate — roughly ±5.7 (men) / ±5.1 (women) ml/kg/min on the
  VO₂max itself. This is large. The number is a useful trend, not a lab measurement.

These coefficients were reproduced independently in **JAHA / Ball State 2020 (PMC7428991)** and are
corroborated by the **CERG/NTNU** group that authored the original work.

### The PA-index (no questionnaire required)

The Nes model takes a **physical-activity index** that, in HUNT, came from the **HUNT1 PA-Q**
questionnaire (Kurtze 2008) — a short self-report of weekly exercise frequency, duration and intensity
mapped onto a 0–7.5 scale. NOOP doesn't ask the user to fill that in. Instead it **reconstructs the
PA-index on-device** from the measured training signal it already records (workout frequency, duration
and strain/intensity over the rolling window), mapping it onto the same scale the questionnaire produced.
This keeps the input honest — it's derived from what you actually did, not what you'd claim on a survey.

### The Fitness Age itself needs no body measurement

The headline Fitness Age is computed by a **self-consistent inversion** of the same Nes equation. We
solve for the age at which a *population-reference* person — fixed at **RHR = 65** and **PA-index = 5** —
would have your estimated VO₂max. Because both the forward estimate and the inversion use the same
fixed reference body term, the **body/waist term cancels out** of the comparison. The result: the
headline Fitness Age is driven by your **resting HR and reconstructed activity** alone, and is shown
**without requiring any weight, height or waist entry**.

Weight, height and waist circumference are only ever used to **unlock the explicit VO₂max estimate**
(the ml/kg/min figure). They never sharpen, gate, or change the Fitness Age number — the readiness UI
groups them under *"Unlocks your VO₂max"*, never under the age itself.

## Cadence and gating

- **Weekly, on Saturday.** The engine recomputes once a week and stamps the value on that week's
  Saturday, so the number updates on a steady, predictable rhythm rather than jumping day to day.
- **Rolling 7-day medians.** RHR and the activity signal are taken as 7-day medians, so one bad night or
  one rest day doesn't swing the result.
- **≥4-of-7-nights coverage gate.** A week needs resting-HR data from at least 4 of its 7 nights before a
  number is produced. Below that, the engine reports *not ready* / *estimate only* rather than guessing.
- **±5-year presentation band.** The number is shown inside a **±5-year band** (`bandYears = 5.0`), not as
  a false-precision point value — honest about the model's error.

The weekly results are stored in `metricSeries` under two keys, written to the computed `-noop` source:

| Key            | Unit       | Meaning                                              |
|----------------|------------|-----------------------------------------------------|
| `fitness_age`  | years      | the headline number (drives the UI)                 |
| `vo2max_est`   | ml/kg/min  | the explicit VO₂max estimate (only when waist given) |

The UI reads the **latest** `fitness_age` value.

## Honesty disclaimer

- This is a **fitness comparison expressed in years**, not a biological age, a clinical assessment, or a
  diagnosis. It says nothing about disease, longevity, or how old your body "really" is.
- The underlying VO₂max model has a **large mean absolute error** (SEE ≈ 5 ml/kg/min). Treat the number
  as a **direction of travel over weeks**, not a precise readout — which is exactly why it's shown in a
  ±5-year band and only updates weekly.
- It is a **non-exercise estimate**. A real graded exercise test on a treadmill or bike is the gold
  standard; this is a convenient proxy, nothing more.

## References

- **Nes BM, et al.** *Estimating V̇O₂peak from a nonexercise prediction model: the HUNT Study, Norway.*
  Med Sci Sports Exerc. 2011;43(11):2024–2030. — the source model and coefficients.
- **Kurtze N, et al.** (2008) — validation of the **HUNT1 physical-activity questionnaire (PA-Q)** that
  defines the PA-index.
- **JAHA / Ball State 2020, PMC7428991** — independent reproduction of the Nes non-exercise VO₂max model.
- **CERG / NTNU** — the group behind the original "Fitness Age" work, corroborating the approach.
