# FAQ

Answers to the questions that come up most often in issues. If your question isn't here,
[ANALYTICS.md](ANALYTICS.md) documents how every score is computed and
[PRIVACY_SECURITY.md](PRIVACY_SECURITY.md) covers what stays on your device.

---

## Why is NOOP's resting heart rate lower than the WHOOP app's?

**Because they are different statistics over the same night, and the gap is expected.**

NOOP's resting HR is the **lowest sustained level** during your in-bed window — the minimum of the
night's 5-minute non-overlapping bin means. That rejects single-beat dips while capturing the night's
true floor.

The WHOOP app's figure sits closer to the **whole-night average**, which is naturally a few bpm
higher. Typical reported gaps are 5–8 bpm.

Neither number is wrong. NOOP logs both side by side so you can check it yourself — look for this
line in your strap log:

```
rhr day=2026-07-16 floor=44 nightMean=50 inBedSamples=30247
(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
```

`floor` is what NOOP shows you; `nightMean` is the number closer to what the WHOOP app displays. If
the difference between those two is roughly the difference you're seeing between the apps, there is
nothing wrong with your data.

## Why is my HRV different from the WHOOP app's?

HRV is computed from the R-R (beat-to-beat) intervals your strap banks overnight, and small
differences in which beats are accepted move the number. A large difference — roughly double — is
worth reporting, because it usually means the R-R stream is over-covered.

Your strap log carries the diagnostic:

```
hrv diag day=2026-07-16 rmssd=52ms sdnn=98ms coverage=2.54 collapsedCov=1.99 dupBeats=62
```

`coverage` above 1.0 means more R-R data arrived than wall-clock time allows, which points at
duplicated beats. Include that line if you file an issue — it turns a "my HRV looks wrong" report
into something diagnosable.

## Does my data ever leave my device?

No, unless you export it yourself or explicitly enable an optional network path. NOOP operates no
servers, accounts, telemetry, or cloud sync. The AI Coach sends a compact summary only when you ask
it a question. Android's Experimental self-hosted push can send fresh database rows after offload,
at app-launch catch-up, or when the user explicitly selects **Export now**,
but is off until you configure your own endpoint and bearer token; it is one-way and never reads
records back. A receiver may only advertise which fixed protocol streams it accepts. A source-built
Oura history importer is inbound-only.

These exports can carry your data off-device **when you choose to use them**:

- a `.noopbak` backup, which is a copy of the whole local database
- the CSV/JSON export
- the default-off Experimental self-hosted push on Android, to an endpoint you own

The first two are user-initiated actions; self-hosted push is a standing instruction you explicitly
configure and can turn off. See [PRIVACY_SECURITY.md](PRIVACY_SECURITY.md).

NOOP also checks once a day whether a newer release exists, because it is sideloaded on every platform
and has no store to update it. That is a read of a public version number and sends nothing about you —
no identifier, no account, no health data — and it never installs anything. It is on by default and
switchable off in Settings → About, and the full detail is in
[docs/PRIVACY_SECURITY.md §1.1c](PRIVACY_SECURITY.md).

## Which numbers are measured, and which are NOOP's own estimates?

Measured from the strap: heart rate, R-R intervals, resting HR, skin temperature, respiratory rate,
sleep duration and stages.

NOOP's own on-device scores, not clinical measures: Charge (recovery), Effort (strain), Rest (sleep
performance), Stress, Fitness Age and Vitality. [docs/ANALYTICS.md](ANALYTICS.md) documents the
formula behind each one.

NOOP does not invent values it cannot measure. Where a figure needs an input your strap doesn't
provide, the feature stays locked and says so rather than guessing.

## Why does a score say "Calibrating"?

Baseline-relative scores need history before they mean anything. Charge needs several nights of HRV
before it can tell a high night from a low one, so it shows a countdown instead of a number.

Tapping **Recalibrate baseline** restarts that countdown from zero — it discards the nights already
banked. If you're sitting at "Calibrating" and tap it again, you reset your own progress.

## Is NOOP a medical device?

No. It is not a medical device and makes no diagnostic claim. Values are raw readings or
locally-computed estimates, for personal and informational use only.
