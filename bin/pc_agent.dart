import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Taskbar Remote PC agent (client mode).
///
/// The phone runs the WebSocket server; this agent connects out to it. That is
/// the only direction that works when the phone is acting as a Wi-Fi hotspot,
/// because an app on the hotspot host cannot reach connected clients directly.
///
/// Usage:
///   `dart run bin/pc_agent.dart --host PHONE_IP [--port 8765] --token TOKEN`

/// The live-view screenshot streamer (a single persistent PowerShell process).
/// Only one window is ever streamed at a time, so a single handle is enough.
Process? _viewProc;

Future<void> main(List<String> args) async {
  final host = _argValue(args, '--host');
  final port = int.tryParse(_argValue(args, '--port') ?? '') ?? 8765;
  final token = _argValue(args, '--token') ?? '';

  if (host == null || host.isEmpty) {
    stderr.writeln(
      'Usage: dart run bin/pc_agent.dart --host <phone-ip> [--port 8765] --token <token>',
    );
    exit(64);
  }

  final apps = await _loadApps();
  final favorites = await _loadFavorites();
  // id -> running-process base name (e.g. "chrome"), filled when meta resolves.
  final procById = <String, String>{};
  final metaFuture = _loadAppMeta(apps);
  metaFuture.then(
    (meta) {
      procById.addAll(meta.procs);
      stdout.writeln('Icons ready: ${meta.icons.length} of ${apps.length}');
    },
    onError: (Object e) => stdout.writeln('Icon extraction failed: $e'),
  );

  stdout.writeln('Taskbar Remote PC agent (client mode).');
  stdout.writeln('Target phone: ws://$host:$port/agent');
  stdout.writeln('Apps found: ${apps.length}');

  // Reconnect loop: keep trying to reach the phone forever.
  while (true) {
    try {
      final uri = Uri(
        scheme: 'ws',
        host: host,
        port: port,
        path: 'agent',
        queryParameters: {'token': token},
      );
      stdout.writeln('Connecting to phone…');
      final socket = await WebSocket.connect(uri.toString())
          .timeout(const Duration(seconds: 6));
      socket.pingInterval = const Duration(seconds: 10);
      stdout.writeln('Connected to phone.');
      // Fresh connection: the phone lost its cached window icons, so forget
      // which ones we've sent and let them be re-sent for the live windows.
      _sentWinIconPaths.clear();

      // Push the app list (with current favorites) immediately.
      socket.add(jsonEncode({
        'type': 'apps',
        'apps': apps.map((app) => app.toJson()).toList(),
        'favorites': favorites.toList(),
      }));

      // Push icons whenever extraction finishes (independent of metrics).
      metaFuture.then((meta) {
        if (socket.readyState == WebSocket.open) {
          socket.add(jsonEncode({'type': 'icons', 'icons': meta.icons}));
        }
      }).catchError((_) {});

      // Push metrics + the set of running app ids + the live open windows.
      void pushMetrics(Map<String, dynamic> metrics) {
        if (socket.readyState != WebSocket.open) return;
        // Keep the metrics message light — the windows array is sent separately.
        final rawWindows = metrics.remove('windows');
        socket.add(jsonEncode(metrics));
        final names = (metrics['running'] as List?)
                ?.map((e) => '$e'.toLowerCase())
                .toSet() ??
            <String>{};
        final runningIds = [
          for (final entry in procById.entries)
            if (names.contains(entry.value)) entry.key
        ];
        socket.add(jsonEncode({'type': 'running', 'ids': runningIds}));

        // Tag each open window with a matching app id when we know one, so the
        // phone can show matched apps with full features and the rest as plain
        // viewable windows. Also fetch icons for the unmatched ones.
        final procToId = <String, String>{};
        for (final entry in procById.entries) {
          procToId.putIfAbsent(entry.value, () => entry.key);
        }
        final items = <Map<String, dynamic>>[];
        final iconPaths = <String>[];
        final seen = <String>{};
        for (final w in (rawWindows as List? ?? const []).whereType<Map>()) {
          final proc = '${w['proc'] ?? ''}'.toLowerCase();
          if (proc.isEmpty) continue;
          final hwnd = '${w['hwnd'] ?? ''}';
          final path = w['path'] == null ? null : '${w['path']}';
          final appId = procToId[proc];
          // One entry per window handle, so multiple windows of the same
          // program (e.g. two terminal windows) each show up.
          if (!seen.add(hwnd.isNotEmpty ? hwnd : (appId ?? proc))) continue;
          items.add({
            'proc': proc,
            'title': '${w['title'] ?? ''}',
            'path': path,
            'appId': appId,
            'hwnd': hwnd,
          });
          if (appId == null && path != null && path.isNotEmpty) {
            iconPaths.add(path);
          }
        }
        socket.add(jsonEncode({'type': 'windows', 'items': items}));
        unawaited(_sendWinIcons(socket, iconPaths));
      }

      // First sample right away, then every 2s without overlapping.
      _readMetrics().then(pushMetrics).catchError((_) {});

      var readingMetrics = false;
      final metricsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (socket.readyState != WebSocket.open || readingMetrics) return;
        readingMetrics = true;
        try {
          pushMetrics(await _readMetrics());
        } finally {
          readingMetrics = false;
        }
      });

      // Handle launch / favorite / close / view commands until the socket closes.
      final done = Completer<void>();
      socket.listen(
        (data) async {
          await _handleClientMessage(socket, data, apps, favorites, procById);
        },
        onDone: () => done.complete(),
        onError: (_) => done.complete(),
        cancelOnError: true,
      );
      await done.future;
      metricsTimer.cancel();
      await _stopView();
      stdout.writeln('Disconnected from phone.');
    } catch (error) {
      stdout.writeln('Connection failed: $error');
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
}

