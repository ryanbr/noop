# Disclaimer, Trademark & Good-Faith Notice

## 1. Independent & unofficial

This is an independent, unofficial, non-commercial project by an individual hobbyist. It is
**not affiliated with, endorsed by, sponsored by, or connected to WHOOP, Inc.** in any way. All
references to "WHOOP" describe the third-party hardware this software interoperates with and are
**nominative fair use** of the mark — used only to identify that hardware, never to imply origin,
sponsorship, or endorsement, and never as the name of this project's own product or brand.

"WHOOP" and any related marks are the property of WHOOP, Inc. All other trademarks belong to
their respective owners.

**Use it only with a device you own, and do not use this project in breach of any agreement that
applies to you.** This software does not encourage or require you to violate any terms you have
agreed to; how you use hardware you own is your responsibility.

## 2. No proprietary material is contained or redistributed

This repository contains **only original work** authored by the project's contributors, plus
factual protocol observations. Some protocol facts were confirmed by examining the official app
**for the sole purpose of interoperability** — an activity expressly permitted by
**17 U.S.C. § 1201(f)** and analogous interoperability provisions (see §3). **No** such material
is reproduced, redistributed, or included here. Specifically, this repository does **NOT**
contain, bundle, mirror, or link to any of the following:

- WHOOP application binaries, APKs, IPAs, or installers;
- WHOOP firmware, firmware images, or extracted firmware;
- decompiled, disassembled, or reverse-compiled WHOOP source code;
- WHOOP source code, headers, or build artifacts of any kind;
- WHOOP logos, icons, artwork, fonts, screenshots, or other copyrighted/branded assets;
- any WHOOP account credentials, API secrets, or server endpoints.

Application icons, color choices, and UI in this project are **original creations**. Any
similarity to a generic "dark fitness app" aesthetic is coincidental and not copied from any
protected work. Protocol facts (frame layout, command identifiers, field offsets) are
**uncopyrightable factual information** about how bytes appear on a wire, documented through the
author's own observation of traffic to and from a device the author owns.

## 3. Nature of the work: interoperability & security research

The purpose of this project is to allow a person who **owns a WHOOP 4.0 or 5.0/MG device** to read
**their own biometric data** from **their own device** in an interoperable way, and to study the
device for educational and security-research purposes.

- It operates only with the **user's own device** and the **user's own data**.
- It does **not** circumvent any technological protection measure protecting a copyrighted work,
  and does not bypass any subscription, paywall, login, or account control.
- Reverse engineering undertaken solely to achieve **interoperability** of an independently
  created program with other programs is a protected activity under, among others,
  **17 U.S.C. § 1201(f)** (U.S.) and comparable interoperability and research provisions in
  other jurisdictions.
- Nothing here is intended to compete with, devalue, or harm WHOOP's products, services, or
  business. Users are encouraged to maintain an active relationship with the official product.

## 4. Licensing, non-commercial use, and no warranty

NOOP's own source code and documentation are made available under the **PolyForm Noncommercial
License 1.0.0** (see [`LICENSE`](LICENSE)): free for personal and other **non-commercial** use —
you may read, run, fork, and contribute, but commercial use is not granted. The license covers
NOOP's original work only; protocol facts are uncopyrightable, and bundled dependencies keep their
own licenses (see [`NOTICE`](NOTICE)).

The software is provided **as-is**, with **no warranty of any kind**, express or implied. You use it
entirely **at your own risk**, including any risk to your device, data, or warranty status. The
authors accept no liability for any damage, loss, or consequence arising from its use. Review your
own agreements and local laws before use; you are responsible for your own compliance.

## 5. Not a medical device

Outputs such as heart rate, HRV, Charge, Effort, Rest, sleep stages, SpO₂, respiratory rate, and skin
temperature (Charge/Effort/Rest are NOOP's own recovery/strain/sleep scores, not WHOOP's) are
**approximations** computed from published methods. They are **not** clinically
validated, are **not** a medical device, and are **not** medical advice. Do not use them to
diagnose, treat, or make health decisions. Consult a qualified professional.

This applies to **every** feature, including each of the following.

### 5.1 Mind / mood check-in — non-clinical self-tracking only

The **Mind** feature (daily mood check-in and the correlations it draws between your mood and your
other metrics) is a **personal self-tracking journal**. It is **not** a mental-health assessment,
diagnosis, screening, therapy, or treatment, and it is **not** a substitute for care from a
qualified professional. Any pattern or correlation it surfaces is **informational only** — a
reflection of numbers you entered, not a clinical finding.

**If you are struggling, in distress, or in crisis, contact a qualified professional or your local
emergency service straight away — do not rely on NOOP.**

### 5.2 Nutrition import — informational, not dietary advice

Importing nutrition data (e.g. a Cronometer or MacroFactor CSV) simply displays figures **you**
recorded elsewhere alongside your other metrics. NOOP does **not** verify, correct, or endorse those
figures, and nothing it shows is **dietary, nutritional, or medical advice**. For guidance on diet,
supplements, or any condition affected by nutrition, consult a qualified professional.

### 5.3 Apple Health & "Export for Shortcuts" — your data, your choice

On iOS, NOOP can prepare metrics for Apple Health (including the HealthKit-free **"Export for
Shortcuts"** path). NOOP writes **only** the data you explicitly choose to export, **on your own
device**, and only when you trigger it. **You are responsible for the data you push into Apple
Health** and for anything you, or Shortcuts you run, then do with it. NOOP cannot see, retrieve, or
manage data once it is in Apple Health — that store and its sharing settings are governed by Apple
and by you. NOOP-prepared values are the same uncertified approximations described above; do not
treat them as clinical records.

## 6. Good-faith takedown contact

This project is shared in good faith and the author wants to respect others' rights. If you are
WHOOP, Inc. (or another rights holder) and believe anything in this repository infringes your
rights, **please contact the author directly via a GitHub issue or the email on the author's
GitHub profile before filing a formal complaint.** The author will review promptly and, where a
concern is well-founded, will cooperate — including editing or removing the material in question.

The author's intent is interoperability and research, not infringement; most concerns can be
resolved quickly and amicably through direct contact.
