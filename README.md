# Taskbar Remote

Control and monitor your Windows PC from your Android phone over your local network — no cloud, no account.

Taskbar Remote shows live **CPU / RAM / Wi-Fi** from your PC and lets you **launch, switch to, and close** any of your Start Menu apps right from your phone. It's built around a precision-instrument UI (segmented LED meters, mono telemetry readouts) and works fully wireless over Wi-Fi or a phone hotspot.

> Personal project. Phone ⇄ PC talk directly over your LAN; nothing leaves your network.

---

## Features

- **Live system telemetry** — CPU and RAM as segmented LED meters, Wi-Fi SSID + signal, temperature (when the PC exposes a sensor).
- **Launch PC apps** — every Start Menu shortcut, searchable from the phone.
- **Switch instead of duplicate** — tapping an already-open app brings its window to the front instead of opening a second copy.
- **Close from your phone** — gracefully close a running app on the PC (it can still prompt to save).
- **Quick page** — pin favourite apps to a full-page grid; a green dot + **Close** appears on the ones currently running.
- **Real app icons** — extracted from the PC and shown on the phone.
- **Token-secured** — a per-phone random token gates the connection.
- **Fully wireless** — works over normal Wi-Fi or the phone's own hotspot.

---

## How it works

The phone is the **server**; the PC agent is the **client** that connects to it.

```
┌─────────────┐      Wi-Fi / hotspot LAN       ┌──────────────────┐
│  Android    │  ws://<phone-ip>:8765/agent    │  Windows PC      │
│  app        │ ◀───────────────────────────── │  agent (client)  │
│  (server)   │  apps · icons · metrics ─────▶ │                  │
│             │  ◀──── launch / close / fav     │  PowerShell/WMI  │
└─────────────┘                                 └──────────────────┘
```

**Why this direction?** When the phone is acting as a Wi-Fi hotspot, an app on the host phone can't reach connected devices directly (Android routes its sockets out the cellular link). The PC *can* always reach the phone, so the PC connects to the phone. This makes it work over a phone hotspot with no extra setup.

The agent reads metrics and enumerates/launches apps using built-in Windows tooling (PowerShell, WMI, performance counters, `System.Drawing` for icons). The phone never runs anything on the PC except the apps you tap.

---

## Project structure

| Path | What it is |
|---|---|
| `lib/main.dart` | The Android app (Flutter) — UI + WebSocket server |
| `bin/pc_agent.dart` | The PC agent (Dart console client) |
| `windows-agent/TaskbarRemote.cs` | A Windows tray app (C#/WinForms) that wraps the agent with a window, system-tray icon, and an installer |
| `assets/fonts/` | Space Grotesk + Space Mono (SIL OFL) |
| `android/` | Android build config |

---

## Build it yourself

### Prerequisites
- [Flutter](https://flutter.dev) 3.44+ (Dart 3.12+)
- Android SDK (platform + build-tools)
- A JDK 17–21 (the one bundled with Android Studio works)
- Windows 10/11 for the PC agent

### Android app (APK)
```bash
flutter pub get
flutter build apk --release
# -> build/app/outputs/flutter-apk/app-release.apk
```
Install it on the phone (`adb install -r <apk>` or copy + tap).

### PC agent (standalone .exe, no Dart needed to run)
```bash
dart build cli                 # -> build/cli/windows_x64/bundle/bin/pc_agent.exe
```
Or run it directly during development:
```bash
dart run bin/pc_agent.dart --host <phone-ip> --port 8765 --token <token>
```

### Windows tray app (single self-installing .exe)
The C# tray app embeds the agent and gives you a real window + system-tray + installer. Build with the .NET Framework compiler (no SDK needed):
```bat
csc /target:winexe /out:TaskbarRemote.exe ^
    /resource:build\taskbar-agent.exe,agent ^
    /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll ^
    windows-agent\TaskbarRemote.cs
```
(`taskbar-agent.exe` is the compiled agent from the step above, renamed.)

---

## Using it

1. **PC and phone on the same network** — a normal Wi-Fi router, or the phone's hotspot.
2. **Open the app on the phone.** It shows its **Phone IP** and a **Token**.
3. **Run the agent on the PC** — `TaskbarRemote.exe`, then enter the phone's IP + token (it remembers them). Click **Install on this PC** to add it to the Start Menu and start it with Windows.
4. The phone flips to **LINKED** and starts showing live data and your apps.

The token is generated once per phone and saved, so you only set it up once.

### Wireless tip (phone hotspot)
Connect the laptop to the phone's hotspot, open the app, run the agent — done. The PC reaches the phone at the hotspot gateway IP.

---

## Security

- The connection is gated by a **random per-phone token** (rejected with `401` without it).
- Traffic is **plain WebSocket over your LAN** — fine on your own network/hotspot; avoid using it on untrusted public Wi-Fi (the token would travel in cleartext).
- Anyone with the token (and on the same network) can launch/close apps on the PC, so treat it like a password. The agent only ever runs Start Menu apps and reads system metrics.

---

## Tech

Flutter/Dart · Dart console agent · C#/WinForms tray app · WebSockets · PowerShell + WMI + performance counters · `System.Drawing` icon extraction.

## License

MIT — see [LICENSE](LICENSE). Bundled fonts (Space Grotesk, Space Mono) are licensed under the SIL Open Font License.
