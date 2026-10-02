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
- Current stage: 2 (not started)
- Completed:
  - Stage 1: project setup, audio engine (AVAudioSinkNode → lock-free ring buffer → background YIN pipeline), live pitch graph, debug screen, pitch/DSP unit tests. Xcode setup steps are in README.md.

## Code conventions (established in Stage 1)
- Xcode 26 projects default to `MainActor` isolation. Mark DSP and model types `nonisolated` (struct/enum/final class) so they run off the main thread whatever that setting is. View models are explicitly `@MainActor @Observable`.
- Each file imports what it uses (the Xcode 26 template turns on MemberImportVisibility).
- Do DSP in plain synchronous types such as `LivePitchPipeline`, and test them with synthetic signals (`VoiceBloomTests/TestSignal.swift`). Live audio flows through `AudioCaptureService.samples`, which allows exactly one reader at a time.
- `LivePitchMonitor` is the shared live-listening object and is injected with `.environment`. Stage 2 meters should hang off the same pipeline and frames.