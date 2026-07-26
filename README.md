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

**It guides you through it.** A full-screen, phase-colored timer with a big countdown ring, the exact speed/incline or resistance/cadence to hit, haptic + sound cues, and — the detail that matters on a treadmill — an **amber early warning before every change**, sized to your machine's lag, so you can press the buttons before the interval starts. If live heart rate is available (Apple Watch workout or a chest strap), it nudges you in real time when you're above or below the target zone.

**It learns.** After each session you rate the effort (RPE 1–10). Finish everything comfortably and next session's targets step up; a maximal or unfinished session holds or steps back; heart-rate data can veto increases after sessions that ran too hot. Every ~6th hard session is deliberately lighter — a recovery week you don't have to remember to schedule.

**It remembers.** History with per-phase breakdowns, a weekly-minutes trend chart, and automatic export of every workout (duration, estimated calories, distance) to Apple Health.

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

## Live heart rate — what to expect

iPhone apps can't produce heart-rate data themselves. The app reads the most recent samples written to HealthKit, which stream in near-real-time when an Apple Watch has a workout running (start any workout on the Watch) or when a Bluetooth chest strap is paired through a companion app that writes to Health. Without a source, everything still works — you just train by the speed/resistance targets and RPE instead of live bpm.

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
