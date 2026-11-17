# HIIT Coach

A simple, beautiful iOS app that builds smart interval workouts around *your* equipment, *your* level, and *your* time — then guides you through them in real time and gets a little harder every time you succeed.

Built with SwiftUI + SwiftData + HealthKit + Swift Charts. No accounts, no subscriptions, no servers — everything lives on your phone.

## What it does

**Tell it where you're training.** Treadmill, stationary bike, or outdoors. The first time you pick a machine it asks what the machine can actually do — top speed, incline range, resistance levels, and how quickly the speed buttons react. Every target the app ever gives you is clamped to those limits.

**Tell it who you are.** Connect Apple Health and it pulls your age, weight, height, and resting heart rate to set heart-rate zones (Tanaka formula), calibrate starting intensity, and improve calorie estimates. Or enter things manually — everything degrades gracefully.

**Choose what you need today.** Pick **Hard intervals** for the original HIIT coach, or **Build endurance** for sustainable treadmill/bike cardio. Endurance sessions include a real warm-up and cool-down and aim for a conversational 65–75% of estimated max heart rate — the starting pace comes from the same personalized speed math as interval sessions (experience, earned progression, and your speed→HR calibration), so the band is reachable whatever your fitness. The same one-tap live coach suggests small speed or resistance changes only after your heart rate has had time to settle, re-offering at most every five minutes. Without live heart rate, the full-sentence/RPE cues still guide the session.

**It builds the session — length included.** Pick where you're training and the app proposes your next workout whole: it chooses the duration from your level, history, and recovery state, then assembles a warm-up, a research-based interval protocol, and a cool-down that exactly fills it. Everything is overridable — duration chips (8–60 min via the stepper) and a feel picker ("Coach's pick", "Push me", "Easier today") regenerate the plan in place:

| Protocol | Source | When you'll see it |
|---|---|---|
| Classic intervals | ACSM work:recovery progression (1:2.5 → 1:1) | All levels, the backbone |
| Norwegian 4×4 | Helgerud et al., 2007 | 26+ min sessions, intermediate+ |
| 10-20-30 | Gunnarsson & Bangsbo, 2012 | Bike & outdoor only — treadmill belts can't change speed that fast |
| Pyramid | Standard periodization | Intermediate+ |
| Hill climbs | Low-impact incline work | Treadmills with incline |
| Cadence surges | Leg-speed work | Bike |

**Screen on or off, it keeps going.** The app keeps the display awake for the whole session, and nothing stops if you lock the phone or switch apps — see the next paragraph. Only when iOS itself suspends the app (a phone call taking over audio, say) do cues pause; the timer then reconciles the gap from the wall clock and the summary says how much time ran unguided.

**It follows you to the lock screen — and keeps working there.** A Live Activity mirrors the workout in the Dynamic Island and on the lock screen: the current phase, a live countdown, the target you should be holding, what's coming next, and **+/− buttons** that adjust the live targets without unlocking the phone. The session itself keeps running with the screen off or another app up front — the audio session and Bluetooth background modes keep the timer, beeps, spoken cues, strap heart rate, and the live coach alive in your pocket — and when the coach has a suggestion, it appears **on the lock screen with its own Apply button** and lights the screen to tell you.

**It guides you through it.** A full-screen, phase-colored timer with a big countdown ring, the exact speed/incline or resistance/cadence to hit, and — the detail that matters on a treadmill — an **amber early warning before every step up**, sized to your machine's lag, so you can press the buttons before the interval starts. Cues are synthesized tones played through the media channel (they work with the ringer switch off and mix over your music), and the cue *language* is semantic — each sound shape means one thing, so the session reads with eyes closed: a **double-beep** at the warning lead says "reach for the machine", a **rising 3-2-1** counts you in by pitch (no counting needed), a high **GO** completes the rise when the harder phase lands, and long efforts get a **halfway marker**. Optional **spoken cues** say the actual numbers — "Next: push — 6.8, incline 2" — ahead of every change, plus "halfway" and the live coach's advice, so you never have to look down at all. Slow-downs get no warning — braking early just cuts the effort short — instead each work interval counts itself out with the same 3-2-1 and a distinct done tone, so you push through to the line. If live heart rate is available (Apple Watch workout or a chest strap), it nudges you in real time when you're above or below the target zone. Feeling better than the plan? Tap **±** on the live target ("it said 5.0 but I'm running 5.5") — the change applies to the rest of the session, the calorie/distance math follows what you actually did, and the next session starts where you actually trained.

