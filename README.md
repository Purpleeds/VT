# VoiceBloom

An iPhone app for voice training toward a more feminine (or androgynous) voice. Pitch, resonance, vocal weight and intonation are all measured on the device, and recordings never leave the phone. The full spec is in [SPEC.md](SPEC.md).

**Status:** Stage 1 of 14 is done: project setup, the audio engine, the live pitch graph, a debug screen, and pitch unit tests.

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
   - **Storage:** None (SwiftData is added in Stage 4)
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
| Concurrency errors mentioning Swift 5 | Make sure **Swift Language Version** is 6 on every target. |

---

## What to try on the device (Stage 1)

- **Practice tab:** tap **Start Listening** and allow the microphone. Hold an "aah" and slide your pitch up and down. The graph scrolls through the last 10 seconds, with the 180–220 Hz target zone shaded. The big numbers show your current pitch (Hz and note name) and the percentage of voiced time spent in the target zone.
- **More ▸ Debug & Tuning:** shows raw YIN estimates (grey dots) against the filtered line, input level, the adaptive noise floor and voice gate, sample rate, frame and hop size, DSP time per frame, and dropped samples.
- **Interruptions:** start listening, then trigger Siri or take a call. Listening pauses, and resumes by itself if iOS allows it. Leaving the app pauses too; tap **Resume** when you come back.
- **Bluetooth:** the app only allows Bluetooth for *playback*, so with AirPods connected the iPhone's own mic is still used. If a Bluetooth or car microphone does end up as the input, a warning explains that resonance readings will be unreliable.

The target zone is fixed at the feminine default until Settings (Stage 6). The noise floor adapts automatically until mic calibration (Stage 2).

---

## Architecture (so far)

```
VoiceBloom/
  App/            App entry point and tab bar
  Audio/          AudioCaptureService (AVAudioSession + AVAudioEngine), lock-free SampleRingBuffer,
                  route detection, microphone permission
  DSP/            AnalysisConfiguration, PitchAnalyzer (YIN), PitchTracker (octave-jump rejection,
                  median, smoothing), SignalLevel + NoiseFloorEstimator (voice activity), SampleFramer,
                  LivePitchPipeline (the full per-frame chain), PitchMath
  Models/         PitchFrame, PitchTargetZone, PitchSessionStats, PitchHistory
  Features/       Practice (LivePitchMonitor, PracticeView, pitch graph), Debug, More
  DesignSystem/   Theme colors (light/dark, colorblind-safe) and shared components
VoiceBloomTests/  Swift Testing unit tests for all DSP code
```

**Audio path:**

1. The microphone feeds an `AVAudioSinkNode`.
2. On the real-time thread, the sink node copies samples into a lock-free ring buffer. That thread never locks or allocates.
3. A background task drains the ring buffer every 5 ms and runs `LivePitchPipeline`: 2048-sample frames with a 512-sample hop, a noise gate, YIN, then the tracker.
4. Results arrive on the main actor in batches.
5. The graph redraws in sync with the display through `TimelineView` and `Canvas`. The text readouts refresh about 8 times a second so they stay readable.

**Audio session:** category `.playAndRecord`, mode `.measurement` (no automatic gain control or voice processing), options `.defaultToSpeaker` and `.allowBluetoothA2DP`, preferred 48 kHz with 5 ms I/O buffers. Interruptions, route changes, engine configuration changes and media-services resets are all handled.