/// Some Start-Menu shortcuts point at a small *launcher* whose process exits
/// immediately and whose real window is owned by a differently-named process.
/// Windows 11 opens PowerShell/consoles inside Windows Terminal (`wt.exe` ->
/// `WindowsTerminal.exe`), so without this the terminal never shows as running
/// and can't be viewed. Map the launcher name to the real window process.
const Map<String, String> _procAliases = {
  'wt': 'windowsterminal',
};

String _aliasProc(String proc) => _procAliases[proc.toLowerCase()] ?? proc;

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}

/// Launches the shortcut, or — if its target program already has an open
/// window — brings that window to the foreground instead of starting a
/// duplicate. The shortcut path is passed via the TBR_LAUNCH env var.
const String _launchScript = r'''
$lnk = $env:TBR_LAUNCH
$shell = New-Object -ComObject WScript.Shell
$target = ""
try { $target = $shell.CreateShortcut($lnk).TargetPath } catch {}
$switched = $false
if ($target -and (Test-Path $target)) {
  $procName = [System.IO.Path]::GetFileNameWithoutExtension($target)
  if ($procName -eq 'wt') { $procName = 'WindowsTerminal' }
  $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
  if ($procs) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TbrWin {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool c);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern void keybd_event(byte v, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, uint c, uint d);
  public static void Focus(IntPtr h) {
    if (IsIconic(h)) { ShowWindow(h, 9); }
    SystemParametersInfo(0x2001, 0, 0, 2);
    uint pid;
    uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    uint cur = GetCurrentThreadId();
    keybd_event(0x12, 0, 0, UIntPtr.Zero);
    keybd_event(0x12, 0, 2, UIntPtr.Zero);
    AttachThreadInput(cur, fg, true);
    BringWindowToTop(h);
    ShowWindow(h, 5);
    SetForegroundWindow(h);
    AttachThreadInput(cur, fg, false);
  }
}
"@
    try { [TbrWin]::Focus($procs[0].MainWindowHandle); $switched = $true } catch {}
  }
}
if (-not $switched) { Start-Process -FilePath $lnk }
if ($switched) { Write-Output "switched" } else { Write-Output "launched" }
''';

