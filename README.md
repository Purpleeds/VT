# VoiceBloom

An iPhone app for voice training toward a more feminine (or androgynous) voice. Pitch, resonance, vocal weight and intonation are all measured on the device, and recordings never leave the phone. The full spec is in [SPEC.md](SPEC.md).

**Status:** Stages 1–12 of 14 are done:
- **Stage 1:** project setup, the audio engine, the live pitch graph, a debug screen, and pitch tests.
- **Stage 2:** resonance, weight and intonation meters, plus microphone calibration.
- **Stage 3:** slip alerts (haptic, sound, visual), eyes-free practice, the "% in target" display, and voice-quality and strain monitoring.
- **Stage 4:** SwiftData storage, automatic session saving, "save this as a recording" with playback, live on-device transcripts, and the post-session check-in with rest-day advice.
- **Stage 5:** the Progress tab: trend charts, practice calendar, check-in history, scenario radar, Then vs Now, weekly summary, CSV export and a shareable progress image.
- **Stage 6:** first-launch onboarding (9 steps, with the placement test and the Day 1 baseline recording) and the Settings screen.
- **Stage 7:** the 16-week lesson plan (all content in `Lessons.json`), guided sessions (warm-up, main practice, carryover, cool-down) in Quick/Standard/Deep lengths, unlock rules, and maintenance mode.
- **Stage 8:** Tools: the searchable exercise library, a reference tone generator with a mini piano, the Daily Sentence Journal with a timeline, Quick Check, and Discreet Mode.
- **Stage 9:** Target Voice: import audio or video from Files or Photos, trim it on a waveform, quality warnings, a Target Voice Profile, automatic targets, Compare to Target, shadowing, and several saved profiles.
- **Stage 12:** motivation: streaks with a weekly streak freeze, achievements, a daily challenge, the balloon pitch game, an evening nudge, Home Screen and Lock Screen widgets, and Siri shortcuts.
- **Stage 13:** privacy (app lock, app-switcher cover, a neutral app icon, neutral notification wording, backup/restore to a file, delete all data), the Vocal Health Center (articles, a 45-minute daily soft limit with break suggestions, rest suggestions) and an accessibility pass. iCloud sync is left out: it needs a paid Apple Developer account.
- **Stage 11:** the AI Coach: Apple's on-device model, optional Gemini with your own key, or simple built-in tips; post-session feedback, an AI scenario partner, weekly review, practice texts and Ask the Coach.
- **Stage 10:** scenario practice: 11 everyday situations at Easy, Medium and Hard with pre-written scripts, each turn scored, results saved for the Progress radar.

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

### 7. Widgets, App Group and Siri shortcuts (Stage 12)

The GitHub build already includes all of this (it comes from `project.yml`). If you build in Xcode yourself:

1. **Add the widget target:** **File ▸ New ▸ Target… ▸ Widget Extension**. Product name `VoiceBloomWidget`, untick **Include Live Activity**, **Include Control** and **Include Configuration App Intent**, click **Finish**, and **Activate** the scheme if asked. Xcode sets the bundle ID to `com.williamzhao.voicebloom.VoiceBloomWidget`; that's fine.
2. **Use the repo's widget code:** delete the Swift files Xcode generated in the new `VoiceBloomWidget` group (Move to Trash), then drag `VoiceBloomWidget/VoiceBloomWidget.swift` from the repo into that group with only the **VoiceBloomWidget** target ticked.
3. **Share two app files with the widget:** select `VoiceBloom/Shared/WidgetSnapshot.swift` and `VoiceBloom/Shared/LaunchIntents.swift`, open the File inspector (right sidebar) and tick **VoiceBloomWidget** under **Target Membership** (keep **VoiceBloom** ticked).
4. **Match the settings:** select the **VoiceBloomWidget** target ▸ **General**: Minimum Deployments **iOS 26.0**. **Build Settings**: Swift Language Version **Swift 6**, Default Actor Isolation **MainActor**, Approachable Concurrency **Yes**.
5. **Add the App Group to the app:** select the **VoiceBloom** target ▸ **Signing & Capabilities** ▸ **+ Capability** ▸ **App Groups**, click **+**, enter `group.com.williamzhao.voicebloom`, and make sure it's ticked.
6. **Add the same App Group to the widget:** select the **VoiceBloomWidget** target ▸ **Signing & Capabilities** ▸ choose the same Team ▸ **+ Capability** ▸ **App Groups** ▸ tick `group.com.williamzhao.voicebloom`.
7. **Siri shortcuts** need no setup: they're declared in `VoiceBloom/App/AppShortcuts.swift`. After installing, say "Start voice practice in VoiceBloom" or "Do a Quick Check in VoiceBloom", or find them in the Shortcuts app.
8. Build and run the **VoiceBloom** scheme, then long-press the Home Screen ▸ **Edit ▸ Add Widget** ▸ VoiceBloom.

