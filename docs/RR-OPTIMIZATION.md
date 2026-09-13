# R-R Optimization

The R-R optimization work improves the beat-to-beat interval processing that feeds HRV, and through it Recovery and Sleep. This document records what shipped, the measurement harness, and the findings that came out of running that harness against real WHOOP-labeled data. Several findings corrected an earlier literature-only hypothesis, so read the corrections before acting on the older plan.

## What shipped

`HrvAnalyzer` gained gap-aware RMSSD and pNN50 (`cleanRRGapAware`, `rmssdGapAware`, `pnn50GapAware`). When cleaning drops an out-of-range or ectopic beat, its two neighbours become adjacent in the cleaned list, and the plain successive-difference RMSSD counts the difference across that splice as a real beat-to-beat delta. Because RMSSD squares each delta, one removed beat can bias RMSSD high. The gap-aware path skips any difference that straddles a dropped beat. On a series with no drops it is identical to the plain path, so clean data and the existing golden vectors are unchanged. Wired into `analyzeRaw` (spot and daytime and windowed HRV) and the nightly `SleepStager.sessionHrvWindows`.

The gap-aware analysis path shipped as PR ryanbr/noop#204 (iOS/macOS twin #208). It composes with the seq storage fix (PR ryanbr/noop#163): the PK `(deviceId, ts, rrMs, seq)` stops two equal same-second intervals from colliding under INSERT IGNORE and being dropped, which also biased RMSSD high. The two fixes cover the same class of defect from opposite sides, one at storage and one at analysis.

## The harness

Seven tests under `app/src/test/java/com/noop/analytics` (five in `.../agreement`), in two tiers: committed synthetic tests that run in CI, and fixture-backed tests that validate against real public datasets and skip via `assumeTrue` when their local fixtures are absent, so CI stays green.

Committed, CI-safe (synthetic, no fixtures):

`RrVersionRundownTest` reproduces the three algorithm versions from the tree's own public functions (`rmssdRaw`+`cleanRR` = pre-fix, `rmssdGapAware`+`cleanRRGapAware` = rr-opt, plus a `(ts,rrMs)` dedup that reproduces the old storage drop), replays identical synthetic sleep windows carrying both artifact classes, and writes `build/rr-rundown.md`. It asserts the accuracy ordering improves monotonically (ryanbr MAE >= +2PR MAE >= rr-opt MAE), so a regression in gap-aware fails the build. On synthetic data the MAE versus the true rhythm falls 0.41 to 0.17 to 0.11 ms across the three versions.

`HrvArtifactDensityTest` sweeps injected artifact density and asserts the gap-aware RMSSD and pNN50 stay monotonic and bounded as more beats are dropped — a property test pinning the gap-aware invariant with no external data.

Fixture-backed, local-only (read `-Dnoop.hrvGoldFixtures` / `-Dnoop.rrFixture`; skip in CI):

`HrvGoldAgreementTest` feeds range-cleaned NN windows from the public gold datasets (AAUWSS PSG-ECG, GalaxyPPG Polar-H10) through the pure primitives and asserts RMSSD/SDNN/pNN50 match a textbook reference to 1e-6, isolating the formula from the cleaning. It consumes only windows-shaped fixtures carrying a computed gold `refRmssd`, so it ignores the array-shaped and model-reference fixtures that share the directory.

`HrvOpticalRobustnessTest` compares plain versus gap-aware RMSSD against the gold R-R under injected optical artifacts and asserts gap-aware cuts the mean absolute error on the regular-rhythm windows — the real point of the shipped fix.

`HrvFreqAgreementTest` pins the frequency-domain LF/HF path against an independent reference.

`RecoveryAgreementTest` feeds diverse driver-input cases through `RecoveryScorer.recovery` and asserts each matches an independent numpy replication of the exact z-score + logistic composite, pinning all recovery constants against silent regression.

`RealDataRundownTest` runs the real `HrvAnalyzer` over a fixture exported from a noop backup DB paired to a WHOOP CSV export. The fixture holds personal biometrics, so it is not committed; it reads an absolute path (`-Dnoop.rrFixture=...`) and skips when absent.

## Findings from the real data

Base data was one user's own capture: 289,940 R-R intervals across eight nights from a noop backup, paired to the same eight nights of WHOOP CSV export (WHOOP's own reported Recovery, HRV in RMSSD ms, RHR, respiration, stage minutes).

1. Gap-aware helps more on real data than synthetic. Whole-night HRV MAE versus WHOOP fell from 8.47 ms (no gap handling) to 5.47 ms (gap-aware), a 35 percent reduction, because real optical PPG carries more artifacts to exclude than the synthetic model. This is the strongest real validation of the shipped fix.

2. The seq storage delta is not visible in this backup. The backup predates the seq PK, so the equal-beat duplicates were already dropped at storage. On this stored data the ryanbr and +2PR versions are identical; that delta only shows in the synthetic rundown. Confirming the seq delta on real data needs a fresh capture with the seq fix in place.