/// Gracefully closes every window of the named process (sends WM_CLOSE, so the
/// app can prompt to save). Process name passed via the TBR_CLOSE env var.
const String _closeScript = r'''
$name = $env:TBR_CLOSE
Get-Process -Name $name -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowHandle -ne 0 } |
  ForEach-Object { $_.CloseMainWindow() | Out-Null }
''';

/// Gracefully closes one specific window (WM_CLOSE), so exactly the window the
/// user tapped closes. The window handle is passed via TBR_CLOSE_HWND.
const String _closeHwndScript = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TbrClose {
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
}
"@
try {
  $h = [IntPtr][int64]$env:TBR_CLOSE_HWND
  if ([TbrClose]::IsWindow($h)) { [TbrClose]::SendMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
} catch {}
''';

Future<void> _handleClientMessage(
  WebSocket socket,
  dynamic data,
  List<LaunchableApp> apps,
  Set<String> favorites,
  Map<String, String> procById,
) async {
  try {
    final message = jsonDecode(data as String) as Map<String, dynamic>;
    final type = message['type'];
    if (type == 'setFavorite') {
      final favId = '${message['id'] ?? ''}';
      if (favId.isEmpty) return;
      if (message['value'] == true) {
        favorites.add(favId);
      } else {
        favorites.remove(favId);
      }
      await _saveFavorites(favorites);
      return;
    }
    if (type == 'close') {
      // Prefer closing a specific window handle (so the right terminal window
      // closes); fall back to closing by process name.
      final hwnd = '${message['hwnd'] ?? ''}'.trim();
      if (hwnd.isNotEmpty) {
        await Process.run(
          'powershell.exe',
          ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', _closeHwndScript],
          environment: {'TBR_CLOSE_HWND': hwnd},
        );
        return;
      }
      var procName = '${message['proc'] ?? ''}'.trim();
      if (procName.isEmpty) {
        procName = procById['${message['id'] ?? ''}'] ?? '';
      }
      if (procName.isNotEmpty) {
        await Process.run(
          'powershell.exe',
          ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', _closeScript],
          environment: {'TBR_CLOSE': procName},
        );
      }
      return;
    }
    if (type == 'startView') {
      final hwnd = '${message['hwnd'] ?? ''}'.trim();
      if (hwnd.isNotEmpty) {
        await _startView(socket, hwnd: hwnd);
        return;
      }
      final rawProc = '${message['proc'] ?? ''}'.trim();
      if (rawProc.isNotEmpty) {
        await _startView(socket, proc: rawProc);
        return;
      }
      final vid = '${message['id'] ?? ''}';
      final app = apps.where((item) => item.id == vid).firstOrNull;
      if (app == null) {
        socket.add(jsonEncode(
            {'type': 'viewStatus', 'status': 'error', 'message': 'Unknown app'}));
        return;
      }
      await _startView(socket, app: app);
      return;
    }
    if (type == 'stopView') {
      await _stopView();
      return;
    }
    if (type != 'launch') return;
    final id = '${message['id'] ?? ''}';
    final app = apps.where((item) => item.id == id).firstOrNull;
    if (app == null) {
      socket.add(jsonEncode(
          {'type': 'launchResult', 'ok': false, 'name': 'Unknown app'}));
      return;
    }
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', _launchScript],
      environment: {'TBR_LAUNCH': app.path},
    );
    socket.add(jsonEncode({
      'type': 'launchResult',
      'ok': result.exitCode == 0,
      'name': app.name,
    }));
  } catch (error) {
    socket.add(jsonEncode({'type': 'error', 'message': '$error'}));
  }
}

/// Persistent live-view streamer. Resolves the shortcut's target process,
/// brings its window to the front once, then repeatedly screenshots that
/// window's rectangle, scales it down, JPEG-encodes it, and prints one
/// base64 line per frame (`F <w> <h> <base64>`). The shortcut path is passed
/// via the TBR_VIEW_LNK env var. Prints "NOWIN" while no window is open yet.
const String _viewScript = r'''
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TbrView {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
}
"@
$hwndArg = $env:TBR_VIEW_HWND
$procName = $env:TBR_VIEW_PROC
if (-not $procName -and -not $hwndArg) {
  $lnk = $env:TBR_VIEW_LNK
  try {
    $shell = New-Object -ComObject WScript.Shell
    $t = $shell.CreateShortcut($lnk).TargetPath
    if ($t) { $procName = [System.IO.Path]::GetFileNameWithoutExtension($t) }
  } catch {}
}
if ($procName -eq 'wt') { $procName = 'WindowsTerminal' }
if (-not $procName -and -not $hwndArg) { [Console]::Out.WriteLine("NOWIN"); }
$fixedH = [IntPtr]::Zero
if ($hwndArg) { try { $fixedH = [IntPtr][int64]$hwndArg } catch {} }
$maxW = 1366
$jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$ep = New-Object System.Drawing.Imaging.EncoderParameters 1
$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]72)
$focused = $false
while ($true) {
  try {
    if ($fixedH -ne [IntPtr]::Zero) {
      if (-not [TbrView]::IsWindow($fixedH)) { [Console]::Out.WriteLine("NOWIN"); [Console]::Out.Flush(); Start-Sleep -Milliseconds 500; continue }
      $h = $fixedH
    } else {
      $p = Get-Process -Name $procName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
      if (-not $p) { [Console]::Out.WriteLine("NOWIN"); [Console]::Out.Flush(); Start-Sleep -Milliseconds 500; continue }
      $h = $p.MainWindowHandle
    }
    if (-not $focused) {
      if ([TbrView]::IsIconic($h)) { [TbrView]::ShowWindow($h, 9) | Out-Null }
      [TbrView]::SetForegroundWindow($h) | Out-Null
      $focused = $true
      Start-Sleep -Milliseconds 150
    }
    $r = New-Object 'TbrView+RECT'
    [TbrView]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    if ($w -le 0 -or $ht -le 0) { Start-Sleep -Milliseconds 300; continue }
    $shot = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($shot)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
    $g.Dispose()
    $scale = 1.0
    if ($w -gt $maxW) { $scale = $maxW / $w }
    $nw = [int]($w * $scale); $nh = [int]($ht * $scale)
    if ($nw -lt 1) { $nw = 1 }; if ($nh -lt 1) { $nh = 1 }
    $out = New-Object System.Drawing.Bitmap $nw, $nh
    $g2 = [System.Drawing.Graphics]::FromImage($out)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($shot, 0, 0, $nw, $nh)
    $g2.Dispose(); $shot.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $out.Save($ms, $jpeg, $ep)
    $out.Dispose()
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    $ms.Dispose()
    [Console]::Out.WriteLine("F $nw $nh $b64")
    [Console]::Out.Flush()
  } catch {
    Start-Sleep -Milliseconds 300
  }
  Start-Sleep -Milliseconds 260
}
''';

/// Starts (or restarts) the live-view streamer and forwards each frame to the
/// phone as a `frame` message. Targets either a Start-Menu [app] (opened/focused
/// first so its window exists) or a raw window process name [proc] (for live
/// windows with no shortcut, e.g. Windows Terminal). Killing the process stops it.
Future<void> _startView(WebSocket socket,
    {LaunchableApp? app, String? proc, String? hwnd}) async {
  await _stopView();
  try {
    final env = <String, String>{};
    if (hwnd != null && hwnd.isNotEmpty) {
      env['TBR_VIEW_HWND'] = hwnd;
    } else if (proc != null && proc.isNotEmpty) {
      env['TBR_VIEW_PROC'] = proc;
    } else if (app != null) {
      // Open or focus the app first so its window exists and is on top.
      unawaited(Process.run(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', _launchScript],
        environment: {'TBR_LAUNCH': app.path},
      ));
      env['TBR_VIEW_LNK'] = app.path;
    } else {
      return;
    }
    final vproc = await Process.start(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', _viewScript],
      environment: env,
    );
    _viewProc = vproc;
    vproc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (socket.readyState != WebSocket.open) return;
      if (line.startsWith('F ')) {
        final firstSpace = line.indexOf(' ', 2);
        final secondSpace = firstSpace == -1 ? -1 : line.indexOf(' ', firstSpace + 1);
        if (firstSpace == -1 || secondSpace == -1) return;
        final w = int.tryParse(line.substring(2, firstSpace));
        final h = int.tryParse(line.substring(firstSpace + 1, secondSpace));
        final data = line.substring(secondSpace + 1);
        socket.add(jsonEncode({'type': 'frame', 'w': w, 'h': h, 'data': data}));
      } else if (line.trim() == 'NOWIN') {
        socket.add(jsonEncode({'type': 'viewStatus', 'status': 'nowindow'}));
      }
    }, onError: (_) {});
    vproc.stderr.drain<void>();
  } catch (error) {
    socket.add(jsonEncode(
        {'type': 'viewStatus', 'status': 'error', 'message': '$error'}));
  }
}

Future<void> _stopView() async {
  final proc = _viewProc;
  _viewProc = null;
  if (proc != null) {
    try {
      proc.kill();
    } catch (_) {}
  }
}

/// Executable paths whose icon has already been sent, so each is extracted once.
final Set<String> _sentWinIconPaths = <String>{};

/// Extracts and sends icons for any not-yet-seen window executable paths, keyed
/// by path (the phone caches them for the Running page's live windows).
Future<void> _sendWinIcons(WebSocket socket, List<String> paths) async {
  final needed = paths.where((p) => _sentWinIconPaths.add(p)).toList();
  if (needed.isEmpty) return;
  try {
    final icons = await _extractExeIcons(needed);
    if (icons.isNotEmpty && socket.readyState == WebSocket.open) {
      socket.add(jsonEncode({'type': 'winIcons', 'icons': icons}));
    }
  } catch (_) {}
}

Future<Map<String, String>> _extractExeIcons(List<String> paths) async {
  const script = r'''
