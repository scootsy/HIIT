# HIIT Coach

A simple, beautiful iOS app that builds smart interval workouts around *your* equipment, *your* level, and *your* time — then guides you through them in real time and gets a little harder every time you succeed.

Built with SwiftUI + SwiftData + HealthKit + Swift Charts. No accounts, no subscriptions, no servers — everything lives on your phone.

## What it does

**Tell it where you're training.** Treadmill, stationary bike, or outdoors. The first time you pick a machine it asks what the machine can actually do — top speed, incline range, resistance levels, and how quickly the speed buttons react. Every target the app ever gives you is clamped to those limits.

**Tell it who you are.** Connect Apple Health and it pulls your age, weight, height, and resting heart rate to set heart-rate zones (Tanaka formula), calibrate starting intensity, and improve calorie estimates. Or enter things manually — everything degrades gracefully.

**Choose what you need today.** Pick **Hard intervals** for the original HIIT coach, or **Build endurance** for sustainable treadmill/bike cardio. Endurance sessions include a real warm-up and cool-down, aim for a conversational 65–75% of estimated max heart rate, and use the same one-tap live coach to suggest small speed or resistance changes only after your heart rate has had time to settle. Without live heart rate, the full-sentence/RPE cues still guide the session.

**It builds the session — length included.** Pick where you're training and the app proposes your next workout whole: it chooses the duration from your level, history, and recovery state, then assembles a warm-up, a research-based interval protocol, and a cool-down that exactly fills it. Everything is overridable — duration chips (8–60 min via the stepper) and a feel picker ("Coach's pick", "Push me", "Easier today") regenerate the plan in place:

| Protocol | Source | When you'll see it |
|---|---|---|
| Classic intervals | ACSM work:recovery progression (1:2.5 → 1:1) | All levels, the backbone |
| Norwegian 4×4 | Helgerud et al., 2007 | 26+ min sessions, intermediate+ |
| 10-20-30 | Gunnarsson & Bangsbo, 2012 | Bike & outdoor only — treadmill belts can't change speed that fast |
| Pyramid | Standard periodization | Intermediate+ |
| Hill climbs | Low-impact incline work | Treadmills with incline |
| Cadence surges | Leg-speed work | Bike |

**Keep it on screen while you train.** The app keeps the display awake for the whole session, so this happens naturally — but if you press the power button or switch apps mid-workout, audio cues and live heart rate pause until you come back (the timer reconciles the gap from the wall clock, and the summary notes any time that ran unguided).

**It follows you to the lock screen — and keeps working there.** A Live Activity mirrors the workout in the Dynamic Island and on the lock screen: the current phase, a live countdown, the target you should be holding, what's coming next, and **+/− buttons** that adjust the live targets without unlocking the phone. The session itself keeps running with the screen off or another app up front — the audio session and Bluetooth background modes keep the timer, beeps, spoken cues, strap heart rate, and the live coach alive in your pocket — and when the coach has a suggestion, it appears **on the lock screen with its own Apply button** and lights the screen to tell you.

**It guides you through it.** A full-screen, phase-colored timer with a big countdown ring, the exact speed/incline or resistance/cadence to hit, and — the detail that matters on a treadmill — an **amber early warning before every step up**, sized to your machine's lag, so you can press the buttons before the interval starts. Cues are synthesized tones played through the media channel (they work with the ringer switch off and mix over your music), and the cue *language* is semantic — each sound shape means one thing, so the session reads with eyes closed: a **double-beep** at the warning lead says "reach for the machine", a **rising 3-2-1** counts you in by pitch (no counting needed), a high **GO** completes the rise when the harder phase lands, and long efforts get a **halfway marker**. Optional **spoken cues** say the actual numbers — "Next: push — 6.8, incline 2" — ahead of every change, plus "halfway" and the live coach's advice, so you never have to look down at all. Slow-downs get no warning — braking early just cuts the effort short — instead each work interval counts itself out with the same 3-2-1 and a distinct done tone, so you push through to the line. If live heart rate is available (Apple Watch workout or a chest strap), it nudges you in real time when you're above or below the target zone. Feeling better than the plan? Tap **±** on the live target ("it said 5.0 but I'm running 5.5") — the change applies to the rest of the session, the calorie/distance math follows what you actually did, and the next session starts where you actually trained.

**It coaches the day, not just the plan.** With live heart rate, a rule-based live coach watches the session against its objectives and offers **one-tap corrections** when the day drifts from the plan: sustained HR above the zone → "ease the remaining efforts back"; two efforts in a row that never reach the zone → "you've got more in you"; recoveries that aren't coming down, or a slow 1-minute recovery → ease off. Suggestions appear as a small chip with the exact new target ("drop to 6.8 mph · 2 efforts left") — **Apply** routes through the same override path as the manual ±, so nothing changes unless you say so, and what you accept counts toward next session's starting point. It's deliberately bounded: one suggestion at a time, a cooldown between them, at most a few tenths per session, never during warm-up/cool-down, and never judging an effort HR hasn't had time to catch.

