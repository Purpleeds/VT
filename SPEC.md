Build a complete iPhone app in Swift/SwiftUI called "VoiceBloom" that helps users train their voice to sound more feminine (with an option for an androgynous target). It should feel like a polished App Store app, not a demo.

==================================================
0. REQUIREMENTS
==================================================
- iOS 26+, built with Xcode 26+. Swift 6, SwiftUI, SwiftData, Swift Charts.
- Frameworks: AVFoundation (AVAudioEngine), Accelerate (vDSP for FFT/LPC), Speech, FoundationModels, Core Haptics, WidgetKit, App Intents, LocalAuthentication, UserNotifications, CloudKit (optional sync).
- ALL audio processing happens on-device. Recordings never leave the phone.
- No paid services. The app must work 100% offline (AI features gracefully degrade).

==================================================
1. ONBOARDING AND SETUP
==================================================
Screens, in order:
1. Welcome + short explanation of how voice training works (pitch, resonance, vocal weight, intonation).
2. Health notice: training should never hurt; stop if there is pain or hoarseness.
3. Microphone permission (clear NSMicrophoneUsageDescription) and speech recognition permission.
4. Mic calibration: 5 seconds of silence to measure the room's noise floor, then a short "say aah" to set input level. Warn if the room is too noisy.
5. Goal selection: Feminine (default target 180–220 Hz) or Androgynous (150–180 Hz), or Custom. Explain targets can change later and can also be set from a target voice clip.
6. Experience level: Beginner / Some training / Experienced. "Some training" and "Experienced" offer a 5-minute placement test (pitch match, resonance hold, reading passage) that can unlock later lesson phases.
7. Daily goal: 10, 15, 20, or 30 minutes, plus a reminder time.
8. Baseline recording: read a short passage (write original passages, do not use copyrighted text) + 30 seconds of free speech. Save as the "Day 1" recording.
9. Optional: enable Face ID lock and AI Coach.

==================================================
2. AUDIO ENGINE AND ACCURACY
==================================================
- AVAudioSession category .playAndRecord, mode .measurement (disables automatic gain control and voice processing so analysis is accurate). Options: .defaultToSpeaker, .allowBluetoothA2DP.
- Sample rate 48 kHz. Analysis frame 2048 samples, hop 512 (~10 ms updates).
- Detect the input route. If a Bluetooth headset mic (e.g. AirPods) is used, show a warning: Bluetooth mics record at low quality and make resonance readings unreliable. Recommend the built-in mic or wired headphones.
- Handle interruptions (phone calls, Siri), route changes, and app backgrounding without crashing; pause and resume cleanly.
- Voice activity detection: ignore frames below the calibrated noise floor + margin.

PITCH (F0)
- YIN algorithm, search range 60–500 Hz, threshold ~0.12.
- Median filter (5 frames) + exponential smoothing for display.
- Reject octave jumps (sudden doubling/halving) unless sustained for 3+ frames.

RESONANCE (FORMANTS)
- Downsample to ~11 kHz, pre-emphasis filter, Hamming window.
- LPC order ~12–14, solve with Levinson-Durbin, find roots to get F1, F2, F3.
- Only measure formants on voiced, stable frames.
- Resonance score (0–100): based mainly on average F2 (and F3), scaled between the user's own baseline and the target value. Default target uses typical adult female averages from published vowel studies (e.g. F2 for "ee" roughly 2700–2800 Hz vs roughly 2300 Hz for adult male averages). If a target voice profile exists, use its values instead.

VOCAL WEIGHT
- Measure H1–H2 (amplitude difference between first and second harmonics) and overall spectral tilt.
- Weight score (0–100, "heavy" to "light"), scaled between baseline and target.

INTONATION
- Pitch variability per sentence (standard deviation in semitones) and number of rises/falls.
- Score how "melodic" speech is compared to the target.

