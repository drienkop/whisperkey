# Alternative: Handy (GUI, Wayland/GNOME)

[Handy](https://github.com/cjpais/Handy) is a free, open-source, offline
speech-to-text desktop app (Tauri + Rust) — a GUI alternative to WhisperKey's
single Bash script. Same offline-first philosophy, but packaged as an
AppImage with a tray icon, model manager, and settings UI instead of a script
you configure by hand.

It has the **same core problem as WhisperKey on GNOME**: its default
auto-type path uses `wtype`, which needs the Wayland *virtual-keyboard*
protocol that Mutter doesn't implement (see the main README's GNOME warning).
Handy also defaults its paste-keystroke simulation to `wtype` regardless of
other settings, so getting reliable auto-typing on a stock Ubuntu/GNOME
desktop takes several additional fixes beyond just installing `ydotool`. This
doc records the exact setup that got it working.

## Install

```bash
mkdir -p ~/Applications
mv ~/Downloads/Handy_*.AppImage ~/Applications/Handy.AppImage
chmod +x ~/Applications/Handy.AppImage
```

Extract the bundled icon/desktop file and register a launcher + autostart
entry so it's searchable in the GNOME app grid and starts hidden in the tray
on login:

```bash
~/Applications/Handy.AppImage --appimage-extract
# copy squashfs-root/Handy.png -> ~/.local/share/icons/hicolor/512x512/apps/handy.png
# write ~/.local/share/applications/handy.desktop and ~/.config/autostart/handy.desktop
# (Exec= must prepend ~/.local/bin to PATH — see "Wrapper scripts" below)
```

## The GNOME/Wayland typing problem

Same root cause as WhisperKey:

```
[handy_app_lib::actions][ERROR] Failed to paste transcription: wtype failed:
Compositor does not support the virtual keyboard protocol
```

`wtype` (and `dotool`) need `zwp_virtual_keyboard_manager_v1`, which GNOME's
Mutter doesn't expose to arbitrary clients. Only wlroots compositors (Sway,
Hyprland) support it. `ydotool` sidesteps this entirely — it injects input at
the kernel `/dev/uinput` level instead of through a Wayland protocol, so it
works under any compositor.

### 1. Install and enable ydotool

```bash
sudo apt install -y ydotool
```

The Debian/Ubuntu package already ships everything needed — no manual udev
rule or group changes required if your user is already in the `input` group
(check with `groups`):

```bash
cat /usr/lib/udev/rules.d/80-uinput.rules
# KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"

systemctl --user enable --now ydotool.service   # runs ydotoold in the background
```

### 2. Point Handy at ydotool for direct typing

In `~/.local/share/com.pais.handy/settings_store.json`:

```json
"typing_tool": "ydotool",
```

This fixes **direct character-by-character typing**. It does **not** fix the
paste-keystroke (see next section) — Handy's key-combo path (used to send
`Ctrl+V` etc.) always tries `wtype` first regardless of this setting.

### 3. Shadow `wtype` with a translation wrapper

Handy hardcodes `wtype` for simulating modifier+key combos (the auto-paste
keystroke), independent of the `typing_tool` setting. Since real `wtype`
can't work on GNOME, we shadow it on `PATH` with a script that translates
`wtype`'s CLI syntax (`-M`/`-m` press/release modifier, `-k` press+release
key — see `man wtype`) into `ydotool key` calls using Linux keycodes:

`~/.local/bin/wtype`:

```bash
#!/bin/bash
# Translates wtype's virtual-keyboard-protocol calls into ydotool (kernel uinput)
# calls, since GNOME/Mutter doesn't implement virtual-keyboard-unstable-v1.

declare -A KEYCODE=(
  [ctrl]=29 [shift]=42 [alt]=56 [logo]=125 [win]=125 [altgr]=100 [capslock]=58
  [a]=30 [b]=48 [c]=46 [d]=32 [e]=18 [f]=33 [g]=34 [h]=35 [i]=23 [j]=36 [k]=37 [l]=38
  [m]=50 [n]=49 [o]=24 [p]=25 [q]=16 [r]=19 [s]=31 [t]=20 [u]=22 [v]=47 [w]=17 [x]=45 [y]=21 [z]=44
  [insert]=110 [delete]=111 [return]=28 [enter]=28 [escape]=1 [tab]=15 [space]=57
  [home]=102 [end]=107 [left]=105 [right]=106 [up]=103 [down]=108
)

lookup() {
    local key_lower="${1,,}"
    echo "${KEYCODE[$key_lower]}"
}

YDOTOOL=/usr/bin/ydotool
events=()
args=("$@")
n=${#args[@]}
i=0
while [ $i -lt $n ]; do
    opt="${args[$i]}"
    case "$opt" in
        -M) kc=$(lookup "${args[$((i+1))]}"); [ -n "$kc" ] && events+=("$kc:1"); i=$((i+2)) ;;
        -m) kc=$(lookup "${args[$((i+1))]}"); [ -n "$kc" ] && events+=("$kc:0"); i=$((i+2)) ;;
        -P) kc=$(lookup "${args[$((i+1))]}"); [ -n "$kc" ] && events+=("$kc:1"); i=$((i+2)) ;;
        -p) kc=$(lookup "${args[$((i+1))]}"); [ -n "$kc" ] && events+=("$kc:0"); i=$((i+2)) ;;
        -k) kc=$(lookup "${args[$((i+1))]}"); [ -n "$kc" ] && events+=("$kc:1" "$kc:0"); i=$((i+2)) ;;
        -d|-s) i=$((i+2)) ;;
        --) i=$((i+1)) ;;
        -) i=$((i+1)) ;;
        *)
            if [ ${#events[@]} -gt 0 ]; then
                exec "$YDOTOOL" key "${events[@]}"
            fi
            exec "$YDOTOOL" type "$opt"
            ;;
    esac
done

if [ ${#events[@]} -gt 0 ]; then
    exec "$YDOTOOL" key "${events[@]}"
fi
```

