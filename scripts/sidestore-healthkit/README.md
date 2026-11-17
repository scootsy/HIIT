# Apple Health for SideStore installs

**In short.** SideStore never asks Apple to switch on the HealthKit capability when it signs an app, so HIIT Coach installed through SideStore can't show the Apple Health permission sheet. This folder holds a small fix for SideStore, a check that the fix does what it should, and a workflow that builds a SideStore with the fix — no Mac and no Xcode.

> **Status:** the fix compiles and passes its check, and the build runs on GitHub's Macs. It has **not** been tried on a real phone with a real Apple ID — nothing here can do that. Apple's current documentation says a free Apple ID may use HealthKit, but older sources say a paid membership was needed, so whether Apple will say yes to *your* account is the first thing the test will show. If it says no, see [If Apple refuses](#if-apple-refuses).

## What was found

| Question | Answer | How it was established |
|---|---|---|
| Does the HIIT IPA carry the HealthKit entitlement? | Yes | CI reads it back out of the IPA's signature (`release.json` lists `com.apple.developer.healthkit`). |
| Does Apple let a free Apple ID use HealthKit? | **Its current documentation says yes — the part that could still fail** | Apple's [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios) table ticks HealthKit for the "Apple Developer" column — the no-cost tier. Older tutorials, and a 2022 question on Apple's developer forums that got no answer, suggest it once needed a paid membership. I couldn't test it. |
| Does SideStore ask Apple for it? | **No** | SideStore signs with its SideSign library. In `Sources/Models/Feature.swift`, `Feature(entitlement:)` turns an app's entitlements into App ID capabilities, and has no HealthKit case; the lists of capabilities a free or paid account may request (`freeFeatures`, `paidFeatures`) don't include it either. |
| What happens to the entitlement? | It is dropped | `Sources/CodeSigning/CodeSignerAPI.swift` signs with only the entitlements that are in the provisioning profile Apple returns. Apple's profile has no HealthKit because the App ID never had it switched on. |

Read from the source of SideStore 0.6.4 (SideSign `7f81842`, the current stable release) and of the development branch on 2026-11-17 (SideSign `752d1ef`): the same gap in both. The open-source signing tool PlumeImpactor doesn't map it either — only comments noting the capability's id. I could not check whether SideStore already has a request open for this (GitHub's issue search wasn't reachable from where this was written).

When the entitlement is missing, HIIT Coach says so when you tap *Connect Apple Health*; the Bluetooth heart-rate strap, manual age/weight entry and everything else keep working — only reading your Health profile, picking up an Apple Watch's heart rate, and saving finished workouts to Health need HealthKit.

## The fix

[`healthkit.patch`](healthkit.patch) changes two files of SideSign — ten added lines:

- `Feature.swift` — a `healthKit` capability (`HK421J6T7P`, the id Apple's developer portal uses for HealthKit), mapped from the `com.apple.developer.healthkit` entitlement, and allowed for free and paid accounts.
- `Entitlement.swift` — the matching entitlement constant, listed as available to free accounts in SideStore's entitlement editor.

Clinical Health Records (`com.apple.developer.healthkit.access`) needs special approval from Apple and is deliberately left alone.

[`check/main.swift`](check/main.swift) compiles SideSign's capability code with the patch and checks it: the mapping, the free and paid lists, and that nothing that worked before changed. It runs at the start of every build.

## Building and installing it

The workflow [`sidestore-healthkit.yml`](../../.github/workflows/sidestore-healthkit.yml) checks out SideStore 0.6.4 exactly as released, applies the patch, builds it the way SideStore's own release workflow does, and saves the IPA.

1. On GitHub: **Actions → SideStore with HealthKit (test build) → Run workflow**. Tick **publish** if you'd like a plain download link (a pre-release) instead of an Actions download. The build hasn't been timed yet; expect a while.
2. Make sure the SideStore on your phone is **version 0.6.4** (SideStore → Settings). The patch is for that release; a different version needs its own build.
3. Download the IPA to your phone. In SideStore: **My Apps → +** → choose the file. It has SideStore's own app ID, so it replaces the SideStore you have. The patched one is named **SideStore HK** under its icon — if the icon still says plain *SideStore*, the install didn't take and you are still on the stock one.
4. Now **update HIIT Coach**: Sources → pull down to refresh → HIIT Coach → **Update**. That is the moment SideStore asks Apple for HealthKit and signs the app with it. An update installs over the old copy, so your history stays — don't delete the app. Then, in HIIT Coach, tap *Connect Apple Health*.

   **Update, don't *Refresh*.** In SideStore 0.6.4 a refresh only installs fresh signing profiles (`RefreshAppOperation`); it never re-signs the app, so the app keeps the signature it was installed with. Only an install or update re-signs. And do step 3 first: HIIT Coach updated with stock SideStore is signed without HealthKit, and the same version can't be updated again — you'd have to wait for the next HIIT Coach release.

If the Health sheet still doesn't appear after step 4, the in-app message will say so, with a **Diagnosis** line read from the install's own signing profile: whether Apple's profile includes HealthKit, and how long ago it was issued — please keep that message (and what SideStore said while updating HIIT Coach) for whoever picks this up next.

### If Apple refuses

If Apple won't enable HealthKit for a free Apple ID, SideStore's update of HIIT Coach would show an error, or HIIT Coach would carry on reporting that HealthKit is missing. The remaining route would then be a paid Apple Developer Program membership, where HealthKit is available; how best to use one with SideStore wasn't explored here. Nothing else in HIIT Coach depends on it.

**Going back:** install the official SideStore 0.6.4 IPA from SideStore's releases the same way (or from a computer, as when you first set up).

Things to know:

- This is an **unofficial** build, not made or endorsed by the SideStore team. SideStore is licensed under the GNU AGPL-3.0; the source of a build is the SideStore and SideSign revisions pinned in the workflow plus `healthkit.patch`, and each build's `BUILD-INFO.txt` records them.
- It handles your Apple ID sign-in, like SideStore does. The change is small enough to read in a minute — please do.
- It must be rebuilt (and the patch possibly adapted) when SideStore releases a new version. The cleaner long-term fix is for SideStore to include this change.

## Suggesting it to SideStore

A ready-to-paste issue for [SideStore/SideStore](https://github.com/SideStore/SideStore/issues):

> **HealthKit capability is never requested for apps that declare `com.apple.developer.healthkit`**
>
> Apps that need HealthKit install through SideStore without it: the Health permission sheet never appears (iOS reports the HealthKit entitlement as missing). Cause: SideSign's `Feature(entitlement:)` has no case for `.healthKit`, and `Feature.freeFeatures` / `paidFeatures` don't list it, so `FetchProvisioningProfilesOperation.updateFeatures` never enables the capability on the App ID; Apple's profile then lacks the entitlement and `CodeSignerAPI` drops it. Apple's Supported capabilities (iOS) table lists HealthKit for the free "Apple Developer" tier.
>
> Proposed change (SideSign 7f81842 / SideStore 0.6.4): add `Feature.healthKit = "HK421J6T7P"`, map `.healthKit → .healthKit` in `Feature(entitlement:)`, and add it to `freeFeatures` and `paidFeatures`. Compiles and passes a small unit check; not yet confirmed against Apple's servers with a real account.