==================================================
3. LIVE PRACTICE SCREEN
==================================================
- Scrolling pitch graph (last 10 seconds) with shaded target zone.
- Current pitch (Hz + note name), resonance meter, weight meter, intonation meter.
- Big "% in target" number for the current session.
- SLIP ALERTS: if pitch or resonance drops back to the old range for more than 2 seconds, give a gentle haptic tap (Core Haptics) and a subtle on-screen color change. Users can turn off haptic, sound, or visual alerts separately.
- "Eyes-free" mode: practice without looking at the screen, using only haptics and optional soft tones.
- Pause/resume, and a one-tap "save this as a recording" button.
- Live transcript (Speech framework) shown below the graph when doing reading or scenario practice.

==================================================
4. VOICE QUALITY AND STRAIN MONITORING
==================================================
- Track jitter (%), shimmer (%), and harmonics-to-noise ratio (HNR, dB) during each session.
- Compare against the user's own normal values. If roughness clearly increases during a session (e.g. 30%+ above their normal), show: "Your voice sounds tired. Take a break."
- After every session: quick check-in — "How did your throat feel?" (Fine / A bit tired / Sore) and "How natural did your voice feel?" (1–5).
- If "Sore" is chosen twice in 3 days, suggest a rest day and recommend seeing a doctor or speech-language pathologist if it continues.
- Clearly label these as rough indicators from a phone mic, NOT a medical diagnosis.

==================================================
5. SESSION STRUCTURE
==================================================
Every guided session follows this template:
- Warm-up (2–3 min): lip trills, humming, gentle sirens.
- Main practice (8–15 min): the current lesson's exercises.
- Real-speech carryover (2–3 min): reading or a scenario using that skill.
- Cool-down (1–2 min): gentle humming downward, yawn-sighs, relaxed breathing.
Session lengths: Quick (5 min), Standard (15 min), Deep (25 min).
Recommend several short sessions a day over one long session. Soft cap: 45 minutes per day.

==================================================
6. LESSON PLAN (16 WEEKS)
==================================================
- Store all lessons in a JSON file for easy editing.
- Each lesson: title, explanation, why it matters, step-by-step instructions, timed exercises, measurable goal, common mistakes, and "how it should feel" notes.
- A week unlocks when the user completes 5+ sessions in the previous week AND meets its goal. Any week can be repeated. Users can stay on a week as long as needed.

PHASE 1 — FOUNDATIONS (Weeks 1–2)
- Week 1: Breathing (diaphragmatic), relaxed jaw/tongue/throat, warm-up routine. Learn what each meter means.
  Goal: 5 warm-up sessions completed.
- Week 2: Pitch awareness — match reference tones, slow glides, find current speaking average.
  Goal: match 8/10 tones within ±10 Hz.
  Mistake: pushing volume up when going higher.

PHASE 2 — RESONANCE (Weeks 3–6)
- Week 3: Larynx awareness — "big dog / small dog" panting, whisper-siren, feeling the larynx rise without squeezing.
- Week 4: Bright vowels — sustain "ee," "ih," "ay" in the bright zone.
- Week 5: Bright resonance on single words, then short phrases.
- Week 6: Full sentences with resonance focus (pitch not scored).
  Goal by Week 6: resonance in bright zone for 70%+ of a reading passage.
  Mistake: throat tension, nasal sound, or pitch rising instead of resonance.

PHASE 3 — PITCH (Weeks 7–9)
- Week 7: Raise speaking pitch gradually (about +10–20 Hz above baseline per step, never jumping to the final target).
- Week 8: Combine pitch + resonance on sentences.
- Week 9: Stability — full paragraphs in the target zone.
  Goal: 70%+ time in target zone with bright resonance and no strain reports.
  Mistake: using falsetto or a "breathy squeak."

PHASE 4 — VOCAL WEIGHT (Weeks 10–11)
- Week 10: Lighter vocal fold contact — gentle onsets, breathy-to-clear slides, soft speaking.
- Week 11: Combine light weight with pitch + resonance.
  Goal: weight meter in the "light" range for 60%+ of a passage.
  Mistake: becoming too breathy and quiet to be heard.

PHASE 5 — INTONATION AND EXPRESSION (Weeks 12–13)
- Week 12: Melodic speech — rising/falling patterns, word emphasis, wider pitch variety.
- Week 13: Non-speech sounds — laughing, sighing, coughing softly, "mm-hmm," surprise, agreement.