```bash
chmod +x ~/.local/bin/wtype
```

### 4. Make Handy resolve the wrapper first

Both `~/.local/share/applications/handy.desktop` and
`~/.config/autostart/handy.desktop` need `~/.local/bin` prepended to `PATH`
so Handy's subprocess spawns find the `wtype` wrapper before the real
`/usr/bin/wtype`:

```ini
Exec=env PATH=$HOME/.local/bin:$PATH $HOME/Applications/Handy.AppImage --start-hidden
```

### 5. Skip typing entirely — instant clipboard paste

Character-by-character typing is inherent to any keystroke-injection tool
(real key events sent one at a time), so it's always going to look like it's
"drawing" the text. For instant whole-text insertion, switch Handy from
typing to clipboard+paste instead:

```json
"paste_method": "ctrl_shift_v",
```

Handy copies the transcript to the clipboard (`wl-copy`) then sends **one**
paste keystroke (still through the `wtype`→`ydotool` wrapper above) instead
of typing every character.

**Use `ctrl_shift_v`, not `ctrl_v`, if you dictate into terminals.** Most
Linux terminal emulators (GNOME Terminal, Konsole, …) bind paste to
`Ctrl+Shift+V` — plain `Ctrl+V` is often unbound or reserved by the shell.
With `ctrl_v`, Handy's own log shows a successful "paste" while nothing
actually lands in a focused terminal. `ctrl_shift_v` works in both terminals
and most GUI text fields.

Trade-off: each dictation briefly overwrites your system clipboard.

### 6. Fix the rapid-retrigger race

If you toggle the hotkey again before the previous transcription/paste
finishes, Handy silently cancels the earlier one (`"Transcription operation
cancelled before paste"` in the log) — sometimes producing no output,
sometimes a stale/previous result. There's a `reliable_paste` setting for
this that isn't in the settings file by default (it just uses an in-memory
default of `false`); add it explicitly:

```json
"reliable_paste": true,
```

## Final `settings_store.json` (relevant keys)

Path: `~/.local/share/com.pais.handy/settings_store.json`

```json
"paste_delay_ms": 10,
"paste_delay_after_ms": 10,
"paste_method": "ctrl_shift_v",
"reliable_paste": true,
"typing_tool": "ydotool",
```

Stop/restart Handy after editing this file directly (it doesn't hot-reload):

```bash
pkill -x handy
PATH="$HOME/.local/bin:$PATH" nohup ~/Applications/Handy.AppImage --start-hidden >/tmp/handy.log 2>&1 &
disown
```

## GNOME hotkey

Handy has its own in-app global-shortcut capture, but it only fires when
Handy's own window is focused (GNOME/Mutter limitation) — so bind the
external CLI trigger through GNOME's own custom-keybindings the same way
WhisperKey does:

```bash
HANDY=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/handy/
SCHEMA=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding

gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
  "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/whisperkey/', '$HANDY']"
gsettings set "$SCHEMA:$HANDY" name 'Handy Toggle Transcription'
gsettings set "$SCHEMA:$HANDY" command "$HOME/Applications/Handy.AppImage --toggle-transcription"
gsettings set "$SCHEMA:$HANDY" binding '<Primary>Print'
```

`--toggle-transcription` messages the already-running (backgrounded)
instance rather than launching a new one, so autostart + this binding must
both be in place.

**Watch for GNOME default-shortcut collisions** — GNOME's own window-manager
bindings win over custom media-key bindings silently (no error, the custom
one just never fires). Two hit during setup:

- `<Super>h` → claimed by `org.gnome.desktop.wm.keybindings minimize`
- `<Super>Control_L` (an attempt at a pure two-modifier chord) → GNOME's
  shortcut grabber doesn't support modifier-only accelerators for custom
  keybindings at all, regardless of collisions

Check before picking one:

```bash
gsettings list-recursively | grep "'<Primary>Print'"   # empty = free
```

## Summary of files touched

| File | Purpose |
|------|---------|
| `~/Applications/Handy.AppImage` | the app |
| `~/.local/share/applications/handy.desktop` | app-grid launcher, `PATH`-wrapped |
| `~/.config/autostart/handy.desktop` | starts hidden in tray on login, `PATH`-wrapped |
| `~/.local/share/icons/hicolor/512x512/apps/handy.png` | launcher icon |
| `~/.local/bin/wtype` | wrapper: translates wtype syntax → `ydotool key` |
| `~/.local/share/com.pais.handy/settings_store.json` | `typing_tool`, `paste_method`, `reliable_paste`, `paste_delay_*` |
| GNOME `custom-keybindings` (dconf) | `Ctrl+Print` → `Handy.AppImage --toggle-transcription` |