**It coaches the day, not just the plan.** With live heart rate, a rule-based live coach watches the session against its objectives and offers **one-tap corrections** when the day drifts from the plan: sustained HR above the zone → "ease the remaining efforts back"; two efforts in a row that never reach the zone → "you've got more in you"; recoveries that aren't coming down, or a slow 1-minute recovery → ease off. Suggestions appear as a small chip with the exact new target ("drop to 6.8 mph · 2 efforts left") — **Apply** routes through the same override path as the manual ±, so nothing changes unless you say so, and what you accept counts toward next session's starting point. It's deliberately bounded: one suggestion at a time, a cooldown between them, at most a few tenths per session, never during warm-up/cool-down, and never judging an effort HR hasn't had time to catch.

**It learns.** After each session you rate the effort (RPE 1–10). Finish everything comfortably and next session's targets step up; a maximal or unfinished session holds or steps back; heart-rate data can veto increases after sessions that ran too hot. Every ~6th hard session is deliberately lighter — a recovery week you don't have to remember to schedule. It also learns *your* physiology: sessions with live HR build a personal **speed→heart-rate calibration** that pulls generated work speeds toward where your zones actually live (conservatively — halfway, bounded, and only once three sessions of clean data exist), and when you genuinely exceed your estimated max heart rate, the summary offers a **one-tap max-HR update** so every zone and grade gets more accurate.

**It grades the session.** With live heart rate, the summary answers "did this workout do its job?" in plain language: time at ≥85% of max HR (the high-intensity dose HIIT is programmed for), the share of work time spent in the target zone, how far your heart rate fell between efforts, and your 1-minute recovery after the last one — each marked met, partial, or missed, with what to change next time.

**It remembers.** History with per-phase breakdowns, a weekly-minutes trend chart, and automatic export of every workout (duration, estimated calories, distance) to Apple Health. It also tracks the fitness signals a coach would actually watch: **Cardio Fitness (VO₂max)** and **resting heart rate** trends pulled from Health, plus **1-minute heart-rate recovery** measured automatically after your last hard interval whenever live HR is available.

**It's laid out for iPhone Duo — closed, open, and folded.** Every screen arranges itself for the space it actually has rather than for a list of devices. On the Duo's cover display the live workout is a single compact column that fits without scrolling; open it and the timer ring and heart-rate chart grow to use the large display; turn it on its side and the screen splits into two panes — timer and target on one, stats, heart rate and controls on the other. Half-fold it and the two panes sit on either side of the crease: prop it on the treadmill console like a little laptop and the timer stands upright while the controls lie flat under your hand. Ordinary iPhones get the same treatment, including landscape — a phone wedged sideways on a console finally works.

**Optional AI coach — now a coach you can talk to.** Add your own API key — Anthropic (Claude), OpenAI, or Google (Gemini) — in Settings and the coach opens as a **chat**: it starts with concrete feedback on the session you just finished (including how it graded against its objectives), and takes follow-up questions. Ask for a change — "make things easier", "shorter sessions", "let me walk the recoveries" — and it proposes real plan changes from a fixed menu (difficulty level, next-session length, walking recoveries) rendered as **tap-to-confirm buttons**: nothing applies without your tap, and what you approve flows through the app's ordinary progression machinery. Keys live in the device Keychain and requests go directly from your phone to the provider you chose — no middleman. Each request contains your profile numbers (age, weight, resting HR), your experience level, recent session stats and grades, and any workout notes you wrote — nothing else leaves the device, and only when you open the coach. Providers retire models regularly, so the app doesn't depend on one staying available: if the built-in model is switched off, it asks the provider what your key can use, picks the closest current equivalent, and carries on. You can also name a specific model in Settings.

## Install it (no Mac needed)

Every change merged into `main` is built into an IPA and published as a [release](../../releases) automatically. Two ways to get it onto a phone:

**Add the source once, get updates forever — SideStore or LiveContainer.** The repository maintains an install feed that both apps understand:

```
https://raw.githubusercontent.com/scootsy/HIIT/altstore/apps.json
```