PHASE 6 — REAL-WORLD USE (Weeks 14–16)
- Scenario practice (see section 7), speaking louder without dropping into the old voice, practicing when tired.
- Week 16: re-record the Day 1 baseline for "Then vs Now."

AFTER WEEK 16 — MAINTENANCE MODE
- Daily 5–10 minute routines mixing all skills, weekly scenario challenges, and an AI-suggested focus area.

==================================================
7. SCENARIO PRACTICE
==================================================
The app shows a scenario, the user speaks, and each turn is scored for pitch, resonance, weight, intonation, and consistency.
Scenarios (each with Easy / Medium / Hard versions):
- Ordering coffee or food at a counter
- Answering a phone call and leaving a voicemail
- Introducing yourself to someone new
- Asking a shop assistant for help
- Making a complaint or returning an item
- Casual chat with a friend (2 minutes, open-ended)
- Reading a story aloud with expression
- Giving a 1–2 minute presentation
- Emotional reactions (excited, annoyed, laughing, surprised)
- Calling someone across a room (louder voice)
- End-of-day "tired voice" practice
With AI enabled, the AI plays the other person (see section 10). Without AI, use pre-written dialogue scripts.

==================================================
8. TOOLS AND EXERCISE LIBRARY
==================================================
- Exercise library: every exercise searchable and playable on its own, with filters by skill (pitch, resonance, weight, intonation, warm-up).
- Reference tone generator + mini piano keyboard (AVAudioEngine tone synthesis) to hear target notes.
- Daily Sentence Journal: the user records the same sentence every day; build a timeline to scrub through and hear progress.
- Quick Check: a 10-second reading that gives today's pitch/resonance/weight snapshot.
- Discreet Mode: quiet exercises (whisper resonance, silent larynx awareness, very soft humming) for when others are nearby; reference tones play through headphones only.
- Voice Preview (ADVANCED, build last): take a user recording, apply pitch and formant shifting to give a rough preview of what the target could sound like. Clearly labeled as an approximation.

==================================================
9. TARGET VOICE UPLOAD
==================================================
- Import MP3, M4A, WAV, MP4, MOV from Files (UTType.audio, UTType.movie) or videos from Photos (PhotosPicker).
- Extract audio from videos with AVAsset / AVAssetReader.
- Waveform view with drag handles to trim the section to analyze (recommend 10–60 seconds of clear, solo speech).
- Warn if the clip has music, background noise, or multiple speakers.
- Generate a Target Voice Profile: average pitch, pitch range, pitch histogram, average F1/F2/F3, weight estimate, intonation variability.
- Option to use the profile to set targets automatically (keep manual override).
- Compare to Target: overlay user and target pitch histograms and formants, with a % match for each category.
- Shadowing exercise: play a short segment of the target, user repeats, show both pitch contours on top of each other.
- Save multiple profiles and switch between them.
- Note in UI: the target is a guide, not something to copy exactly; aim for a voice that feels natural and comfortable.

==================================================
10. AI COACH (FREE ONLY)
==================================================
Priority order:
1. Apple Foundation Models (on-device, free, no API key). Check SystemLanguageModel.default.availability. Use LanguageModelSession and @Generable/@Guide structs for structured output.
2. Optional Google Gemini API free tier, ONLY if on-device AI is unavailable AND the user turns it on and pastes their own key (stored in Keychain, never hardcoded). Only send text stats and transcripts, never audio. Show a clear notice about what is sent.
3. Rule-based coach (preset tips based on stats) so the app always works without AI.

AI features:
- Post-session feedback: 2–3 specific tips + one recommended exercise, based on session stats and trends vs the last 5 sessions.
- Scenario partner: AI plays the barista/caller/friend for 4–6 turns. AI lines shown on screen and optionally spoken with AVSpeechSynthesizer. User's replies transcribed with SpeechAnalyzer/SpeechTranscriber.
- Weekly review: suggests moving on, repeating a week, or extra practice for a weak skill.
- Practice text generator: fresh reading passages targeting specific sounds and difficulty.
- Ask the Coach chat: safe, general vocal training advice only. System instructions must: never encourage straining or pushing through pain, recommend a speech-language pathologist for pain or lasting problems, keep answers short and supportive.
- AI toggle in Settings to turn everything off.