Add-Type -AssemblyName System.Drawing
$paths = Get-Content -Raw -LiteralPath $env:TBR_EXE_PATHS | ConvertFrom-Json
$result = @{}
foreach ($p in $paths) {
  try {
    if ($p -and (Test-Path $p)) {
      $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($p)
      if ($icon) {
        $bmp = $icon.ToBitmap()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $result[$p] = [Convert]::ToBase64String($ms.ToArray())
        $ms.Dispose(); $bmp.Dispose(); $icon.Dispose()
      }
    }
  } catch {}
}
$result | ConvertTo-Json -Compress -Depth 3
''';
  final file = File(
      '${Directory.systemTemp.path}\\tbr_exe_icons_${DateTime.now().microsecondsSinceEpoch}.json');
  try {
    await file.writeAsString(jsonEncode(paths));
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
      environment: {'TBR_EXE_PATHS': file.path},
    ).timeout(const Duration(seconds: 30));
    final out = '${result.stdout}'.trim();
    if (out.isEmpty) return {};
    final decoded = jsonDecode(out);
    if (decoded is! Map) return {};
    final icons = <String, String>{};
    decoded.forEach((key, value) {
      if (value is String && value.isNotEmpty) icons['$key'] = value;
    });
    return icons;
  } finally {
    try {
      await file.delete();
    } catch (_) {}
  }
}

Future<Map<String, dynamic>> _readMetrics() async {
  const script = r'''
