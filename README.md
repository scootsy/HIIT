# HIIT Coach

A simple, beautiful iOS app that builds smart interval workouts around *your* equipment, *your* level, and *your* time — then guides you through them in real time and gets a little harder every time you succeed.

Built with SwiftUI + SwiftData + HealthKit + Swift Charts. No accounts, no subscriptions, no servers — everything lives on your phone.

## What it does

**Tell it where you're training.** Treadmill, stationary bike, or outdoors. The first time you pick a machine it asks what the machine can actually do — top speed, incline range, resistance levels, and how quickly the speed buttons react. Every target the app ever gives you is clamped to those limits.

**Tell it who you are.** Connect Apple Health and it pulls your age, weight, height, and resting heart rate to set heart-rate zones (Tanaka formula), calibrate starting intensity, and improve calorie estimates. Or enter things manually — everything degrades gracefully.

**It builds the session.** Pick a duration (10–60 min) and a feel ("Coach's pick", "Push me", "Easier today") and the generator assembles a warm-up, a research-based interval protocol, and a cool-down that exactly fills your time budget:

| Protocol | Source | When you'll see it |
|---|---|---|
| Classic intervals | ACSM work:recovery progression (1:2.5 → 1:1) | All levels, the backbone |
| Norwegian 4×4 | Helgerud et al., 2007 | 26+ min sessions, intermediate+ |
| 10-20-30 | Gunnarsson & Bangsbo, 2012 | Bike & outdoor only — treadmill belts can't change speed that fast |
| Pyramid | Standard periodization | Intermediate+ |
| Hill climbs | Low-impact incline work | Treadmills with incline |
| Cadence surges | Leg-speed work | Bike |

**It guides you through it.** A full-screen, phase-colored timer with a big countdown ring, the exact speed/incline or resistance/cadence to hit, and — the detail that matters on a treadmill — an **amber early warning before every step up**, sized to your machine's lag, so you can press the buttons before the interval starts. Cues are synthesized tones played through the media channel (they work with the ringer switch off and mix over your music): low beeps count the warning down (lead, 10, 6, 3, 2, 1), then a high **GO** when the harder phase lands. Slow-downs get no warning — braking early just cuts the effort short — instead each work interval counts itself out with the same beeps and a distinct done tone, so you push through to the line. If live heart rate is available (Apple Watch workout or a chest strap), it nudges you in real time when you're above or below the target zone. Feeling better than the plan? Tap **±** on the live target ("it said 5.0 but I'm running 5.5") — the change applies to the rest of the session, the calorie/distance math follows what you actually did, and the next session starts where you actually trained.

**It learns.** After each session you rate the effort (RPE 1–10). Finish everything comfortably and next session's targets step up; a maximal or unfinished session holds or steps back; heart-rate data can veto increases after sessions that ran too hot. Every ~6th hard session is deliberately lighter — a recovery week you don't have to remember to schedule.

**It remembers.** History with per-phase breakdowns, a weekly-minutes trend chart, and automatic export of every workout (duration, estimated calories, distance) to Apple Health. It also tracks the fitness signals a coach would actually watch: **Cardio Fitness (VO₂max)** and **resting heart rate** trends pulled from Health, plus **1-minute heart-rate recovery** measured automatically after your last hard interval whenever live HR is available.

**Optional AI coach.** Add your own Anthropic API key in Settings and get short, concrete feedback on your recent training after any workout. The key is stored in the device Keychain and requests go directly from your phone to Anthropic — no middleman.

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
│   ├── ProgressionEngine.swift Progressive-overload rules
│   └── MetabolicMath.swift    ACSM MET equations, calories, HR zones
├── Health/                    HealthKit auth, profile pull, live HR, workout export
├── Coach/                     Optional Anthropic API client + Keychain storage
└── Views/                     Home, guided setup, live workout, summary,
                               history + charts, settings, science explainer
```

## Disclaimers

HIIT Coach provides general fitness guidance, not medical advice. Calorie and distance figures are estimates from standard metabolic equations, not measurements. Stop any session that causes pain, dizziness, or chest discomfort, and talk to a doctor before starting a new exercise program.

## License

MIT — see [LICENSE](LICENSE).