==================================================
11. TRAINING HISTORY AND GRAPHS
==================================================
Progress tab (Swift Charts, custom SwiftUI drawing where Charts can't do it):
- Average pitch over time with target zone shaded
- Resonance, weight, and intonation scores over time (toggle each line)
- % time in target per session
- Practice minutes per day/week (bar chart)
- Calendar heatmap of practice days (custom grid)
- Scenario scores radar chart (custom drawn with SwiftUI Path)
- Strain/comfort check-in history
- Time ranges: 7 days, 30 days, 90 days, all time
- Tap any point to open that session's details and recording
- "Then vs Now": play baseline and latest recording back to back with stats side by side
- Weekly summary card (best day, biggest improvement, area to focus on)
- Export: CSV of all stats, and share a progress image

==================================================
12. MOTIVATION
==================================================
- Streak counter with 1 "streak freeze" per week (so a rest day for vocal health doesn't break the streak).
- Achievements (first session, 7-day streak, first week finished, 50% then 80% in target, first scenario, etc.).
- Daily challenge (one short, varied task each day).
- Pitch game: a simple mini-game controlled by voice (e.g. guide a balloon through gaps by holding pitch and resonance). Scores saved.
- Local notification reminders at the user's chosen time; smart nudge if they haven't practiced by evening. No guilt-tripping language.
- Home screen and Lock Screen widgets (WidgetKit): streak, today's minutes vs goal, quick-start button.
- App Intents / Siri Shortcuts: "Start voice practice," "Do a Quick Check."

==================================================
13. PRIVACY AND SECURITY
==================================================
- Optional Face ID / passcode lock (LocalAuthentication).
- Blur app contents in the app switcher.
- Option to use a neutral app name and icon on the home screen (alternate app icons).
- Notifications use neutral wording by default (e.g. "Time for practice").
- All data stored locally with SwiftData; optional iCloud sync via CloudKit private database (free).
- Manual backup/restore to a file.
- "Delete all data" button with confirmation.
- No analytics, no tracking, no ads.

==================================================
14. VOCAL HEALTH CENTER
==================================================
- Articles: how the voice works, safe training habits, hydration, rest, signs of strain, why falsetto/forcing pitch is risky, when to see a speech-language pathologist.
- Daily soft limit (45 min) with break suggestions.
- Rest day suggestions after strain reports.

==================================================
15. ACCESSIBILITY
==================================================
- Full VoiceOver labels, including spoken descriptions of graph values.
- Dynamic Type support everywhere.
- Colorblind-safe palettes; never use color alone to show meaning (add labels/patterns).
- Respect Reduce Motion.
- Haptic feedback alternatives for visual cues.

==================================================
16. SETTINGS
==================================================
- Target zones (pitch, resonance, weight), or use a target voice profile
- Display units: Hz, note names, or both
- Slip alert sensitivity and type (haptic/sound/visual)
- Re-run mic calibration and placement test
- Daily goal, reminder time, session length default
- AI Coach settings (on/off, provider, API key)
- Privacy settings, iCloud sync, backup, delete data
- Theme: system/light/dark

==================================================
17. DESIGN AND NAVIGATION
==================================================
- Calm, modern, soft color palette, full dark mode.
- Large, glanceable meters readable at arm's length.
- Tab bar: Practice, Lessons, Target Voice, Progress, More (Health Center, Tools, Settings).
- Smooth animations for meters (no lag behind the audio).
- Empty states with friendly guidance (e.g. no sessions yet).

==================================================
18. DATA MODEL (SwiftData)
==================================================
- UserProfile: goal type, targets, baseline values, experience level, settings
- Session: id, date, duration, type, lesson id, avg/min/max pitch, % in target, resonance, weight, intonation, jitter, shimmer, HNR, comfort rating, naturalness rating, AI feedback text
- Recording: id, session id, file URL, transcript, stats
- LessonProgress: week, sessions completed, goal met, unlocked date
- TargetVoiceProfile: name, pitch stats, histogram, formants, weight, intonation, source clip URL
- ScenarioResult: scenario id, difficulty, per-turn scores, transcript
- Achievement: id, unlocked date
- DailyJournalEntry: date, recording, stats

==================================================
19. ARCHITECTURE AND CODE QUALITY
==================================================
- MVVM with services: AudioCaptureService, PitchAnalyzer, FormantAnalyzer, WeightAnalyzer, VoiceQualityAnalyzer, IntonationAnalyzer, TranscriptionService, TargetVoiceImporter, LessonManager, ScenarioEngine, AICoachService (protocol with FoundationModels, Gemini, and RuleBased implementations), ProgressStore, HapticsService, NotificationService.
- All DSP off the main thread using Swift concurrency; use Accelerate/vDSP for speed.
- Keep the UI at 60fps during live analysis.
- Clear comments in all DSP code explaining each step.
- No force unwraps; handle all errors with user-friendly messages.

==================================================
20. TESTING
==================================================
- Unit tests for PitchAnalyzer using generated sine waves and sawtooth waves at known frequencies (should be within ±2 Hz).
- Unit tests for FormantAnalyzer using synthetic vowel signals.
- Tests for lesson unlock logic and score calculations.
- A debug screen showing raw pitch, formants, and noise floor for tuning on a real device.

==================================================
21. BUILD STAGES
==================================================
Build ONE stage at a time. Each stage must compile and run on a real iPhone before moving on. Give complete files and Xcode setup steps for each stage.
1. Project setup, audio engine, live pitch graph, debug screen, pitch unit tests
2. Resonance, weight, and intonation meters + mic calibration
3. Slip alerts, haptics, voice quality/strain monitoring
4. SwiftData models, session saving, recordings, check-ins
5. Progress tab and all graphs
6. Onboarding, placement test, settings
7. Lesson system (JSON content for all 16 weeks) and session structure
8. Tools: exercise library, tone generator, daily journal, Quick Check, Discreet Mode
9. Target voice upload, profile, compare, shadowing
10. Scenarios (scripted)
11. AI Coach (FoundationModels → Gemini fallback → rule-based)
12. Motivation: streaks, achievements, pitch game, notifications, widgets, Siri Shortcuts
13. Privacy features, iCloud sync, backup/restore, accessibility pass
14. Voice Preview (advanced) and final polish
15. Pitch Track generation (22.1) + gameplay screen (22.2) + scoring (22.4) + built-in tracks
16. Recording with save/discard (22.3), review (22.5), track library and history (22.6), data model (22.8)
(Section 22's optional Stage 17, on-device vocal isolation for clips with background music, is covered by section 23's splitter: Stages 17 and 18 below.)
17. Splitter with the BASIC engine: SeparationService protocol, splitter screen, preview mixer, save/export/discard (including video audio replacement), storage screen, and all integrations from 23.4
18. HIGH QUALITY engine: convert and add the ML model, chunked processing, Fast/Best settings, automatic fallback

Start with Stage 1 now.

==================================================
22. PITCH TRACK MODE (MATCH THE BARS)
==================================================
A game-style practice mode where bars scroll across the screen and the user must match their pitch (and resonance and weight) to them, like a karaoke singing game. Tracks can be generated automatically from any uploaded audio or video.

--------------------------------------------------
22.1 AUTO TRACK GENERATION FROM UPLOADS
--------------------------------------------------
- Import MP3, M4A, WAV, MP4, MOV from Files or Photos. Extract audio from videos with AVAssetReader.
- Reuse the import/trim UI from section 9. Any clip imported in the Target Voice tab gets a "Make a Pitch Track" button, and vice versa.
- Show a progress screen while processing ("Detecting pitch… Measuring resonance… Building track…") with a cancel button. Process off the main thread.

AUTO-DETECTION
- Detect clip type automatically: SPEECH or SINGING, based on pitch stability, how well pitches snap to musical semitones, and voiced-to-unvoiced ratio. Show the result with a manual override.
- Detect background music. If found:
  - Optional on-device vocal isolation using an open-source source-separation model (e.g. Demucs, MIT licensed) converted to Core ML. Mark this ADVANCED/OPTIONAL and build it last; the app must work without it.
  - Otherwise warn that music will reduce accuracy and recommend clips with clear solo voice.
- Detect multiple speakers and warn.

ANALYSIS (reuse analyzers from section 2)
- Full pitch contour (10 ms frames).
- SINGING clips: segment into notes (stable pitch regions longer than ~80 ms), snap each to the nearest semitone, and merge tiny gaps.
- SPEECH clips: keep the natural pitch contour, grouped into syllable/word segments, drawn as curved bars instead of flat ones.
- For each segment, store: start time, duration, pitch (Hz and note), resonance (F1/F2/F3 and score), weight score, loudness.
- Transcribe with SpeechAnalyzer (word timestamps) and show words under the bars (for speech especially; for songs, show if transcription confidence is good enough).
- Detect the track's overall pitch range and compare it to the user's comfortable range (from their history). If it's outside, suggest transposing.

TRACK SETTINGS (editable before playing)
- Transpose: −12 to +12 semitones, plus an "Auto-fit to my range" button.
- Speed: 50%–100% (time-stretch with AVAudioUnitTimePitch, pitch unchanged).
- Loop a section: drag to select start/end.
- Difficulty (pitch tolerance): Easy ±100 cents, Medium ±50 cents, Hard ±25 cents.
- Score resonance and weight: on/off (on by default for speech tracks).
- Audio during play: Original audio, Guide tones only (synthesized notes), or Silent (bars only).
- Saved as a Track the user can rename, replay, and delete.

BUILT-IN TRACKS (so the mode works without uploads)
- Generated exercises: sirens, slides, 5-note scales, arpeggios, held notes in the target zone, and speech intonation patterns (questions rising, statements falling, excited speech) built around the user's current target zone.

--------------------------------------------------
22.2 GAMEPLAY SCREEN
--------------------------------------------------
- Landscape and portrait supported.
- Vertical axis = pitch (semitone grid lines with note names). Horizontal = time, scrolling right to left.
- Fixed "now" line at about 25% from the left.
- Target bars: pitch shown by vertical position, length by duration. Bar outline color shows its resonance target (darker to brighter), and a thin inner line shows weight target.
- User's live pitch is a glowing dot with a short trail.
- Feedback while playing:
  - Bar fills in as the user hits it (fill amount = accuracy)
  - Color: green (on), yellow (close), red (off), with an arrow hinting "go higher / go lower"
  - Small resonance and weight meters at the side
  - Combo counter for consecutive hits
  - Optional haptic tap on a perfect hit
- 3-second countdown before starting. Pause button (pause freezes the track and the recording).
- REQUIRED: recommend headphones before starting when audio is set to Original or Guide tones, so the mic doesn't pick up the track. If no headphones are connected, warn and offer Silent mode.
- LATENCY: Bluetooth headphones add delay. Add a latency calibration (tap along to a beat, or auto-measure) and a manual offset slider in Settings; apply the offset to scoring.

--------------------------------------------------
22.3 RECORDING, SAVE OR DISCARD
--------------------------------------------------
- Record the user's microphone input during every attempt (voice only, separate from the backing audio).
- On completion (or if the user stops early), show the Results screen with:
  - Play my take / Play my take with the original / Play original only
  - SAVE button: saves the recording, scores, and review as an Attempt, linked to a Session so it appears in Progress graphs (section 11)
  - DISCARD button: asks "Discard this attempt?" then deletes the recording. Scores are not saved.
  - RETRY button: discards and restarts immediately (with confirmation)
- If the app is closed during the results screen, keep the attempt as an unsaved draft and ask again next time it opens.

--------------------------------------------------
22.4 SCORING
--------------------------------------------------
Per bar and overall (0–100):
- Pitch accuracy: average cents off, within the difficulty tolerance
- Pitch stability: how steady the pitch is on held notes
- Timing: how close the start of each note is to the bar start (after latency offset)
- Resonance match (if enabled): user F2/F3 vs bar target
- Weight match (if enabled): user weight score vs bar target
- Overall score = weighted average, plus a 1–5 star rating
- Also track: % bars hit, longest combo, highest and lowest notes reached comfortably

--------------------------------------------------
22.5 REVIEW AFTER COMPLETION
--------------------------------------------------
The Results screen includes a full review:

VISUAL BREAKDOWN
- Graph of target pitch vs the user's pitch over the whole track, with misses highlighted.
- Section-by-section breakdown (split the track into ~5–10 second sections) with a score for each.
- Tap any section to replay that part of the take, or jump straight into a loop practice of that section.

WRITTEN REVIEW
Structure every review as:
1. Overall summary (1–2 sentences)
2. What went well (1–3 specific points with timestamps)
3. What to improve: the top 3 issues, each with:
   - WHAT happened, with specific numbers and timestamps (e.g. "From 0:32 to 0:41 you were about 40 cents flat on the high notes")
   - WHY it probably happened (e.g. "pitch tends to drop when resonance darkens")
   - HOW to fix it: a specific technique, plus a button linking to a matching exercise from the exercise library (section 8)
4. Next step: recommended settings for the next attempt (e.g. "Try 75% speed on section 3" or "Transpose down 2 semitones")
5. Comparison with the previous attempts on this track ("Pitch accuracy up 12 points since last time")
6. Health note if strain indicators (section 4) rose during the attempt

HOW THE REVIEW IS GENERATED
- Use the AICoachService from section 10 (Foundation Models → Gemini free tier → rule-based).
- Send only the numbers: per-section scores, problem timestamps, pitch/resonance/weight errors, track type, difficulty, and previous attempt scores. Never send audio.
- Use a @Generable struct for the review so it always has the same sections.
- Rule-based fallback must produce the same structure from preset rules (e.g. consistently flat on high notes → suggest slides and resonance brightening; late timing → suggest slower speed; weight too heavy → suggest light onset exercises).
- Keep the tone encouraging and specific. Never encourage pushing through strain.

--------------------------------------------------
22.6 TRACK LIBRARY AND HISTORY
--------------------------------------------------
- Track library: built-in and uploaded tracks, with best score, last played, and number of attempts.
- Each track has an attempts list (saved attempts only): date, score, stars, play the recording, view the review.
- Graph of scores over time for each track.
- Pitch Track scores also feed the main Progress tab.

--------------------------------------------------
22.7 SPEECH vs SINGING NOTE
--------------------------------------------------
- Show a short in-app note: singing and speaking use the voice differently, and singing high does not automatically make the speaking voice sound more feminine. Speech tracks are the most useful for everyday voice goals; singing tracks are great for pitch control and range.

--------------------------------------------------
22.8 DATA MODEL ADDITIONS (SwiftData)
--------------------------------------------------
- PitchTrack: id, name, source file URL, type (speech/singing/built-in), duration, transpose, speed, difficulty, scoring options, audio mode, detected range, created date
- TrackSegment: track id, start, duration, pitch Hz, note, resonance target, weight target, loudness, word text
- TrackAttempt: id, track id, session id, date, recording URL, per-section scores, overall scores, stars, review (structured), saved flag

--------------------------------------------------
22.9 TESTING
--------------------------------------------------
- Unit tests for note segmentation using generated audio with known notes and gaps.
- Unit tests for speech/singing detection using synthetic examples.
- Unit tests for scoring with fake pitch data (perfect, flat, late, off-key).
- Debug option to play a track with a simulated "perfect" voice to check scoring gives ~100.

==================================================
23. VOCAL / BACKING SPLITTER
==================================================
Lets the user split any imported song or video into separate VOCALS and BACKING (instrumental) tracks, then play, mix, export, or use either part elsewhere in the app. All processing is on-device and free.

--------------------------------------------------
23.1 SEPARATION ENGINES
--------------------------------------------------
Two engines behind a SeparationService protocol:

1. HIGH QUALITY (machine learning)
- Use an open-source music source-separation model with a permissive license (e.g. Demucs or Spleeter, both MIT) converted to Core ML. Check the license before using any model.
- 2-stem output: vocals + accompaniment.
- Process audio in overlapping chunks (e.g. 10 s chunks, 1 s overlap, crossfaded) to keep memory low and avoid crashes on long songs.
- Run on the Neural Engine/GPU (MLComputeUnits.all). Fall back to CPU if needed.
- Quality setting: Fast (single pass) or Best (extra pass / larger model if available).
- If the model file is missing or the device can't run it, fall back to engine 2 automatically and tell the user.

2. BASIC (no model, works on every device)
- Stereo only: vocals are usually panned to the center, so:
  - Backing ≈ left minus right (center cancellation), with a low-frequency restore so bass and kick drum aren't lost
  - Vocals ≈ mid channel with the extracted backing subtracted, plus a vocal-range band-pass filter (~100 Hz–8 kHz)
- Use vDSP for speed.
- Label clearly as "Basic quality": works best on studio songs with centered vocals, and won't work on mono files (detect mono and explain).

--------------------------------------------------
23.2 SPLITTER SCREEN
--------------------------------------------------
- Entry points: a "Split vocals / backing" button on any imported clip (Target Voice tab, Pitch Track import, and a Splitter tool in More > Tools).
- Choose output: Vocals only, Backing only, or Both.
- Choose engine: High Quality or Basic (default High Quality when available).
- Progress screen with percentage, estimated time left, and cancel. Keep processing if the screen locks briefly (request extra background time); warn that very long songs may take several minutes and use battery.
- Detect if the clip has no music (e.g. plain speech) and tell the user splitting isn't needed.

PREVIEW AND MIXER
- Waveforms for Vocals and Backing, stacked.
- Play/pause, scrub, loop selection.
- Solo / mute buttons for each part, and a volume slider for each (0–150%).
- A/B toggle to instantly compare original vs vocals vs backing.
- "Clean up" options for vocals: noise gate and light de-reverb (simple, optional).

--------------------------------------------------
23.3 SAVE, EXPORT, AND DISCARD
--------------------------------------------------
- Save stems to the app's library (SeparatedTrack model) so they never need reprocessing.
- Export options via share sheet / Save to Files:
  - Vocals only (M4A or WAV)
  - Backing only (M4A or WAV)
  - Custom mix from the mixer sliders (M4A or WAV)
  - For VIDEO sources: export the original video with its audio replaced by vocals only, backing only, or the custom mix (AVMutableComposition + AVAssetExportSession), keeping the video untouched.
- Discard button (with confirmation) deletes the stems.
- Storage screen in Settings: list saved stems with file sizes, delete individually or all.
- Small note in the UI: separated audio is for personal practice; respect the rights of the original creators when sharing.

--------------------------------------------------
23.4 INTEGRATION WITH OTHER FEATURES
--------------------------------------------------
- PITCH TRACK MODE (section 22):
  - When a clip has music, offer "Split first for best results." Bars are generated from the isolated VOCALS.
  - New audio option during play: "Backing only (karaoke)", where the user sings/speaks over the instrumental while matching the bars. This becomes the default for split songs.
  - Keep "Original," "Vocals only," "Guide tones," and "Silent" as other options.
  - Results screen: "Play my take with the backing" mixes the user's recording with the instrumental.
- TARGET VOICE (section 9): analyze the isolated vocals instead of the full mix for much more accurate pitch, resonance, and weight profiles.
- Record over backing: a simple mode where the user records themselves over the backing track (no bars, no scoring), then saves/discards and can export the mix.

--------------------------------------------------
23.5 DATA MODEL ADDITIONS
--------------------------------------------------
- SeparatedTrack: id, source file URL, source type (audio/video), engine used, quality, vocals file URL, backing file URL, duration, file sizes, created date
- Link PitchTrack and TargetVoiceProfile to an optional SeparatedTrack

--------------------------------------------------
23.6 TESTING
--------------------------------------------------
- Unit tests for the Basic engine using synthetic stereo audio (a centered tone + side-panned tones): backing should strongly reduce the centered tone.
- Test chunk crossfading produces no clicks at chunk boundaries.
- Test mono detection, cancel mid-process, and low-storage handling.
- Debug screen showing processing time per chunk and memory use.
