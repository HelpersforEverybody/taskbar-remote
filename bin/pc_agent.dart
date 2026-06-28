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

      // Push metrics + the set of running app ids together.
      void pushMetrics(Map<String, dynamic> metrics) {
        if (socket.readyState != WebSocket.open) return;
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

      // Handle launch / favorite / close commands until the socket closes.
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
      stdout.writeln('Disconnected from phone.');
    } catch (error) {
      stdout.writeln('Connection failed: $error');
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
}

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
      final cid = '${message['id'] ?? ''}';
      final procName = procById[cid];
      if (procName != null && procName.isNotEmpty) {
        await Process.run(
          'powershell.exe',
          ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', _closeScript],
          environment: {'TBR_CLOSE': procName},
        );
      }
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
[PSCustomObject]@{
  type = "metrics"
  cpu = if ($cpu -ne $null) { [math]::Round([double]$cpu, 1) } else { $null }
  ram = if ($ram -ne $null) { [math]::Round([double]$ram, 1) } else { $null }
  wifi = $wifi.Trim()
  temperature = if ($temp -ne $null) { [math]::Round([double]$temp, 1) } else { $null }
  running = $running
  timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
} | ConvertTo-Json -Compress
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
      if (proc is String && proc.isNotEmpty) procs[id] = proc;
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