- **SideStore:** Sources → **+** → paste the address. HIIT Coach appears under the source; install it, and SideStore offers each new version as an update (and keeps the 7-day signature refreshed).
- **LiveContainer:** Sources → **+** → paste the same address. Tap the app to install; tap it again later to pull the newest build.

> **The repository has to be public for this to work.** Both apps fetch the feed and the IPA without signing in to GitHub, so while the repository is private the address above returns "not found". Making it public (Settings → General → Danger Zone → Change repository visibility) is all it takes — nothing needs rebuilding, and builds on public repositories also stop counting against the Actions minutes allowance.

**Or grab one build by hand.** Download `HIIT-unsigned.ipa` from the latest release and open it with SideStore, AltStore or Sideloadly; it is re-signed with your Apple ID.

A few things to know about sideloaded copies:

- **Apple Health doesn't work through stock SideStore.** It never asks Apple to switch on the HealthKit capability when it signs an app, so iOS can't show the Health permission sheet (the app says so). There is a fix you can build without a Mac — see [Apple Health and sideloading](#apple-health-and-sideloading).
- **Inside LiveContainer** the app runs as a guest of LiveContainer rather than as its own installed app, so anything iOS ties to the installed app follows LiveContainer instead. The lock-screen Live Activity isn't available there (it needs the app's own widget extension). Apple Health inside LiveContainer depends on LiveContainer's own signature having HealthKit, which stock SideStore doesn't give it either — the app tells you if it doesn't. Workouts, cues, the background session and live heart rate from a Bluetooth strap don't depend on any of that. The window belongs to LiveContainer too, so how much of iPhone Duo's displays the app is given is up to LiveContainer's own Duo support. For the complete experience, install with SideStore.

## Requirements (building it yourself)

- Xcode 27.1 or newer — the first SDK that gives an app all of both iPhone Duo displays, and the one the fold-aware layout is written against
- iOS 17.0+ device
- A free or paid Apple Developer account (free is fine for sideloading)

## Build & sideload from Xcode

1. Clone the repo and open `HIIT.xcodeproj` in Xcode.
2. Select the **HIIT** target → **Signing & Capabilities** → choose your **Team** (add your Apple ID under Xcode → Settings → Accounts if needed). Xcode will manage signing automatically; change the bundle identifier if it collides.
3. Plug in your iPhone, select it as the run destination, and press **Run**.
4. First run on a free account: on the phone, go to **Settings → General → VPN & Device Management** and trust your developer certificate.

Notes for free accounts: apps expire after 7 days (re-run from Xcode to refresh), and you're limited to 3 sideloaded apps at a time. The HealthKit capability works fine with free provisioning.

## Live heart rate — two ways

**Bluetooth monitor (best, no Apple Watch needed).** Any watch or chest strap that broadcasts the standard Bluetooth heart-rate profile works: Amazfit watches/straps (turn on heart-rate broadcast in the Zepp app), Polar, Garmin, Coospo, and most gym straps. Pair once in Settings → Heart-rate monitor, and every workout connects automatically and shows your pulse second-by-second. The architecture is deliberately `strap → app` live, `app → Apple Health` for the durable record — Health is a database, not a real-time sensor feed, and third-party watch apps batch their Health writes far too slowly for live coaching. Strap-sourced heart-rate samples are saved to Health with the finished workout, so your Health history gets the full trace.

**Apple Watch.** Start any workout on the Watch and its heart-rate samples stream through Health in near-real-time; the app picks those up automatically (a paired Bluetooth monitor takes priority if both are present, since it updates faster).

Without either source, everything still works — you train by the speed/resistance targets and RPE instead of live bpm.

## Apple Health and sideloading