$ErrorActionPreference = "SilentlyContinue"
$cpu = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
$os = Get-CimInstance Win32_OperatingSystem
$total = [double]$os.TotalVisibleMemorySize
$free = [double]$os.FreePhysicalMemory
$ram = if ($total -gt 0) { (($total - $free) / $total) * 100 } else { $null }
$wifi = ""
$netsh = netsh wlan show interfaces
$ssidLine = $netsh | Where-Object { $_ -match '^\s*SSID\s*:' -and $_ -notmatch 'BSSID' } | Select-Object -First 1
$signalLine = $netsh | Where-Object { $_ -match '^\s*Signal\s*:' } | Select-Object -First 1
if ($ssidLine) { $wifi = ($ssidLine -replace '^\s*SSID\s*:\s*','').Trim() }
if ($signalLine) { $wifi = "$wifi " + (($signalLine -replace '^\s*Signal\s*:\s*','').Trim()) }
$temps = Get-WmiObject MSAcpi_ThermalZoneTemperature -Namespace "root/wmi"
$temp = $null
if ($temps) {
  $values = @($temps | ForEach-Object { ($_.CurrentTemperature / 10) - 273.15 } | Where-Object { $_ -gt 0 -and $_ -lt 130 })
  if ($values.Count -gt 0) { $temp = ($values | Measure-Object -Average).Average }
}
$running = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -ExpandProperty ProcessName -Unique)
$block = @('textinputhost','applicationframehost','searchhost','shellexperiencehost','startmenuexperiencehost','lockapp','nvidia overlay','nvidia share','widgets')
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class TbrEnum {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  public static List<object[]> List() {
    var res = new List<object[]>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      if (GetWindow(h, 4) != IntPtr.Zero) return true;
      int ex = GetWindowLong(h, -20);
      if ((ex & 0x80) != 0) return true;
      var sb = new StringBuilder(len + 1);
      GetWindowText(h, sb, sb.Capacity);
      uint pid; GetWindowThreadProcessId(h, out pid);
      res.Add(new object[] { (long)h, sb.ToString(), (int)pid });
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@
$byPid = @{}
foreach ($pp in Get-Process) { $byPid[[int]$pp.Id] = $pp }
$windows = @()
foreach ($w in [TbrEnum]::List()) {
  if ("$($w[1])" -eq 'Program Manager') { continue }
  $procObj = $byPid[[int]$w[2]]
  if (-not $procObj) { continue }
  $name = $procObj.ProcessName.ToLower()
  if ($block -contains $name) { continue }
  $wp = $null; try { $wp = $procObj.Path } catch {}
  $windows += [PSCustomObject]@{ hwnd = [string]$w[0]; proc = $name; title = "$($w[1])"; path = $wp }
}
[PSCustomObject]@{
  type = "metrics"
  cpu = if ($cpu -ne $null) { [math]::Round([double]$cpu, 1) } else { $null }
  ram = if ($ram -ne $null) { [math]::Round([double]$ram, 1) } else { $null }
  wifi = $wifi.Trim()
  temperature = if ($temp -ne $null) { [math]::Round([double]$temp, 1) } else { $null }
  running = $running
  windows = $windows
  timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
} | ConvertTo-Json -Compress -Depth 5
''';

  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]).timeout(const Duration(seconds: 8));
    final out = '${result.stdout}'.trim();
    if (result.exitCode != 0 || out.isEmpty) {
      return {'type': 'metrics'};
    }
    final decoded = jsonDecode(out);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'type': 'metrics'};
  } catch (_) {
    return {'type': 'metrics'};
  }
}

Future<List<LaunchableApp>> _loadApps() async {
  const script = r'''
$paths = @(
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
  "$env:AppData\Microsoft\Windows\Start Menu\Programs"
)
$items = foreach ($path in $paths) {
  if (Test-Path $path) {
    Get-ChildItem $path -Recurse -Filter *.lnk | Select-Object @{
      Name="name"; Expression={ $_.BaseName }
    }, @{
      Name="path"; Expression={ $_.FullName }
    }
  }
}
$items | Sort-Object name -Unique | ConvertTo-Json -Compress
''';

  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    script,
  ]);
  if (result.exitCode != 0 || '${result.stdout}'.trim().isEmpty) return [];
  final decoded = jsonDecode('${result.stdout}'.trim());
  final list = decoded is List ? decoded : [decoded];
  return list.whereType<Map>().map((item) {
    final path = '${item['path'] ?? ''}';
    final name = '${item['name'] ?? path}';
    return LaunchableApp(
      id: base64Url.encode(utf8.encode(path)).replaceAll('=', ''),
      name: name,
      path: path,
    );
  }).where((app) => app.path.isNotEmpty).toList();
}

/// Favorites are stored in a single fixed per-user location so they persist
/// across rebuilds/reinstalls and never get scattered into whatever folder the
/// agent happened to launch from.
File _favoritesFile() {
  final base = Platform.environment['APPDATA'] ??
      Platform.environment['LOCALAPPDATA'] ??
      Directory.systemTemp.path;
  final sep = Platform.pathSeparator;
  final dir = Directory('$base${sep}TaskbarRemote');
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
  } catch (_) {}
  return File('${dir.path}${sep}favorites.json');
}

Future<Set<String>> _loadFavorites() async {
  final file = _favoritesFile();
  if (!await file.exists()) return <String>{};
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is List) return decoded.map((e) => '$e').toSet();
  } catch (_) {}
  return <String>{};
}

Future<void> _saveFavorites(Set<String> favorites) async {
  try {
    await _favoritesFile().writeAsString(jsonEncode(favorites.toList()));
  } catch (_) {}
}

class _AppMeta {
  const _AppMeta(this.icons, this.procs);
  final Map<String, String> icons; // id -> base64 PNG
  final Map<String, String> procs; // id -> running-process base name
}

/// For each app shortcut, extracts a small PNG icon AND resolves the target
/// program's process name (used for the running indicator and Close). The app
/// paths go through a temp file and Process.run drains stdout/stderr
/// concurrently, so there is no pipe deadlock on the large payload.
Future<_AppMeta> _loadAppMeta(List<LaunchableApp> apps) async {
  if (apps.isEmpty) return const _AppMeta({}, {});
  const script = r'''
Add-Type -AssemblyName System.Drawing
$shell = New-Object -ComObject WScript.Shell
$paths = Get-Content -Raw -LiteralPath $env:TBR_ICON_PATHS | ConvertFrom-Json
$result = @{}
foreach ($lnk in $paths) {
  $entry = @{ icon = $null; proc = $null }
  try {
    $sc = $shell.CreateShortcut($lnk)
    $target = $sc.TargetPath
    if ($target) { $entry.proc = [System.IO.Path]::GetFileNameWithoutExtension($target).ToLower() }
    $src = $target
    $il = $sc.IconLocation
    if ($il) { $p = ($il -split ',')[0]; if ($p -and (Test-Path $p)) { $src = $p } }
    if (-not $src -or -not (Test-Path $src)) { $src = $lnk }
    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($src)
    if ($icon) {
      $bmp = $icon.ToBitmap()
      $ms = New-Object System.IO.MemoryStream
      $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
      $entry.icon = [Convert]::ToBase64String($ms.ToArray())
      $ms.Dispose(); $bmp.Dispose(); $icon.Dispose()
    }
  } catch {}
  $result[$lnk] = $entry
}
$result | ConvertTo-Json -Compress -Depth 4
''';

  final pathsFile =
      File('${Directory.systemTemp.path}\\taskbar_remote_icons.json');
  try {
    await pathsFile.writeAsString(jsonEncode(apps.map((app) => app.path).toList()));
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
      environment: {'TBR_ICON_PATHS': pathsFile.path},
    ).timeout(const Duration(seconds: 120));
    final out = '${result.stdout}'.trim();
    if (out.isEmpty) return const _AppMeta({}, {});
    final decoded = jsonDecode(out);
    if (decoded is! Map) return const _AppMeta({}, {});
    final idByPath = {for (final app in apps) app.path: app.id};
    final icons = <String, String>{};
    final procs = <String, String>{};
    decoded.forEach((path, entry) {
      final id = idByPath['$path'];
      if (id == null || entry is! Map) return;
      final icon = entry['icon'];
      final proc = entry['proc'];
      if (icon is String && icon.isNotEmpty) icons[id] = icon;
      if (proc is String && proc.isNotEmpty) procs[id] = _aliasProc(proc);
    });
    return _AppMeta(icons, procs);
  } catch (_) {
    return const _AppMeta({}, {});
  }
}

class LaunchableApp {
  const LaunchableApp({required this.id, required this.name, required this.path});

  final String id;
  final String name;
  final String path;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'path': path};
}
