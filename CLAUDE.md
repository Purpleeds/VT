# VoiceBloom
iOS 26+ SwiftUI app. The full spec is in SPEC.md. Read it before starting any work.

## Rules
- Work on ONE build stage at a time (SPEC.md section 21). Don't start the next stage unless asked.
- This environment has no Xcode or iOS SDK, so code can't be compiled here. Be extra careful with Swift 6 concurrency, imports, and API availability so the code compiles first try.
- Put all Swift files inside the VoiceBloom/ folder so Xcode picks them up automatically.
- Write unit tests for all DSP code.
- Things like widgets, Siri Shortcuts extensions, and capabilities (iCloud, background audio) need setup in Xcode. When a stage needs this, give me step-by-step Xcode instructions instead of editing the project file.
- After each stage, update the Progress section below.

## Progress
- Current stage: 3 (not started)
- Completed:
  - Stage 1: project setup, audio engine (AVAudioSinkNode → lock-free ring buffer → background YIN pipeline), live pitch graph, debug screen, pitch/DSP unit tests. Xcode setup steps are in README.md.
  - Stage 2: FormantAnalyzer (decimate to ~12 kHz, pre-emphasis, Hamming, order-12 LPC via Levinson–Durbin, Aberth roots → F1–F3), WeightAnalyzer (Goertzel H1–H2, Iseli–Alwan formant correction, spectral tilt), IntonationAnalyzer (phrases split at 0.35 s pauses, semitone SD, rises/falls), and resonance/weight/intonation meters on Practice. Also: mic calibration flow (5 s noise floor + "aah" level check, saved in UserDefaults), formant/weight/intonation/calibration sections on the debug screen, and tests with synthetic vowels. No extra Xcode setup needed.

## Code conventions (established in Stages 1–2)
- Xcode 26 projects default to `MainActor` isolation. Mark DSP and model types `nonisolated` (struct/enum/final class) so they run off the main thread whatever that setting is. View models are explicitly `@MainActor @Observable`.
- Each file imports what it uses (the Xcode 26 template turns on MemberImportVisibility).
- Do DSP in plain synchronous types and test them with synthetic signals. Test helpers are in `VoiceBloomTests/TestSignal.swift`; `TestSignal.vowel` and `TestVowel` give source–filter vowels with known formants. Prototype numeric expectations before writing the tests (no compiler here).
- `VoiceAnalysisPipeline` turns samples into `VoiceFrame`s (pitch, level, stability, formants, weight, completed phrases). Live audio flows through `AudioCaptureService.samples`, which allows exactly one reader at a time.
- `LiveVoiceMonitor` is the shared live-listening object and is injected with `.environment`. Readings are published about 8 times a second. Features that need every frame (calibration now, slip alerts and recording later) use `addFrameListener`. Scoring is in `Models/VoiceReferences.swift` (baseline → target, 0–100) and `Models/VoiceMeters.swift` (rolling medians).
- Calibration is stored by `MicCalibrationStore` (UserDefaults) until SwiftData arrives in Stage 4.