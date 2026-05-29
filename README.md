# WhisperKey

> A **minimal hotkey wrapper around [whisper.cpp](https://github.com/ggerganov/whisper.cpp) + [`wtype`](https://github.com/atx/wtype)** — push-to-talk offline dictation for Ubuntu / Wayland.

WhisperKey is one small Bash script. It doesn't reinvent anything: it just glues
together tools you already have — `ffmpeg` records the mic, **whisper.cpp**
transcribes it, and **`wtype`** types the result at your cursor. Bind it to a
key, talk, and your words appear. Everything runs **fully offline** — no cloud
APIs, no accounts, no daemon, minimal attack surface.

```
1st press  ->  🎙  record the mic
2nd press  ->  ✍  transcribe (whisper.cpp) & type at the cursor (wtype)
```

> ## ⚠️ Read this first if you're on GNOME
>
> **`wtype` cannot type on GNOME.** GNOME's Mutter compositor doesn't implement
> the Wayland *virtual-keyboard* protocol `wtype` relies on, so WhisperKey
> **can't auto-type into the focused window on a stock Ubuntu/GNOME desktop**.
>
> Instead, the transcript is placed on your **clipboard** and you paste it with
> **`Ctrl+V`**. So on GNOME the real flow is:
>
> ```
> Super+R  ->  speak  ->  Super+R  ->  Ctrl+V
> ```
>
> Auto-typing works out of the box only on **wlroots** compositors (Sway,
> Hyprland, …). To get true auto-typing on GNOME you must switch the typing
> backend to [`ydotool`](https://github.com/ReimuNotMoe/ydotool) (uinput-based,
> needs a daemon + permissions) — see [Typing on GNOME](#prerequisites).

## Features

- 🪶 **Minimal** — one auditable Bash script wrapping whisper.cpp + `wtype`, no daemons
- 🔒 **100% offline** — audio never leaves your machine
- ⌨️ **Single-key toggle** — works with the press-only shortcuts GNOME provides
- 📋 **Clipboard fallback** — transcript copied via `wl-copy`; **on GNOME this is the primary path** (type isn't possible, so paste with `Ctrl+V`)
- 🔔 **Desktop notifications** at each stage (recording / transcribing / done)

## How it works

Ubuntu/GNOME shortcuts only deliver a **key-press**, never a release, so true
hold-to-talk would need an app with built-in global hotkeys or a dedicated hotkey
daemon — WhisperKey stays minimal on purpose and simply **toggles**:

1. **First press** starts `ffmpeg` recording your default mic to a WAV and saves
   its PID.
2. **Second press** detects the running recorder, stops it cleanly, runs
   whisper.cpp on the audio, types the result with `wtype`, and copies it to the
   clipboard.

### Where files live (important for the snap)

The `whisper-cpp` snap is **strictly confined** — it can only read files inside
its own data dir, `~/snap/whisper-cpp/common`. It **cannot** read
`$XDG_RUNTIME_DIR` or hidden dirs like `~/.local`. So by default both the model
and the recorded WAV live under:

```
~/snap/whisper-cpp/common/
├── models/ggml-base.en.bin   # the model
└── whisperkey/               # runtime state (WAV, PID, lock, verbose log)
```

If you use a **native** (non-snap) whisper build, point `WHISPER_BIN`,
`WHISPER_MODEL`, and `WHISPER_STATE_DIR` wherever you like (see
[Configuration](#configuration)).

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| `whisper.cpp` | speech-to-text | `sudo snap install whisper-cpp` |
| `ffmpeg` | mic capture | `sudo apt install ffmpeg` |
| `wtype` | type into focused window (Wayland) | `sudo apt install wtype` |
| `wl-clipboard` | clipboard fallback (`wl-copy`) | `sudo apt install wl-clipboard` |
| `libnotify-bin` | desktop notifications (`notify-send`) | `sudo apt install libnotify-bin` |

One-liner:

```bash
sudo snap install whisper-cpp
sudo apt install ffmpeg wtype wl-clipboard libnotify-bin
```

> **⚠️ Typing on GNOME:** `wtype` uses the Wayland *virtual-keyboard* protocol,
> which **wlroots** compositors (Sway, Hyprland, …) support but **GNOME/Mutter
> does not**. On GNOME the script can't auto-type — it falls back to putting the
> transcript on the clipboard so you paste with `Ctrl+V`. For true auto-typing on
> GNOME, use [`ydotool`](https://github.com/ReimuNotMoe/ydotool) instead (it works
> via `uinput` and needs a running daemon + permissions) — swap the `wtype "$TEXT"`
> line in `whisperkey.sh` for `ydotool type "$TEXT"`. On X11, `xdotool type` works.

## Install

### 1. Download a model

Use the snap's bundled downloader so the model lands in a snap-readable path:

```bash
whisper-cpp.download-ggml-model base.en ~/snap/whisper-cpp/common/models
```
`base.en` is the recommended default — real-time on CPU with solid accuracy. The
English-only (`.en`) models beat the multilingual ones at the same size for
English dictation. Pass a different name (run `whisper-cpp.download-ggml-model`
with no args to list them) and point `WHISPER_MODEL` at it for another tradeoff:

| Model | Size | Notes |
|-------|------|-------|
| `ggml-tiny.en.bin` | ~74 MB | fastest, noticeably more errors |
| **`ggml-base.en.bin`** | **~141 MB** | **recommended default** |
| `ggml-small.en.bin` | ~465 MB | better accuracy, longer transcribe pause |
| `ggml-medium.en.bin` | ~1.4 GB | slow on CPU, overkill for dictation |

For non-English, drop the `.en` suffix (e.g. `ggml-small.bin`).

### 2. Get the script

```bash
git clone https://github.com/<your-user>/whisperkey.git
cd whisperkey
chmod +x whisperkey.sh
```

### 3. Test it from a terminal

```bash
./whisperkey.sh   # starts recording — say something
./whisperkey.sh   # stops, transcribes, and types (or copies) the text
```

## Bind to a keyboard shortcut

Pick a shortcut that's free in
GNOME *and* in any app you care about — `Super`-based combos are safest because
GNOME apps and editors like VSCode don't bind the `Super` key on Linux:

```bash
SCRIPT="$(pwd)/whisperkey.sh"       # run from the repo dir, or use an absolute path
KEY=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/whisperkey/
SCHEMA=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding

gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$KEY']"
gsettings set "$SCHEMA:$KEY" name 'WhisperKey'
gsettings set "$SCHEMA:$KEY" command "$SCRIPT"
gsettings set "$SCHEMA:$KEY" binding '<Super>r'
```

> **Check for conflicts first** — list every binding that already uses a key:
> ```bash
> gsettings list-recursively | grep "'<Super>r'"   # empty output = it's free
> ```
> Avoid `<Super>v` (GNOME's message tray) and bare `F9` (VSCode's *Toggle
> Breakpoint*). `<Super>r`, `<Super>j`, `<Super>b` are typically free.

To change the key later, re-run the last line with a new binding. To remove it:

```bash
gsettings reset-recursively "$SCHEMA:$KEY"
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "[]"
```

## Configuration

Override defaults with environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `WHISPER_MODEL` | `~/snap/whisper-cpp/common/models/ggml-base.en.bin` | path to the GGML model |
| `WHISPER_BIN` | `whisper-cpp.cli` | whisper.cpp transcribe command |
| `WHISPER_STATE_DIR` | `~/snap/whisper-cpp/common/whisperkey` | runtime state (WAV, PID, lock, log) |

Example:

```bash
WHISPER_MODEL=~/snap/whisper-cpp/common/models/ggml-small.en.bin ./whisperkey.sh
```

## Debugging

Run with `--verbose` / `-v` (or `VERBOSE=1`) to see what's happening:

```bash
./whisperkey.sh --verbose      # start recording, verbose
./whisperkey.sh --verbose      # stop, transcribe, verbose
```

Verbose mode:

- logs timestamped events to **stderr and** `~/snap/whisper-cpp/common/whisperkey/whisperkey.log`
  (the log file matters when launched from a keyboard shortcut, where there's no
  terminal to print to);
- shows the resolved **paths** — model, PID file, lock, and the **WAV location**;
- surfaces `ffmpeg` and `whisper.cpp` output instead of silencing it;
- **keeps the recorded WAV** after transcription so you can inspect or replay it
  (`aplay ~/snap/whisper-cpp/common/whisperkey/record.wav`).

Tail the log live while testing the shortcut:

```bash
tail -f ~/snap/whisper-cpp/common/whisperkey/whisperkey.log
```

## Troubleshooting

- **"whisper binary not found"** — the snap exposes `whisper-cpp.cli` (not
  `whisper-cpp.transcribe`). Check `snap list whisper-cpp` and that `/snap/bin`
  is on your `PATH`.
- **"Model missing" / transcribes nothing** — the model must be in a
  **snap-readable** path. A model in `~/.local/...` or any hidden dir is
  invisible to the confined snap; re-download with
  `whisper-cpp.download-ggml-model base.en ~/snap/whisper-cpp/common/models`.
- **Nothing gets typed (but clipboard works)** — expected on **GNOME**: `wtype`
  can't drive Mutter. Paste with `Ctrl+V`, or switch to `ydotool` (see the
  Prerequisites note).
- **Wrong/silent recording** — check your default input device with
  `pactl info` / GNOME Sound settings. Run `./whisperkey.sh --verbose` and play back
  `~/snap/whisper-cpp/common/whisperkey/record.wav` with `aplay`.
- **Stuck "Recording…"** — a recorder PID file may be stale; just press the
  shortcut again. The script clears stale state on the next start.

## Notes

- **Auto-typing** works out of the box on **wlroots** compositors (Sway,
  Hyprland). On **GNOME** you get the clipboard fallback unless you switch to
  `ydotool` (see Prerequisites).
- Entirely offline — no cloud APIs.
- Minimal attack surface: a single auditable Bash script wrapping whisper.cpp.

## License

MIT — see [LICENSE](LICENSE) if present, otherwise use freely.
