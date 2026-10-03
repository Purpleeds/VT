# On-device testing checklist

Everything below needs a real iPhone. CI already builds the app and runs the unit tests on a simulator, covering:
- the DSP (pitch, formants, weight, intonation, voice quality, Voice Preview);
- scoring, lessons, scenarios, streaks, backup and the other logic.

What CI can't check is sound, microphones, haptics, notifications, widgets, Face ID, and how the screens look and feel. Tick items off as you go; anything that fails, note the screen and what you did.

Tip: **More ▸ Debug & Tuning** shows raw pitch, formants, the noise floor and processing time, and can generate sample history for the Progress tab.

## 1. Install and first launch
- [ ] The app installs and opens (sideloaded `.ipa` or Xcode), named **Chirp** with a plain light sky blue icon.
- [ ] Onboarding runs through all 9 steps.
- [ ] Each permission prompt appears once, with readable text: microphone, speech recognition, Face ID, notifications.
- [ ] Placement test: the tones play, matching works, and it suggests a sensible starting week.
- [ ] Day 1 baseline: the reading and the free speech both record, and the baseline is saved.

## 2. Live analysis (Practice tab)
- [ ] **Pitch accuracy:** play a note from the Tone Generator on a second phone (or use a tuner app). The readout is within a few Hz.
- [ ] **Resonance:** the meter moves toward Bright on "ee" and Dark on "oo". Weight moves when you speak more breathily or more pressed.
- [ ] **Intonation:** the meter updates after each sentence.
- [ ] **Calibration:** try a quiet room and a noisy one. Background noise never draws a pitch line.
- [ ] **Smoothness:** the graph scrolls smoothly and meters don't lag behind your voice.
  - [ ] In Low Power Mode the graph still looks fine (it drops to 30 fps).
- [ ] **Long session (30+ minutes):** no stutter, the phone stays only mildly warm, and the debug screen's processing time stays low.
- [ ] **Slip alerts:** haptics, chimes and banners each work and can be switched off. A chime is never counted as your voice.
- [ ] **Eyes-free practice:** the phone face down turns the screen off and listening continues; haptics only.
- [ ] **Strain warning:** appears after sustained rough or creaky voicing, with no repeat for 10 minutes.
- [ ] **Interruptions:** a phone call, Siri, or an alarm pauses listening and it resumes afterwards. Locking the phone pauses.
- [ ] **AirPods:** with **Use Bluetooth Microphones** off (the default), the iPhone's own mic is still used and chimes play in the AirPods. A Bluetooth or car mic shows the warning.
- [ ] **Break banner:** appears after 15 minutes of practice, near 40 minutes for the day, and at 45 minutes, with a gentle tap.

## 2b. Clear Mic and Mic Check (section 24)
Open **Mic Check** from the mic icon on Practice (or **Settings ▸ Mic Check & Clear Mic**). Do each block in a **quiet room** and in a **noisy one** (TV or music on, a fan, a café, traffic).

- [ ] **Level meter:** moves with your voice, the peak tick holds about 1.5 s. Shout or hold the phone close: the clipping warning appears.
- [ ] **Background noise:** settles within about 2 seconds of opening.
  - [ ] Quiet room: *Great*. Noisy room: *OK* or *Too noisy*.
  - [ ] Talking doesn't push the number up as long as you pause now and then.
- [ ] **Sample Room Noise:** stay quiet; the bar fills over 2 s and "Room noise saved" appears, with "Last sampled just now".
- [ ] **Off vs Light vs Strong** (same sentence each time, on Practice):
  - [ ] **Off:** readings as before Clear Mic.
  - [ ] **Light:** in the noisy room, the pitch line stops jumping around during pauses and the meters say **No voice** once you've been quiet for a moment. Pitch, resonance and weight while you talk look the same as Off.
  - [ ] **Strong:** the room is quieter still; the resonance-precision note shows; readings while talking stay close to Light.
  - [ ] Switching between Light and Strong while listening takes effect at once; turning Clear Mic on or off leaves only a tiny gap in the graph.
  - [ ] **Live readings from: Raw Mic** shows the old behavior with Clear Mic still selected (for comparing).