**It learns.** After each session you rate the effort (RPE 1–10). Finish everything comfortably and next session's targets step up; a maximal or unfinished session holds or steps back; heart-rate data can veto increases after sessions that ran too hot. Every ~6th hard session is deliberately lighter — a recovery week you don't have to remember to schedule. It also learns *your* physiology: sessions with live HR build a personal **speed→heart-rate calibration** that pulls generated work speeds toward where your zones actually live (conservatively — halfway, bounded, and only once three sessions of clean data exist), and when you genuinely exceed your estimated max heart rate, the summary offers a **one-tap max-HR update** so every zone and grade gets more accurate.

**It grades the session.** With live heart rate, the summary answers "did this workout do its job?" in plain language: time at ≥85% of max HR (the high-intensity dose HIIT is programmed for), the share of work time spent in the target zone, how far your heart rate fell between efforts, and your 1-minute recovery after the last one — each marked met, partial, or missed, with what to change next time.

**It remembers.** History with per-phase breakdowns, a weekly-minutes trend chart, and automatic export of every workout (duration, estimated calories, distance) to Apple Health. It also tracks the fitness signals a coach would actually watch: **Cardio Fitness (VO₂max)** and **resting heart rate** trends pulled from Health, plus **1-minute heart-rate recovery** measured automatically after your last hard interval whenever live HR is available.

**Optional AI coach — now a coach you can talk to.** Add your own API key — Anthropic (Claude), OpenAI, or Google (Gemini) — in Settings and the coach opens as a **chat**: it starts with concrete feedback on the session you just finished (including how it graded against its objectives), and takes follow-up questions. Ask for a change — "make things easier", "shorter sessions", "let me walk the recoveries" — and it proposes real plan changes from a fixed menu (difficulty level, next-session length, walking recoveries) rendered as **tap-to-confirm buttons**: nothing applies without your tap, and what you approve flows through the app's ordinary progression machinery. Keys live in the device Keychain and requests go directly from your phone to the provider you chose — no middleman. Each request contains your profile numbers (age, weight, resting HR), your experience level, recent session stats and grades, and any workout notes you wrote — nothing else leaves the device, and only when you open the coach.

## Requirements

- Xcode 16 or newer
- iOS 17.0+ device
- A free or paid Apple Developer account (free is fine for sideloading)

## Build & sideload

1. Clone the repo and open `HIIT.xcodeproj` in Xcode.
2. Select the **HIIT** target → **Signing & Capabilities** → choose your **Team** (add your Apple ID under Xcode → Settings → Accounts if needed). Xcode will manage signing automatically; change the bundle identifier if it collides.
3. Plug in your iPhone, select it as the run destination, and press **Run**.
4. First run on a free account: on the phone, go to **Settings → General → VPN & Device Management** and trust your developer certificate.

Notes for free accounts: apps expire after 7 days (re-run from Xcode to refresh), and you're limited to 3 sideloaded apps at a time. The HealthKit capability works fine with free provisioning.

## Live heart rate — two ways

**Bluetooth monitor (best, no Apple Watch needed).** Any watch or chest strap that broadcasts the standard Bluetooth heart-rate profile works: Amazfit watches/straps (turn on heart-rate broadcast in the Zepp app), Polar, Garmin, Coospo, and most gym straps. Pair once in Settings → Heart-rate monitor, and every workout connects automatically and shows your pulse second-by-second. The architecture is deliberately `strap → app` live, `app → Apple Health` for the durable record — Health is a database, not a real-time sensor feed, and third-party watch apps batch their Health writes far too slowly for live coaching. Strap-sourced heart-rate samples are saved to Health with the finished workout, so your Health history gets the full trace.

**Apple Watch.** Start any workout on the Watch and its heart-rate samples stream through Health in near-real-time; the app picks those up automatically (a paired Bluetooth monitor takes priority if both are present, since it updates faster).

Without either source, everything still works — you train by the speed/resistance targets and RPE instead of live bpm.

## Sideloading and the Health permission sheet

The HealthKit permission sheet can only appear if the installed app carries the `com.apple.developer.healthkit` entitlement. Xcode installs always do. Sideloaded IPAs depend on the re-signing tool: the CI-built IPA ships ad-hoc-signed with the entitlement embedded so AltStore/SideStore/Sideloadly can carry it over, but if your tool strips it, iOS silently refuses the authorization request — the app detects this and tells you, and reinstalling via Xcode fixes it. This applies doubly to container-style launchers (LiveContainer and similar), which run the app under their own signature.

Helpfully, the live Bluetooth heart-rate path uses CoreBluetooth, not HealthKit — so live HR from a paired strap works even in installs where the Health integration can't. You lose only the durable Health sync until the app runs properly signed.

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
│   ├── ProgressionEngine.swift Progressive-overload rules
│   └── MetabolicMath.swift    ACSM MET equations, calories, HR zones
├── Health/                    HealthKit auth, profile pull, live HR, workout export
├── Coach/                     Optional AI-coach client (Claude/OpenAI/Gemini) + Keychain
├── Support/                   Theme, tones, checkpointing, Live Activity controller
└── Views/                     Home, guided setup, live workout, summary,
                               history + charts, settings, science explainer
Shared/                        Live Activity attributes + intents (app + widget)
HIITWidgets/                   Widget extension: lock screen + Dynamic Island UI
```

## Disclaimers

HIIT Coach provides general fitness guidance, not medical advice. Calorie and distance figures are estimates from standard metabolic equations, not measurements. Stop any session that causes pain, dizziness, or chest discomfort, and talk to a doctor before starting a new exercise program.

## License

MIT — see [LICENSE](LICENSE).