If the App Group is missing (for example with some sideloading tools), the widgets show "Open the app to start" instead of your numbers; everything else still works.

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

**Stage 13** (privacy, vocal health, accessibility):
- **Settings ▸ Privacy & data:**
  - **Lock with Face ID** (from Stage 6) covers the app until you unlock it.
  - **Hide in app switcher** (on by default) shows a plain screen instead of your data when you swipe between apps.
  - **Notification wording:** *Neutral* (the default: "Time for practice") or *Mention voice practice*. Pending reminders are rescheduled with the new words.
  - **App icon:** switch to a plain grey "list" icon; iOS confirms with an alert. iOS doesn't let apps change the name under the icon, so the screen explains how to make a Shortcuts bookmark with any name and icon instead.
  - **Backup & restore:** back up everything (sessions, check-ins, lessons, target voices, scenario results, journal, achievements, settings, and optionally the recordings) to one `.json` file you save anywhere in Files. Restore shows what's in a file before replacing anything. The Gemini key and mic calibration are never in a backup.
  - **Delete all data** now also removes notifications, the widget data and the alternate icon.
- **More ▸ Vocal Health Center:** today's practice against the 45-minute soft limit, a rest suggestion after sore check-ins or repeated strain warnings, the last 7 days' check-ins and strain warnings, and seven short articles (how the voice works, safe habits, hydration, rest, signs of strain, why forcing pitch or falsetto is risky, when to see a speech-language pathologist).
- **Break suggestions on Practice:** a banner with a gentle tap after every 15 minutes in a session, near 40 minutes for the day, and at 45. Practice is never blocked.
- **Accessibility:** big numbers and icons now follow Dynamic Type everywhere, animations respect Reduce Motion, the scenario radar has an audio graph for VoiceOver (Swift Charts have one built in), and break suggestions, backups and icon changes come with haptics.