The Health permission sheet only appears if the installed app's signature carries Apple's `com.apple.developer.healthkit` entitlement, and that only happens when the signing profile Apple issues for the app includes HealthKit — that is, the capability was switched on for the app's ID. Apple's [capability table](https://developer.apple.com/help/account/reference/supported-capabilities-ios) lists HealthKit for the no-cost tier too, though older sources say a paid membership was needed — that part hasn't been confirmed.

- **Xcode** switches it on for you, so installs from Xcode always have Health.
- **SideStore** doesn't: its signing library has no mapping for HealthKit, so it never asks, Apple's profile comes back without it, and the entitlement is dropped from the signature. HIIT Coach notices and says so when you tap *Connect Apple Health*. (Read from the source of SideStore 0.6.4 and of its development branch.)
- **Other sideloading tools** (AltStore, Sideloadly, …) haven't been checked.

**A fix without a Mac:** [`scripts/sidestore-healthkit`](scripts/sidestore-healthkit/) holds a ten-line change that makes SideStore ask for HealthKit, and a workflow that builds SideStore 0.6.4 with it (Actions → *SideStore with HealthKit (test build)*). It's unofficial and hasn't been tried on a real phone yet — read that folder's README before using it.

Without Health nothing else is lost: live heart rate from a Bluetooth strap uses CoreBluetooth, not HealthKit, and age, weight and resting heart rate can be typed in Settings. What does need HealthKit is reading those values from Health automatically, picking up an Apple Watch's heart rate, and saving finished workouts to Health.

## How releases and the install feed work

`.github/workflows/release.yml` does everything; there is nothing to run by hand.

- **On every pull request** it runs the logic tests, compiles the app with Xcode 27, and prints a preview of what the install feed would contain — so a broken build or a broken feed is caught before merging.
- **On every merge to `main`** it builds the IPA, publishes a GitHub release, and regenerates the install feed on the `altstore` branch.
- **Versions take care of themselves.** Each build is stamped `MAJOR.MINOR.PATCH`: `MAJOR.MINOR` comes from the Xcode project (`MARKETING_VERSION`), and `PATCH` is one more than the newest release — 1.0.31, 1.0.32, … SideStore decides whether an update exists by comparing those numbers, so every release must carry its own. To start a new series, change `MARKETING_VERSION` (to `1.1`, say).
- **The feed describes what was actually built.** After packaging, `scripts/ipa_info.py` reads the version, build number, size and SHA-256 back out of the IPA and attaches them to the release as `release.json`; `scripts/build_source.py` assembles `apps.json` from those files. Installers verify every one of those values against the download, so none of them is ever typed by hand. Delete a release and it drops out of the feed on the next run.
- **Checking layouts without a device.** Actions → *Build & Release IPA* → *Run workflow* → tick *Photograph every screen*: the workflow opens each screen with sample data on the iPhone Duo simulator (closed, open, on its side, half folded), draws the live workout at ordinary iPhone sizes too, and uploads the pictures as an artifact. It takes about a quarter of an hour of macOS runner time, so it only runs when asked. `scripts/screenshots.sh` does the same on a Mac.

## Project layout

```
HIIT/
├── HIITApp.swift              App entry, SwiftData container, environment
├── Models/                    Equipment & machine profiles, plan/phase types,
│                              SwiftData models, persisted settings
├── Engine/
│   ├── WorkoutGenerator.swift Protocol selection + target math (the brain)
│   ├── WorkoutEngine.swift    Live timer state machine, cues, HR aggregation
│   ├── LiveCoach.swift        Rule-based in-session suggestions (one-tap apply)
│   ├── SpeedCalibration.swift Personal speed→HR fit feeding the generator
│   ├── SessionObjectives.swift Post-session HR-based objective grading
│   ├── ProgressionEngine.swift Progressive-overload rules and the weekly cap
│   └── MetabolicMath.swift    ACSM MET equations, calories, HR zones
├── Health/                    HealthKit auth, profile pull, live HR, workout export
├── Coach/                     Optional AI-coach client (Claude/OpenAI/Gemini),
│                              model selection + recovery, Keychain
├── Support/
│   ├── AdaptiveLayout.swift   Fold reading, the flexible full-screen stack
│   ├── DemoMode.swift         Debug-only: any screen with sample data
│   └── …                      Theme, tones, checkpointing, Live Activity controller
└── Views/                     Home, guided setup, live workout, summary,
                               history + charts, settings, science explainer
Shared/                        Live Activity attributes + intents (app + widget)
HIITWidgets/                   Widget extension: lock screen + Dynamic Island UI
Tests/                         Logic tests — ./Tests/run.sh, needs only swiftc
scripts/                       Release tooling (IPA description, install feed,
                               simulator screenshots) and its tests
```

## Disclaimers

HIIT Coach provides general fitness guidance, not medical advice. Calorie and distance figures are estimates from standard metabolic equations, not measurements. Stop any session that causes pain, dizziness, or chest discomfort, and talk to a doctor before starting a new exercise program.

## License

MIT — see [LICENSE](LICENSE).
