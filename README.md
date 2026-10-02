# VoiceBloom

An iPhone app for voice training toward a more feminine (or androgynous) voice. Pitch, resonance, vocal weight and intonation are all measured on the device, and recordings never leave the phone. The full spec is in [SPEC.md](SPEC.md).

**Status:** Stages 1–6 of 14 are done:
- **Stage 1:** project setup, the audio engine, the live pitch graph, a debug screen, and pitch tests.
- **Stage 2:** resonance, weight and intonation meters, plus microphone calibration.
- **Stage 3:** slip alerts (haptic, sound, visual), eyes-free practice, the "% in target" display, and voice-quality and strain monitoring.
- **Stage 4:** SwiftData storage, automatic session saving, "save this as a recording" with playback, live on-device transcripts, and the post-session check-in with rest-day advice.
- **Stage 5:** the Progress tab: trend charts, practice calendar, check-in history, scenario radar, Then vs Now, weekly summary, CSV export and a shareable progress image.
- **Stage 6:** first-launch onboarding (9 steps, with the placement test and the Day 1 baseline recording) and the Settings screen.

> **Building in Xcode yourself?** Stage 4 added a speech recognition entry and Stage 6 a Face ID entry to Info.plist: see [steps 3.4 and 3.5](#3-target-settings). The GitHub build already includes both.

---

## Install without a Mac (Windows)

You can't run Xcode on Windows, so GitHub builds the app for you on one of its Macs (free for public repos, and within the free monthly minutes for private ones).

**1. Build `VoiceBloom.ipa` on GitHub**
1. Open the repo on github.com and click the **Actions** tab.
2. Pick **Build iPhone app** on the left, click **Run workflow**, then the green **Run workflow** button. (It also runs by itself after each change to the app code.)
3. Wait for the green tick (about 10–15 minutes).
4. Open the run, scroll to **Artifacts**, and download **VoiceBloom-ipa**. Unzip it to get `VoiceBloom.ipa`.

If the run turns red, open it, click the failed step, and copy the lines containing `error:`.

**2. Install with Sideloadly**
1. On Windows, install Apple's **Apple Devices** app (Microsoft Store) or iTunes, then **Sideloadly** from sideloadly.io.
2. Plug in the iPhone, unlock it, and tap **Trust** if asked.
3. Drag `VoiceBloom.ipa` into Sideloadly, enter your Apple ID, and click **Start**.
4. On the iPhone: **Settings ▸ General ▸ VPN & Device Management**, tap your Apple ID, then **Trust**. If iOS asks, turn on **Settings ▸ Privacy & Security ▸ Developer Mode** and restart.

With a free Apple ID the app stops opening after 7 days. Install the same `.ipa` again to refresh it; your saved sessions are kept.

The workflow uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to create the Xcode project from `project.yml` (same settings as the steps below), then builds an unsigned app that Sideloadly signs.

---

## Xcode setup (one time)

Requires **Xcode 26+** and an iPhone on **iOS 26+**. The repo has all the source files but no `.xcodeproj`. You create the project once in Xcode and then move it into the repo.

### 1. Create the project

1. Clone this repo (for example to `~/Developer/VT`).
2. In Xcode choose **File ▸ New ▸ Project… ▸ iOS ▸ App ▸ Next**.
3. Fill in:
   - **Product Name:** `VoiceBloom` (it must be exactly this, because the tests use `@testable import VoiceBloom`)
   - **Team:** your Apple ID (a free Personal Team is fine)
   - **Organization Identifier:** e.g. `com.yourname`
   - **Interface:** SwiftUI · **Language:** Swift
   - **Testing System:** Swift Testing with XCTest UI Tests
   - **Storage:** None (the app sets up SwiftData in code)
4. Click **Next**, choose a **temporary folder** such as the Desktop, untick **Create Git repository on my Mac**, and click **Create**.
5. **Quit Xcode.**

### 2. Move the project file into the repo

1. In Finder, open the temporary `VoiceBloom` folder Xcode created.
2. Move **only `VoiceBloom.xcodeproj`** into the root of this repo, next to the `VoiceBloom/`, `VoiceBloomTests/` and `VoiceBloomUITests/` folders.
3. Delete the rest of the temporary folder. Its template files (`ContentView.swift`, the app file, assets and tests) are replaced by the ones in the repo.
4. Open `VT/VoiceBloom.xcodeproj`. Xcode syncs those three folders automatically, so every file appears without being added by hand. Any file added to these folders later is picked up the same way.

### 3. Target settings

Select the blue **VoiceBloom** project in the navigator.

1. Select the **VoiceBloom** target, open **General**, and set **Minimum Deployments** to **iOS 26.0**. You can also remove iPad, Mac and Vision under **Supported Destinations**.
2. Open **Build Settings**, choose **All**, search for `Swift Language Version` and set it to **Swift 6**. Do this for all three targets: **VoiceBloom**, **VoiceBloomTests** and **VoiceBloomUITests**.
   - Leave **Default Actor Isolation** and **Approachable Concurrency** at Xcode's defaults. The code marks its isolation explicitly, so it works with either setting.
3. Open the **Info** tab, hover over a row under **Custom iOS Target Properties**, click **+**, and add:
   - Key: **Privacy - Microphone Usage Description** (`NSMicrophoneUsageDescription`)
   - Value: `VoiceBloom listens to your voice while you practice to measure pitch and resonance. Audio is analyzed on your iPhone and never leaves it.`
4. In the same list, click **+** again and add:
   - Key: **Privacy - Speech Recognition Usage Description** (`NSSpeechRecognitionUsageDescription`)
   - Value: `VoiceBloom can show a live transcript of what you say while you practice. Speech is recognized on your iPhone and never leaves it.`

5. Add one more row:
   - Key: **Privacy - Face ID Usage Description** (`NSFaceIDUsageDescription`)
   - Value: `VoiceBloom can lock with Face ID so your practice stays private.`

No capabilities are needed: SwiftData is set up in code, data stays on the device (iCloud sync is a later, optional stage), and reminders are local notifications.

### 4. Run on your iPhone

1. Connect the iPhone. If it asks, turn on **Settings ▸ Privacy & Security ▸ Developer Mode** and restart the phone.
2. Pick the iPhone as the run destination and press **⌘R**.
3. With a free Personal Team, the first launch is blocked until you trust the developer under **Settings ▸ General ▸ VPN & Device Management**.

### 5. Run the tests

Pick any iPhone simulator and press **⌘U**. The unit tests don't need a microphone.

### 6. Commit the project file

```sh
git add VoiceBloom.xcodeproj
git commit -m "Add Xcode project"
```

`.gitignore` already excludes per-user Xcode state.

### Troubleshooting

| Problem | Fix |
|---|---|
| `No such module 'VoiceBloom'` in tests | The product name must be exactly `VoiceBloom`. |
| `DEVELOPMENT_ASSET_PATHS … does not exist` | Build Settings: delete the `Development Assets` entry (older templates point it at a `Preview Content` folder). |
| App crashes the moment you tap **Start Listening** | The microphone usage description (step 3.3) is missing. |
| Live transcript says it "isn't set up in this build" | The speech recognition usage description (step 3.4) is missing. |
| Live transcript says on-device transcription isn't available | Turn on Dictation for your language (**Settings ▸ General ▸ Keyboard ▸ Enable Dictation**) so iOS downloads the on-device speech model. The app never falls back to Apple's servers. |
| Concurrency errors mentioning Swift 5 | Make sure **Swift Language Version** is 6 on every target. |

---

## What to try on the device

Stages 2 and 3 need no extra Xcode setup. Stage 4 needs the speech recognition entry from step 3.4.

**Stage 6:**
- **Onboarding** appears on first launch only (**More ▸ Debug & Tuning ▸ Show onboarding again** replays it without deleting anything). Nine steps:
  1. Welcome: what pitch, resonance, vocal weight and intonation are.
  2. Health notice: training should never hurt.
  3. Microphone and (optional) speech recognition permission.
  4. Mic calibration (or skip).
  5. Goal: Feminine 180–220 Hz, Androgynous 150–180 Hz, or a custom range.
  6. Experience level. *Some training* and *Experienced* offer the **placement test**: match 5 reference tones (listen, then hum each back within ±10 Hz), hold a bright "ee" for 6 s, and read a passage. The result recommends a starting week (1, 3, 7, 10 or 12) and unlocks it and the weeks before it for the lessons in Stage 7.
  7. Daily goal (10/15/20/30 min), usual session length, and an optional daily reminder (worded neutrally: "Time for practice").
  8. **Baseline recording:** read an original passage, then talk freely for 30 s. Saved as your "Day 1" recordings (they feed Then vs Now), and your own pitch, F2/F3, H1–H2 and intonation become the starting point (0) that the resonance, weight and intonation scores count up from.
  9. Optional Face ID lock and AI Coach.
- **Settings** (**More ▸ Settings**): goal and pitch range, resonance/weight/intonation targets (or defaults), pitch shown as Hz, note names or both (the Practice readout follows it), slip alerts, re-run calibration/placement/baseline, daily goal, reminder, session length, AI Coach (on/off, which coach, an optional Gemini key kept in the Keychain), Face ID lock, **Delete all data**, and the theme (system/light/dark). iCloud sync and backup show "Coming soon" (Stage 13).
- **Face ID lock:** when on, the app locks whenever it goes to the background and asks for Face ID (or your passcode) when you return.

**Stage 5:**
- **No data yet?** Open **More ▸ Debug & Tuning ▸ Generate sample history**. It adds ~90 days of slowly improving sessions, check-ins (a few "Sore"), scenario scores and two synthetic recordings, all marked so **Remove sample history** deletes only them.
- **Progress tab**, with a **7D / 30D / 90D / All** range picker at the top:
  - **This week:** practice time, sessions, active days, best day (highest % in target), biggest improvement on last week, and the area to focus on with a tip.
  - **Average pitch** per session with your target zone shaded and each session's low–high range as a faint bar.
  - **Resonance, weight & intonation** lines; tap the chips to show or hide each one.
  - **Time in target** per session with the 70% lesson goal.
  - **Practice time** per day or week, with your daily goal line.
  - **Practice calendar:** a heatmap of practice days (darker = more minutes, a dot = goal met). Tap a day for its minutes.
  - **Comfort check-ins:** throat comfort (shape and color) and how natural it felt, over time.
  - **Scenario skills:** a radar chart of pitch, resonance, weight, intonation and consistency from scenario practice (filled in by Stage 10; sample data shows it now).
  - **Then vs Now:** your baseline (or first) recording next to the latest, with stats side by side and a button that plays both back to back.
  - **Export:** share a CSV of every session's stats, or a picture of your progress.
- **Tap any point** on the pitch, scores, in-target or check-in charts to open that session (its stats, check-in and recordings). **All sessions** at the bottom lists everything.

**Stage 4:**
- **Sessions save themselves.** Practice for a few seconds: once you've spoken for 3+ seconds the session is stored, and it's updated every 20 seconds and whenever you leave the app. Nothing is lost if iOS closes the app; a session left open is closed on the next launch.
- **Finish:** tap **Finish** (bottom bar, or **⋯ ▸ Finish Session**). Listening stops, the session is saved, and a fresh session starts. **⋯ ▸ Discard Session** deletes the current one, including its recordings, after confirming.
- **Check-in:** after Finish, a sheet asks *How did your throat feel?* (Fine / A bit tired / Sore) and *How natural did your voice feel?* (1–5). *Skip* is always there.
  - Choose **Sore** twice within 3 days and the app suggests a rest day, and recommends a doctor or speech-language pathologist if it continues. A *Rest day suggested* banner shows on Practice that day and the next.
  - Three **Sore** answers within 7 days gives a stronger "please get your throat checked" message.
  - If a session ended without a check-in (for example the app was closed), Practice offers *How did your last session feel?* for up to 12 hours.
- **Save Clip:** tap it right after saying something you liked. The last 30 seconds (less if you just started) are saved as an AAC `.m4a` file with their own pitch, % in target, resonance, weight and intonation, plus the transcript of those words when the live transcript is on. Audio from before a pause is kept, so you can pause first and then save.
- **Live transcript:** **⋯ ▸ Show Live Transcript**. The first time, iOS asks for speech recognition permission. Words appear under the pitch graph as you speak. Recognition runs only on the iPhone (`requiresOnDeviceRecognition`), using the app's own microphone audio.
- **Progress tab:** every session, newest first, with duration, average pitch, % in target, how your throat felt and the number of recordings. Tap one for all its stats (pitch, scores, jitter/shimmer/HNR, alerts), its check-in (add or edit it), and its recordings.
  - **Play** a recording: listening pauses first so the mic doesn't analyze the playback. Starting to listen again stops playback.
  - Swipe left to delete a recording, or a whole session from the list (not the one in progress).
  - Charts arrive in Stage 5.
- **Where things are stored:** sessions, check-ins and the profile are in a SwiftData store in the app's Application Support folder. Recordings are `.m4a` files in `Application Support/Recordings`, excluded from iCloud and computer backups and encrypted while the iPhone is locked. Calibration, alert settings and voice-quality norms stay in UserDefaults, because they belong to this iPhone's microphone.

**Stage 3:**
- **Slip alerts:** start listening, speak in your target zone, then let your pitch drop back below it.
  - After about 2 seconds you feel two soft taps, a warm outline appears around the pitch graph, and a banner suggests easing back up.
  - Resonance darkening gives a single low buzz and outlines the meters card.
  - Pauses between words don't count, and alerts come at most every 4 seconds.
  - Configure them in **⋯ ▸ Alerts & Feedback**: haptic, sound and visual separately, pitch and resonance separately, and *Gentle / Standard / Sensitive* (3 s / 2 s / about 1 s, with different thresholds).
  - Sound alerts are off by default. The mic hears the chime (and the vibration), so those few hundred milliseconds are left out of your stats. Headphones avoid this for chimes.
- **Eyes-free practice:** the **Eyes-free** button opens a full-screen, high-contrast view.
  - Haptics are the feedback: two taps mean pitch drifting, a low buzz means resonance darkening, a light tap means back on target. Soft chimes are optional.
  - The screen stays awake, and proximity sensing turns it off when you put the phone face down or in a pocket, while listening continues. Locking the phone still pauses, because the app doesn't use background audio.
- **% in target:** a ring shows the session's percentage, with the last 10 seconds and the share of time with bright resonance underneath.
- **Voice comfort card:** jitter, shimmer and HNR. For the first ~10–20 s of voicing in your first sessions it says *Learning your usual voice*. After that it compares your last 20 seconds with your normal: the start of the current session at first, then a stored average once you have 2+ sessions.
  - If roughness stays 30%+ above normal for 10 seconds, a "Your voice sounds tired. Take a break." banner appears, with a gentle haptic and a *Take a Break* button. It won't repeat for 10 minutes.
  - Everything is labelled as a rough phone-mic indicator, not a diagnosis.
- **Debug & Tuning:** per-frame jitter, shimmer, HNR and cycle count, recent versus normal values, the roughness ratio, the slip thresholds, and buttons to feel each haptic cue.

**Stage 2:**

- **Calibrate first.** Practice shows a *Calibrate your microphone* card; you can also use **More ▸ Microphone Calibration**. You stay quiet for 5 seconds, then hold a comfortable "aah". The results report room noise (quiet / some noise / too noisy) and voice level (good / too quiet / too loud). Once saved, the measured room level becomes the lowest the noise gate can go.
- **Practice tab:**
  - Pitch: big readouts and the 10-second graph, as in Stage 1.
  - The **Voice** card has three 0–100 meters, each labelled at both ends:
    - **Resonance** (Dark ↔ Bright) uses F2 and F3.
    - **Weight** (Heavy ↔ Light) uses H1–H2 and spectral tilt.
    - **Intonation** (Flat ↔ Melodic) uses pitch variation in your last phrase.
  - Use the menu on the Voice card to choose what resonance is compared against: *Speech*, or a held vowel ("ee", "ih", "ay", "ah"). Formants depend heavily on the vowel, so pick the one you're holding.
  - Intonation updates after you finish a sentence and pause.
  - Start/Pause is pinned to the bottom of the screen.
- **More ▸ Debug & Tuning:** F1–F3 with bandwidths, raw and formant-corrected H1–H2, spectral tilt, the last phrase's variability and rises/falls, the stored calibration values, and engine timing.
- **Interruptions:** start listening, then trigger Siri or take a call. Listening pauses, and resumes by itself if iOS allows it. Leaving the app pauses too; tap **Resume** when you come back.
- **Bluetooth:** the app only allows Bluetooth for *playback*, so with AirPods connected the iPhone's own mic is still used. If a Bluetooth or car microphone does end up as the input, a warning explains that resonance readings will be unreliable.

**Defaults and tuning:**
- The resonance references are rounded adult averages from classic vowel studies: male averages as the starting point, female averages as the target.
- The weight and intonation references are provisional.
- All three get replaced by your own baseline in Stage 6 and a target-voice profile in Stage 9.
- The pitch target zone stays at 180–220 Hz until Settings in Stage 6.
- The calibration thresholds (quiet ≤ −60 dBFS, too noisy > −48 dBFS, voice at least 15 dB above the room) are first guesses to check on a real iPhone using the debug screen.

---

## Architecture (so far)

```
VoiceBloom/
  App/            App entry point and tab bar
  Audio/          AudioCaptureService (AVAudioSession + AVAudioEngine), lock-free SampleRingBuffer,
                  RecentAudioBuffer + AudioTap (last 30 s, transcriber feed), route detection,
                  microphone permission
  DSP/            AnalysisConfiguration, PitchAnalyzer (YIN), PitchTracker, VoiceStabilityTracker,
                  Decimator (anti-alias FIR → ~12 kHz), LinearPrediction (Levinson–Durbin),
                  PolynomialRoots (Aberth), FormantAnalyzer (LPC → F1–F3), WeightAnalyzer
                  (H1–H2, H1*–H2*, spectral tilt), IntonationAnalyzer (phrases, semitone SD,
                  rises/falls), VoiceQualityAnalyzer (jitter, shimmer, HNR), SignalLevel +
                  NoiseFloorEstimator, SampleFramer, VoiceAnalysisPipeline (the full per-frame
                  chain), PitchMath
  Models/         VoiceFrame, PitchTargetZone, PitchSessionStats, PitchHistory,
                  VoiceReferences (baseline/target scoring), VoiceMeters (rolling meter readings),
                  SlipDetector (+ time-in-target tallies), VoiceQualityTracker (norms, strain)
  Feedback/       FeedbackSettings, FeedbackCues (haptic patterns + chimes as data),
                  HapticsService (Core Haptics), FeedbackOutput
  Services/       NotificationService (daily reminder), KeychainStore, AppLock (Face ID), AppPreferences,
                  BaselineStore, PlacementStore, DataEraser
  Content/        Original reading passages
  Persistence/    SwiftData schema (VoiceBloomSchemaV1: UserProfile, PracticeSession, Recording,
                  LessonProgress, TargetVoiceProfile, ScenarioResult, Achievement, DailyJournalEntry),
                  migration plan, enums stored as raw strings, VoiceBloomDatabase (opens the store)
  Sessions/       SessionSnapshot, SessionStore (save/upsert, delete, check-ins), CheckInRules,
                  PracticeSessionController (autosave, finish, discard, clips, playback),
                  ClipStats + FrameLog, RecordingFileStore (.m4a files), RecordingPlayer
  Transcription/  LiveTranscriber (SFSpeechRecognizer, on-device only), TranscriptAccumulator,
                  TranscriptionService (live transcript state)
  Progress/       ProgressAnalytics (ranges, daily/weekly minutes, heatmap, weekly summary, radar,
                  Then vs Now), ProgressCSV, SampleDataGenerator (debug sample history)
  Features/       Progress (dashboard, Swift Charts trend charts, calendar heatmap, radar chart,
                  Then vs Now, weekly summary, export),
                  Practice (LiveVoiceMonitor, PracticeView, pitch graph, voice meters, % in target,
                  slip/strain banners, voice comfort card, transcript card, Alerts & Feedback,
                  eyes-free practice), History (session list, session detail, check-in),
                  Onboarding (9 steps, placement test, baseline recording), Settings,
                  Calibration (MicCalibration, MicCalibrationModel, MicCalibrationView), Debug, More
  DesignSystem/   Theme colors (light/dark, colorblind-safe) and shared components
VoiceBloomTests/  Swift Testing unit tests for all DSP code, using synthetic tones and synthetic vowels
```

**Audio path:**

1. The microphone feeds an `AVAudioSinkNode`.
2. On the real-time thread, the sink node copies samples into a lock-free ring buffer. That thread never locks or allocates.
3. A background task drains the ring buffer every 5 ms and runs `VoiceAnalysisPipeline` on each 2048-sample frame (512-sample hop):
   - Noise gate, then YIN pitch, then octave-jump, median and smoothing filters.
   - On voiced, stable, clearly audible frames only: decimate to ~12 kHz, then 12-pole LPC for F1–F3, then harmonic levels (Goertzel) for H1–H2 and tilt, corrected for the formants.
   - On every 4th stable frame (no overlap): jitter, shimmer and HNR at the full sample rate.
   - Phrase detection for intonation.
4. Results arrive on the main actor in batches.
5. The graph redraws in sync with the display. The meters take a median over a short window and refresh about 8 times a second.
6. On the main actor, `SlipDetector` watches pitch and resonance, and `VoiceQualityTracker` compares roughness with the user's normal. Alerts go out through `FeedbackOutput` as Core Haptics patterns and chimes on an `AVAudioPlayerNode` in the same engine. Frames recorded while a cue plays are left out of the analysis.
7. The same background task hands each chunk of raw samples, with its time on the frame clock, to `AudioTap`. That keeps the last 30 seconds in memory (for **Save Clip**) and, when the transcript is on, feeds `SFSpeechAudioBufferRecognitionRequest`. Recognition requests are rotated every ~55 seconds so transcripts can run for a whole session. Word timings use the same clock, so a saved clip gets exactly the words spoken in it.

**Sessions:** `LiveVoiceMonitor.sessionSnapshot()` turns the session's running statistics into plain values. `PracticeSessionController` stores them through `SessionStore` (`PracticeSession` is updated in place by id) every 20 seconds, when the app goes to the background, and on Finish.

**Audio session:** category `.playAndRecord`, mode `.measurement` (no automatic gain control or voice processing), options `.defaultToSpeaker` and `.allowBluetoothA2DP`, preferred 48 kHz with 5 ms I/O buffers. Interruptions, route changes, engine configuration changes and media-services resets are all handled.