**Stage 12** (motivation):
- **Today card** (top of the Lessons tab): your streak, today's minutes against your daily goal, and today's challenge with **Go** and **Mark done**. One missed day per week is covered by a **streak freeze**, so a rest day for your voice doesn't break the streak (a practice day is any session of a minute or more).
- **Achievements** (Progress tab ▸ Achievements): 18 badges, from your first session and streaks to 80% in target, a Hard scenario and five hours of practice.
- **Balloon game** (More ▸ Tools): hum or speak to steer a balloon through gaps; the green band is your target range, and bright resonance while passing a gap scores a bonus star. Haptics mark passes and misses; Reduce Motion slows it down. Scores are kept.
- **Reminders** (Settings): the daily reminder plus an optional evening nudge at 7 pm only if you haven't practiced. Wording is neutral ("Time for practice").
- **Widgets:** Home Screen (small: streak and minutes; medium: plus today's challenge and a **Start** button) and Lock Screen (minutes ring, streak and minutes, inline). The app updates them whenever you practice.
- **Siri and Shortcuts:** "Start voice practice in VoiceBloom" opens Practice and starts listening; "Do a Quick Check in VoiceBloom" opens Quick Check.
- **Xcode:** the widget target and App Group are in `project.yml` for the GitHub build; for a hand-made Xcode project follow [step 7](#7-widgets-app-group-and-siri-shortcuts-stage-12).

**Stage 11** (AI Coach; **More ▸ Settings ▸ AI Coach** to turn it off or pick the coach):
- **Which coach:** Apple Intelligence on the iPhone when it's available (free, private, no key). Only if it isn't, and you paste your own free Gemini key (get one at aistudio.google.com), Gemini is used; it receives text only (stats, the words you said in scenarios, chat messages), never audio. Otherwise, and whenever an AI answer fails, the built-in rule-based coach answers. Settings shows which coach is in use and why on-device AI isn't available.
- **Post-session feedback:** the check-in sheet and each session's page show a summary, 2–3 tips and one exercise to try, based on the session and the trend over your last 5 sessions.
- **Weekly review** (Lessons tab): move on, stay with the week, extra practice for a weak skill, or rest after sore-throat check-ins.
- **Practice Texts** (More ▸ Tools): fresh passages for bright vowels, S/SH, questions, long sentences, names and numbers or everyday talk, which you can read aloud and get scored on.
- **Ask the Coach** (More): a short, supportive chat about voice training. It never encourages pushing through pain; anything about pain or lasting hoarseness gets the advice to stop and see a speech-language pathologist. Conversations aren't saved.
- **AI scenario partner:** in a scenario, switch on **AI partner**: the other person's lines are written from what you actually said (transcribed on the iPhone; speech recognition permission needed).

**Stage 10** (**More ▸ Tools ▸ Scenarios**, also linked from week 14):
- **11 scenarios**, each at **Easy** (short turns with a line to read), **Medium** (your own words, with prompts) and **Hard** (longer, unscripted, with surprises): ordering coffee, a phone call and voicemail, introducing yourself, asking a shop assistant, a complaint or return, a ~2-minute casual chat, reading a story with expression, a 1–2 minute presentation, emotional reactions, calling across a room, and end-of-day tired voice. All scripts are original and live in `VoiceBloom/Content/Scenarios.json`.
- Each scenario page shows the setting, who you're talking to, the length, tips and your past results. **Read the other person's lines aloud** uses the iPhone's built-in (on-device) voice; the microphone ignores it, and in Discreet Mode it only speaks through headphones.
- **Practice:** the other person's line appears (and is read aloud), then your prompt, a line to say on Easy, and a cue like "Excited" or "Call out". **Start speaking** records up to the turn's time (tap **Done** to finish early). Each turn is scored for **pitch** (time in your target), **resonance**, **weight**, **intonation** and **consistency** (how much of the turn held your target voice without slipping more than a semitone below the zone). **Try again** replaces a turn's score.
- **Results:** an overall score, the five averages, your strongest measure and a tip for the weakest. **Save and finish** stores a `ScenarioResult` (it fills the skills radar on the Progress tab and counts toward week 14's goal) and the practice session (then the check-in). The scenario list shows your best score per difficulty.

**Stage 9** (**Target Voice** tab):
- **Import:** **From Files** (MP3, M4A, WAV, MP4, MOV) or **From Photos** (videos). The sound is extracted on the iPhone (`AVAssetReader`, mixed to mono); up to the first 3 minutes are loaded. Nothing is uploaded, and only the part you keep is saved.
- **Trim:** drag the two handles on the waveform (or use the Start/End steppers, or VoiceOver's adjust gesture) to pick 10–60 seconds of one person talking. **Play selection** to check it (listening pauses first).
- **Analyze:** runs the same analysis as live practice over the selection and warns about **more than one voice** (phrases clustering at clearly different pitches), **music or singing** (long steady notes, or sound with no pauses), **background noise** (voice less than 12 dB above the quiet moments), **not much speech**, **distortion**, and selections shorter than 10 s or longer than 60 s.
- **Profile:** average pitch (with note), pitch range, a pitch histogram, average F1/F2/F3, a weight estimate (H1–H2) and intonation variability.
- **Save** with a name; **Set my targets from this voice** (on by default) sets your pitch range to the voice's typical pitch ±2 semitones and your F2/F3, H1–H2 and intonation targets from it, kept within the ranges Settings allows. You can still change everything in **Settings ▸ Voice targets** (manual override). A profile's page shows the before → after changes before applying them again.
- **Several profiles:** each one can be opened, listened to, renamed, deleted, or made the active one (one at a time).
- **Compare to Target:** read a 15-second passage; you get a % match for pitch (overlap of the two pitch histograms), resonance (F2/F3), weight (H1–H2) and intonation, an overall match, and charts overlaying both pitch histograms and the formants.
- **Shadowing:** the saved clip is split into short phrases. **Listen, then repeat**: the phrase plays, then you say it back. Both pitch contours appear on one chart with a "melody match" (shape, ignoring pitch level and speed) and how many semitones higher or lower you were. **Hear yourself** plays your attempt.
- Every Target Voice screen reminds you that the target is a guide, not something to copy exactly.

**Stage 8** (**More ▸ Tools**):
- **Quick Check:** read one sentence for 10 seconds. You get pitch, % in target, resonance, weight and intonation, each with the change since your last check (green when it moved the right way; for pitch, "right" means toward your target zone). It's saved as a "Quick Check" session (so it shows in Progress) with its recording; tap **Listen** to hear it.
- **Daily Sentence Journal:** record the same sentence once a day (recording again replaces today's entry; **Change** picks your own sentence). The timeline shows your pitch day by day against the target band. Drag the slider to any day to see its numbers and **Listen to this day**. **Play my progress** plays up to eight days in order, from the first to the latest. Entries can be deleted from the ••• menu.
- **Exercise Library:** all 85 exercises from the lessons, warm-ups, cool-downs, maintenance and Discreet Mode. Search by any word (title, instructions, notes), filter by skill (Warm-up, Pitch, Resonance, Weight, Intonation, Real speech, Cool-down) or **Quiet**. Tap one for its full instructions and **Practice this exercise** to run it on its own in the guided player.
- **Tone Generator & Piano:** a steady tone from 80 to 600 Hz (slider, semitone steps, or your target's low/middle/high), as a pure or warm sound, plus a two-octave keyboard (C3–C5) where dots mark the keys inside your target range. If listening is on, it pauses first so the microphone doesn't count the tone as your voice.
- **Discreet Mode:** a switch that stays on until you turn it off. Tones, the piano and lesson pitch-matching only play through headphones (otherwise they show a message instead), and slip-alert chimes go silent unless headphones are connected (vibration still works). It also lists the quiet exercises: whisper resonance, silent larynx awareness, very soft humming, silent tongue-forward placement and whispered reading. Practice shows a small "Discreet Mode" tag while it's on.

**Stage 7:**
- **Lessons tab:** the current week at the top (Start a Quick 5, Standard 15 or Deep 25 minute session), then all 16 weeks by phase: Foundations, Resonance, Pitch, Vocal weight, Intonation and expression, Real-world use. A tick means complete; a lock means not yet.
- **Unlocking:** a week opens after 5 sessions of the week before it **and** reaching that week's goal (e.g. week 2: match 8 of 10 tones within ±10 Hz; week 6: bright resonance 70% of a passage; week 9: 70% in target with bright resonance and no "Sore" check-ins). Any unlocked week can be repeated. The placement test (Stage 6) can unlock later weeks directly. To try everything: **More ▸ Debug & Tuning ▸ Unlock all lesson weeks**.
- **Week pages:** what you'll do, why it matters, step-by-step instructions, the goal, common mistakes, how it should feel, and every exercise. Tap an exercise for its full instructions and **Practice this exercise** on its own.
- **Guided session player** (full screen): each exercise with numbered instructions, "how it should feel" and the common mistake, a timer, the live pitch and meters, and Back / Pause / Next.
  - *Timed* exercises (breathing, trills, sirens, yawn-sighs…) count down and move on by themselves.
  - *Scored* exercises record when you tap **Start**: vowel holds (bright resonance %), readings and phrase lists (time in target, bright resonance, light weight, melody), and **pitch matching** (a tone plays, then you hum it back for 3 s; the mic ignores the tone itself).
  - When a scored exercise reaches the week's goal you'll see "Goal reached".
  - A session counts toward the week once you've done at least half of it. Ending it saves it (as "Lesson") and brings up the check-in.
- **45-minute soft cap:** starting a session after 45 minutes of practice today asks whether you'd rather rest.
- **Week 16:** re-record your baseline from the week page; Then vs Now (Progress tab) then compares Day 1 with today.
- **Maintenance mode** (after week 16): a daily 8-minute routine (focused on your weakest measure this week), a weekly challenge, and the other routines on demand.
- **Editing lessons:** everything is in `VoiceBloom/Content/Lessons.json` (weeks, exercises, goals, passages). The unit tests check the file still matches what the app expects.

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
                  BaselineStore, PlacementStore, DataEraser, PrivacySettings (wording, icon choice),
                  BackupService (archive, restore, BackupDocument)
  Content/        Original reading passages, Lessons.json (the 16-week plan + maintenance),
                  Scenarios.json (11 scenarios × Easy/Medium/Hard)
  Lessons/        LessonCatalog (JSON models), SessionPlanner, unlock rules and goal evaluation,
                  LessonProgressStore, GuidedSessionModel, GuidedSessionCoordinator
  Tools/          Exercise library search and filters, piano layout, tone-generator maths,
                  journal timeline (scrubber, streaks, highlights), Quick Check comparison
  Coach/          AICoachService protocol, FoundationModelsCoach (@Generable answers), GeminiCoach
                  (REST, key in Keychain), RuleBasedCoach, CoachSafety (rules, pain detection),
                  CoachPrompts, CoachRouter (choice + fallback), CoachContextBuilder
  Motivation/     StreakCalculator (weekly freezes), AchievementKind, DailyChallenge, NudgeScheduler,
                  PitchGameEngine + scores, MotivationCenter (refresh achievements, widgets, nudge)
  Health/         BreakAdvisor (soft limit, breaks), VocalHealthSummary (week of check-ins/strain),
                  HealthLibrary (Vocal Health Center articles)
  Shared/         WidgetSnapshot (App Group data) and LaunchIntents (App Intents), also in the widget
  Scenarios/      ScenarioCatalog (Scenarios.json models, script text), ScenarioScoring (turn scores,
                  consistency, summary), ScenarioResultStore, ScenarioSessionModel
  TargetVoice/    AudioFileDecoder (AVAssetReader), TargetClipAnalyzer (offline pipeline run),
                  ClipQualityChecker (music, noise, several speakers), ShadowingSegmenter,
                  TrimSelection, WaveformSummary, TargetComparison (% match), TargetSuggestion
                  (automatic targets), ContourComparison, TargetVoiceStore
  Persistence/    SwiftData schema (VoiceBloomSchemaV1: UserProfile, PracticeSession, Recording,
                  LessonProgress, TargetVoiceProfile, ScenarioResult, Achievement, DailyJournalEntry),
                  migration plan, enums stored as raw strings, VoiceBloomDatabase (opens the store)
  Sessions/       SessionSnapshot, SessionStore (save/upsert, delete, check-ins), CheckInRules,
                  PracticeSessionController (autosave, finish, discard, clips, playback),
                  ClipStats + FrameLog, RecordingFileStore (.m4a files), RecordingPlayer,
                  VoiceTakeRecorder (short measured takes), JournalStore, QuickCheckStore
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
                  Lessons (lesson list, week detail, exercise detail, maintenance, guided session player),
                  Tools (hub, exercise library, tone generator + mini piano, journal, Quick Check,
                  Discreet Mode), TargetVoice (list + import, trim editor, profile, Compare to
                  Target, shadowing), Scenarios (list, detail, full-screen practice),
                  Calibration (MicCalibration, MicCalibrationModel, MicCalibrationView), Debug, More,
                  Health (Vocal Health Center, articles, break banner), Settings ▸ Backup & App Icon
  DesignSystem/   Theme colors (light/dark, colorblind-safe) and shared components
VoiceBloomWidget/ WidgetKit extension: streak, today's minutes, quick start (Home and Lock Screen)
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