- [ ] **A/B test:** record 5 seconds, then play **Raw** and **Light**/**Strong**.
  - [ ] Pitch matches within a few Hz (the summary says so), and the background number drops.
  - [ ] The Clear Mic version sounds cleaner without sounding robotic; Strong may sound a little processed in a loud room.
  - [ ] Switching Light/Strong after recording remakes the Clear Mic version.
- [ ] **AirPods vs built-in mic:**
  - [ ] Built-in mic: the input shows *Built-in mic · 48 kHz*.
  - [ ] AirPods connected, **Use Bluetooth Microphones** off: the input stays the iPhone mic.
  - [ ] Turn it on and pick the AirPods in **Use**: the input shows *Bluetooth* with *high-quality mode* (iOS 26 with supporting AirPods) or *call quality*, and the warning explains the accuracy trade-off. Compare the A/B readings with the built-in mic.
  - [ ] Turn it off again: back to the iPhone mic.
  - [ ] Wired headphones with a mic (if you have them) show *Wired*.
- [ ] **iOS Voice Processing:** run **Test System Mode** (hum one steady note twice).
  - [ ] It reports Passed or Not recommended with a reason, and your strength is unchanged afterwards.
  - [ ] If it passed, **System** appears in the picker; with System on, Practice still works, the Debug screen shows "Voice processing: On, AGC off", and loudness readings don't creep up or down by themselves.
- [ ] **Noisy-room banner:** with Clear Mic Off in a noisy room, keep practicing; after about 8 s a banner suggests Clear Mic. **Turn On Clear Mic** switches to Light. It doesn't come back in the same session (Finish starts a new one).
- [ ] **Recordings stay raw:** save a clip with Clear Mic on, then in Session detail use the clip's **⋯** menu:
  - [ ] **Play with Clear Mic** sounds cleaner than the normal play button (the original).
  - [ ] **Share Original** and **Share with Clear Mic** both share an .m4a that plays in Files.
  - [ ] Journal entries have **Listen with Clear Mic** in their menu.
- [ ] **Calibration** still measures the real room (it analyzes raw audio) and samples room noise for Clear Mic.
- [ ] **Pitch Track** timing feels the same with Clear Mic Off and Light (the extra ~11 ms is corrected for).
- [ ] **Mic Check doesn't count as practice:** talking on the Mic Check screen doesn't add minutes or statistics to the session.
- [ ] **Delete All Data** resets Clear Mic to Off.

## 3. Sessions, recordings, check-ins
- [ ] **Save Clip** keeps the last 30 s; it plays back; it deletes from Session detail.
- [ ] **Live transcript** works with Dictation enabled, and works in Airplane Mode (on-device only).
- [ ] **Finish** saves the session and opens the check-in. Answering "Sore" twice in 3 days shows the rest-day banner.
- [ ] **Progress tab:** charts, calendar, radar and Then vs Now look right with real data and with Debug sample history. Tapping a chart opens the right session.
  - [ ] The CSV export opens in Numbers or Files.
  - [ ] The progress image shares correctly.

## 4. Lessons and guided sessions
- [ ] A Quick, a Standard and a Deep session run start to finish:
  - [ ] tones and the read-aloud steps play;
  - [ ] scored steps show results;
  - [ ] the session saves as a lesson.
- [ ] Five sessions plus the week goal unlock the next week.
- [ ] Past 45 minutes in a day, the soft-cap alert appears.

## 5. Tools
- [ ] **Tone Generator and mini piano:**
  - [ ] the slider, semitone steps and presets work;
  - [ ] keys are easy to read in light and dark mode;
  - [ ] listening pauses while a tone plays.
- [ ] **Discreet Mode:** tones and chimes are blocked without headphones and play with them.
- [ ] **Daily Journal:** record on two different days; the timeline scrubber plays each day; re-recording replaces today's entry.
- [ ] **Quick Check:** two checks compare with each other.
- [ ] **Balloon Game:** playable and fair, with haptics on pass and miss, and the best score saved. It plays slower with Reduce Motion.
- [ ] **Voice Preview:**
  - [ ] Recording 8 seconds works, and so does picking a saved recording.
  - [ ] Original and Preview both play.
  - [ ] Toward My Target and the slider extremes sound like a believable (if processed) shift.
  - [ ] Discreet Mode applies.
  - [ ] Leaving the screen stops playback.

## 5b. Vocal splitter (More › Tools › Vocal Splitter)
- [ ] Split a stereo studio song with **Basic**:
  - [ ] the progress percentage and time left move;
  - [ ] Cancel works;
  - [ ] locking the screen briefly doesn't stop it.
- [ ] A mono file is refused by Basic with an explanation. A plain speech recording says splitting isn't needed.
- [ ] **Mixer:**
  - [ ] Waveforms show; play, pause, scrub and loop work.
  - [ ] Solo, mute, and volume up to 150 % all work.
  - [ ] The A/B buttons switch between Original, Vocals, Backing and Mix.
  - [ ] The noise gate and de-reverb change the vocals.
- [ ] **Export:**
  - [ ] Vocals, backing and your mix as M4A and as WAV open in Files.
  - [ ] A video exported with replaced audio plays with the new sound and the same picture.
- [ ] **Record Over Backing** (with headphones):
  - [ ] the take lines up with the music;
  - [ ] Save keeps the take;
  - [ ] Export the Mix shares it.
- [ ] Target Voice: import a song, then **Split First for Best Results**. The analysis uses the isolated vocals.
- [ ] Settings › Split Tracks Storage lists sizes, and deleting one or all frees the space. Delete All Data removes splits.
- [ ] **High Quality (after adding the model, README › Vocal splitter):**
  - [ ] It splits mono files too, and sounds cleaner than Basic.
  - [ ] **Best** takes about twice as long.
  - [ ] Debug & Tuning shows per-chunk time and free memory.

## 5c. Pitch Track (More › Tools › Pitch Track)
- [ ] **Built-in tracks:**
  - [ ] Each one plays. The bars sit around your target zone.
  - [ ] The speech patterns show words under curved bars.
- [ ] **Make a track:**
  - [ ] From a clip of someone talking: detected as speech, curved bars, words under them.
  - [ ] From a sung clip: detected as singing, flat bars on the right notes.
  - [ ] Switching the type redraws the bars.
  - [ ] Cancel works during the analysis, and Skip Words during the word search.
  - [ ] A song with music shows the music warning; Split First rebuilds the bars from the vocals.
  - [ ] Target Voice ▸ Make a Pitch Track, and the builder's Use as Target Voice, both open.
- [ ] **Settings:**
  - [ ] Transpose and Auto-Fit shift the bars. The out-of-range advice appears for a high song.
  - [ ] 50 % speed plays slower at the same pitch.
  - [ ] A loop repeats its section, and the results list the passes.
  - [ ] Each sound mode plays the right thing: Original, Vocals Only, Backing Only (split songs), Guide Tones (they follow the bars), Silent.
- [ ] **Game:**
  - [ ] Countdown; the bars and the sound stay in step.
  - [ ] The dot follows your voice. Bars fill and change colour, the hint says higher/lower, and the combo counts.
  - [ ] Pause freezes the bars and the sound; Resume continues; End shows the score.
  - [ ] Without headphones there's a warning and Play Silently Instead.
  - [ ] The game turns to landscape; every other screen stays portrait.
  - [ ] A perfect note gives a light tap (when enabled). No slip alerts sound during the game.
  - [ ] The session appears in Progress as Pitch Track, and the check-in follows.
- [ ] **Timing:**
  - [ ] With AirPods, sing a built-in scale on the beat. Timing should score well after the tap-along calibration and noticeably worse with the offset set to 0.
  - [ ] The manual slider and Automatic both save.
- [ ] Debug & Tuning ▸ Simulate a perfect voice: built-in and uploaded tracks score about 100.
- [ ] Delete a track (it leaves the screen first). Delete All Data removes tracks.

## 6. Target Voice
- [ ] Import an MP3/M4A from Files, and a video from Photos.
- [ ] A file longer than 3 minutes loads its first 3 minutes.
- [ ] Trimming on the waveform works.
- [ ] A clip with music or two speakers shows a warning.
- [ ] Save, set active, apply targets, Compare to Target, and shadowing all work.

## 7. Scenarios
- [ ] The partner voice reads lines (Discreet Mode: headphones only).
- [ ] Turns are scored.
- [ ] Results appear in the Progress radar.
- [ ] **AI partner:** replies follow what you said (needs the live transcript and an AI coach).

## 8. AI Coach
- [ ] **On an Apple Intelligence iPhone (15 Pro or later), AI on:** feedback, weekly review, practice texts and chat come from the on-device model ("Coach in use" says so).
- [ ] **Without Apple Intelligence, with a Gemini key saved:** answers come from Gemini; the key survives an app restart; Remove Gemini Key works.
- [ ] **In Airplane Mode or with a bad key:** it quietly falls back to the built-in tips.
- [ ] Mentioning pain in chat always gets the "stop and see a professional" answer.

## 9. Motivation, notifications, widgets, Siri
- [ ] **Streak:** grows day by day; one missed day per week is bridged by the freeze.
- [ ] **Achievements** unlock.
- [ ] **Daily challenge:** Go and Mark Done work.
- [ ] **Daily reminder** arrives at the chosen time.
- [ ] **Evening nudge** arrives at 7 pm only on days without practice.
- [ ] **Neutral notification wording:** the Lock Screen just says "Time for practice". The "Mention voice practice" option changes the wording.
- [ ] **Widgets:**
  - [ ] Home Screen small and medium, and the Lock Screen widgets, show your numbers and update after practice.
  - [ ] The medium widget's Start button opens Practice and starts listening.
  - [ ] Both look right in dark mode.
  - [ ] If they only say "Open the app to start", the App Group didn't survive sideloading (see README step 7).
- [ ] **Siri:** "Start voice practice in Chirp" and "Do a Quick Check in Chirp" work, and both appear in the Shortcuts app.

## 10. Privacy and data
- [ ] **Face ID lock:** it locks on launch and when returning from the background; the passcode fallback works.
- [ ] **App switcher:** shows a plain screen instead of your data (Hide in App Switcher on).
- [ ] **Neutral icon:** switching shows iOS's confirmation and the grey icon on the Home Screen; switching back works.
  - [ ] The Shortcuts-bookmark steps for a neutral name work.
- [ ] **Backup:**
  - [ ] Back up with recordings and without, saving to Files.
  - [ ] Restore shows the file's contents before replacing.
  - [ ] After a restore, sessions, recordings (with sound), the journal, targets and settings are back.
- [ ] **Delete All Data:** returns to onboarding with everything gone, including notifications, widget numbers and the alternate icon.

## 11. Vocal Health Center
- [ ] Today's minutes match Practice.
- [ ] Rest suggestions appear after sore check-ins or repeated strain warnings.
- [ ] All seven articles open and read well.

## 12. Accessibility and appearance
- [ ] **VoiceOver:** walk through Practice, Lessons, Progress, Tools and Settings.
  - [ ] The pitch graph, meters and charts speak their values.
  - [ ] Swift Charts and the scenario radar offer audio graphs.
- [ ] **Largest Dynamic Type sizes (Settings ▸ Accessibility ▸ Display & Text Size):** nothing important is cut off on Practice, check-in, Settings or Voice Preview.
- [ ] **Reduce Motion:** banners and toasts don't slide, and the balloon game slows down.
- [ ] **Dark mode on every screen:** text is readable, charts and the piano look right, and the eyes-free screen stays black.
- [ ] **Differentiate Without Color and Increase Contrast:** meaning is still clear from labels and shapes.

## Known limitations
- **iCloud sync** isn't built; it needs a paid Apple Developer account. Use Backup & Restore to move data.
- **Sideloading:**
  - It may drop the App Group, which stops the widgets from showing numbers.
  - Free signing expires after 7 days.
- **AI scenario partner:** uses the on-device live transcript (SFSpeechRecognizer), not the newer SpeechAnalyzer API.
- **Voice Preview** is a rough approximation; large shifts sound processed by design.
- **Clear Mic:**
  - System mode depends on the iPhone and microphone, so it's only offered after its check passes.
  - High-quality Bluetooth recording needs iOS 26 and earbuds that support it; it uses the .default audio mode (Apple's requirement), so iOS may process that mic a little.
  - The noise profile belongs to the mic it was measured with; a different kind of mic starts learning again.
- **High Quality splitter model:** not in the repo; the README's "Vocal splitter" section explains how to convert and add it. Without it the splitter uses Basic.
- **Pitch Track:**
  - Attempts aren't saved yet. Recordings, save/discard, the written review and track history are Stage 16.
  - Tracks aren't included in backups (like splits).
  - Word timestamps need the system's on-device speech model. Without it, tracks have no words.
  - The background-music check is a heuristic: a cappella singing with no pauses can be flagged.
