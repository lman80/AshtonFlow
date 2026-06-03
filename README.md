<h1 align="center">AshtonFlow</h1>

<p align="center">
  Free, fast Mac dictation — speak anywhere and have clean text pasted into the current app.
</p>

<p align="center">
  <i>A personal fork of <a href="https://github.com/zachlatta/freeflow">FreeFlow</a> by Zach Latta (MIT licensed). A free alternative to Wispr Flow / Superwhisper / Monologue.</i>
</p>

---

## What this is

AshtonFlow lives in your menu bar. You press a key, talk, and your speech is transcribed (via [Groq](https://groq.com/)'s fast API), lightly cleaned up by an AI, and pasted into whatever app you're using. There's no subscription and no AshtonFlow server — the only thing that leaves your Mac is the API call to your transcription/LLM provider.

### What's different from upstream FreeFlow

- **One key does tap *and* hold.** If you set the Hold and Tap shortcuts to the same key: a quick **tap** starts recording and keeps going until you tap again; **press-and-hold** is push-to-talk and stops the moment you let go.
- **Screen recording is optional and off by default.** It's a toggle in Settings → Permissions ("Capture screen for context"). The app works fully without it.
- **Transcribe Audio window.** Menu bar → *Transcribe Audio…* opens a window where you drag in an **audio or video** file and get the text back (auto-copied to your clipboard and saved to History). Video audio is extracted automatically.
- **Offline mode (on-device).** Toggle it in Settings or the menu bar to transcribe **entirely on your Mac** with a local Whisper model (via [WhisperKit](https://github.com/argmaxinc/WhisperKit)) — works with no internet. The model downloads once while you're online (~150 MB for the default `base` model), then runs offline.
  - **Auto-fallback:** if a cloud request fails (e.g. on a VPN that blocks the provider), it automatically switches to offline transcription and switches back when your connection recovers. (On by default.)
  - **Offline cleanup:** on macOS 26 with Apple Intelligence enabled, the automatic text cleanup **and** Edit Mode run **on-device** via Apple's Foundation Models — same settings as online. If Apple Intelligence is off, offline falls back to transcription-only.
- **Speech-bubble menu bar icon** instead of the waveform.

---

## Install (download & run)

> AshtonFlow isn't notarized by Apple (that needs a paid Apple Developer account), so the first launch needs one quick approval step. This is normal for free, self-built Mac apps.

1. Download `AshtonFlow.zip` from the **[Releases](../../releases)** page and unzip it.
2. Drag **AshtonFlow.app** into your **Applications** folder.
3. **First launch:** because it's not notarized, macOS may say it "can't be opened" or is from an "unidentified developer." Do one of these:
   - **Right-click** the app → **Open** → **Open** in the dialog, **or**
   - If that's blocked, open **Terminal** and run:
     ```bash
     xattr -dr com.apple.quarantine /Applications/AshtonFlow.app
     ```
     then open the app normally.
4. Follow the setup wizard. You'll need a **free Groq API key** from [console.groq.com](https://console.groq.com/keys), and you'll grant **Microphone** and **Accessibility** permissions (so it can hear you and paste text). It does **not** ask for Screen Recording.

That's it — look for the speech-bubble icon in your menu bar.

---

## Using it

- **Pick your key** in the menu bar (Hold Shortcut / Tap Shortcut submenus). For the tap-or-hold-on-one-key behavior, set **both** to the same key.
  - **Tap** → records until you tap again.
  - **Hold** → push-to-talk; release to stop and paste.
- **Transcribe a file:** menu bar → **Transcribe Audio…**, then drag in an audio or video file.
- **Settings:** menu bar → **Settings** (custom vocabulary, output language, optional screen-recording context, provider/model, and more).

---

## Build it yourself (optional)

Requires **macOS 14+** (for the offline/WhisperKit support) and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone <this repo's URL>
cd <repo folder>
make run     # builds and launches
# or:
make         # just builds -> build/AshtonFlow.app
```

The build uses Swift Package Manager (`swift build`) and fetches WhisperKit the first time (needs internet once at build time). It signs ad-hoc automatically if you don't have a code-signing certificate, so `make` works on any Mac with no setup. Then drag `build/AshtonFlow.app` into Applications.

---

## Privacy

There is no AshtonFlow server. Audio and text are sent only to the transcription/LLM provider you configure (Groq by default, or any OpenAI-compatible endpoint, including local models like Ollama / LM Studio). Screenshots are never captured unless you explicitly turn on the optional screen-recording context setting.

## License & credit

MIT, same as upstream. Built on [FreeFlow](https://github.com/zachlatta/freeflow) by [Zach Latta](https://github.com/zachlatta) — thank you. See [LICENSE](LICENSE).