3. ln(RMSSD) did not help. The literature (Plews 2013) prefers ln(RMSSD) for recovery because RMSSD is right-skewed, but on the available nights the HRV range was narrow and low, so the log barely moved the relative z-scores and slightly worsened the recovery correlation (0.819 to 0.810). Parked until a wider HRV range is available.

4. Correction to the deep/SWS window hypothesis. An earlier literature-only plan expected WHOOP's lower reported HRV to come from measuring over slow-wave sleep, and recommended defaulting noop's HRV headline to a deep window. The real data refutes the mechanism: deep sleep has the highest HRV (low HR, high vagal tone), so a deep or lowest-HR window reads higher, not lower, and correlated negatively with WHOOP on these nights. noop's whole-night over-read versus WHOOP is more consistent with artifact inflation from sparse and trimmed R-R than with a windowing choice, and it is reduced by the gap-aware fix rather than by re-windowing. Do not default to the deep window to chase WHOOP's absolute value.

   The refutation is specific to STAGE-based window selection, not to overnight window selection in general, and the two must not be conflated. A quality-based selector is a separate mechanism and is not a dead end. A second wearer reports that selecting the lowest-variance (stillest) overnight windows and taking the median RMSSD across them, with no reference to sleep stage, moved leave-one-out recovery correlation from -0.485 to +0.665 at n = 20 nights. That is the same artifact-freeness idea applied at window selection rather than at beat cleaning, so it composes with the gap-aware fix rather than competing with it. The distinction that matters is stage-based, which is dead, versus variance or quality based, which is live. A per-window beat floor (the change below) is the crude form of the same quality filter; a variance selector is its sharper version.

5. Recovery drivers reverse-engineered. Fed WHOOP's own inputs, WHOOP recovery correlates most with sleep performance (r = 0.80), then the HRV/RHR ratio (r = 0.78), then HRV (r = 0.74) and RHR (r = -0.63); respiration and skin temperature are near zero. WHOOP weights sleep far more than noop's `RecoveryScorer` does (`wSleep = 0.15`), and the HRV/RHR ratio tracks better than HRV alone. A fixed, unfitted composite of the HRV/RHR ratio plus sleep raises the correlation with WHOOP recovery from noop's 0.817 to 0.849 with no fitting.

## Honest limits

Two separate limits, each capping a different metric.

Recovery match is capped by sample size. On eight nights a multi-parameter fit reaches 0.849 in-sample but only 0.575 leave-one-out, which is overfitting. An unfitted composite holds at about 0.85. A legitimate correlation near 0.91 needs more nights, so exporting a fuller WHOOP history is the unlock, since WHOOP's data export returns the full account.

HRV absolute match is capped by capture quality. Only three of the eight nights had adequate R-R coverage, because the band is OS-bonded to the WHOOP app and the co-resident noop capture is trimmed. Matching WHOOP's HRV closely needs an exclusive bond on a spare phone without the WHOOP app, not a better formula.

## Candidate changes not yet shipped

These are supported by the analysis but were deliberately not shipped, each for a stated reason.

Raise the recovery sleep weight and add an HRV/RHR-ratio term in `RecoveryScorer`. Supported by the driver analysis and by Plews (2013) and Bellenger (2016), but the exact weights need more nights before they are fixed, and the change touches the Swift parity port. A second wearer found that adding an RHR term destabilised their recovery fit and that HRV alone was the robust choice at n = 20, which is the same overfit wall the honest-limits section describes and reinforces holding this until more nights are available.

Recalibrate the recovery logistic (`logisticK`, `logisticZ0`). The shipped `logisticK = 1.6` is too steep and saturates the extremes; a gentler slope cut the recovery MAE from about 20 to about 9 leave-one-out. This centers to the user's current elevated-RHR period, so it needs more nights before the constants are hardcoded, and it should likely become a personal calibration rather than a fixed constant.

Raise the per-window beat floors toward 20 to 30 beats. `sessionHrvWindows` allows a window RMSSD from two beats and `rollingRmssd` from eight, both below Baek (2015)'s roughly 30-beat reliability floor for RMSSD. Cheap and pure-Kotlin, and independent of the WHOOP-match work.

## References

Task Force of the ESC and NASPE (1996), Circulation 93(5):1043-1065. Munoz et al. (2015), PLoS ONE 10(9):e0138921. Baek et al. (2015), Telemed J E-Health 21(5):404-414. Shaffer and Ginsberg (2017), Front Public Health 5:258. Plews et al. (2013), Sports Med 43(9):773-781. Buchheit (2014), Front Physiol 5:73. Bellenger et al. (2016), Sports Med 46(10):1461-1486. Clifford and Tarassenko (2005), IEEE TBME 52(4):630-638. Laguna et al. (1998), IEEE TBME 45(6):698-715.
