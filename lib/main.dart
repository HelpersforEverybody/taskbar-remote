import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

const int kListenPort = 8765;

// ---- Instrument / control-surface palette ----
const _ink = Color(0xFF0C0F14);
const _panel = Color(0xFF141923);
const _panel2 = Color(0xFF1B2330);
const _line = Color(0xFF252E3C);
const _amber = Color(0xFFF4A93C);
const _amberHi = Color(0xFFFFC571);
const _green = Color(0xFF54D6A0);
const _red = Color(0xFFF0635B);
const _textc = Color(0xFFEAEFF6);
const _muted = Color(0xFF8794A6);
const _dim = Color(0xFF5A6577);

const _mono = 'SpaceMono';
const _grotesk = 'SpaceGrotesk';

final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() {
  runApp(const TaskbarRemoteApp());
}

class TaskbarRemoteApp extends StatelessWidget {
  const TaskbarRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: rootMessengerKey,
      title: 'Taskbar Remote',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _ink,
        fontFamily: _grotesk,
        colorScheme: const ColorScheme.dark(
          primary: _amber,
          surface: _panel,
        ),
        useMaterial3: true,
      ),
      home: const RemoteHomePage(),
    );
  }
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage> {
  final _searchController = TextEditingController();
  final ValueNotifier<int> _rev = ValueNotifier<int>(0);

  HttpServer? _server;
  WebSocket? _agent;
  bool _connected = false;
  String _error = '';
  String _myIp = '…';
  String _token = '';
  Metrics _metrics = Metrics.empty();
  List<RemoteApp> _apps = [];
  final Map<String, Uint8List> _icons = {};
  Set<String> _favorites = {};
  Set<String> _running = {};
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
    _startServer();
  }

  @override
  void dispose() {
    _agent?.close();
    _server?.close(force: true);
    _searchController.dispose();
    _rev.dispose();
    super.dispose();
  }

  // Update state and notify any open child page (Quick page / add sheet).
  void _update(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
    _rev.value++;
  }

  Future<void> _startServer() async {
    _token = await _loadOrCreateToken();
    _myIp = await _localIp();
    if (mounted) setState(() {});
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, kListenPort);
      _server = server;
      server.listen((request) async {
        if (request.uri.path != '/agent' ||
            request.uri.queryParameters['token'] != _token) {
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          return;
        }
        try {
          final socket = await WebSocketTransformer.upgrade(request);
          _onAgentConnected(socket);
        } catch (_) {}
      });
      if (mounted) setState(() {});
    } catch (error) {
      setState(() => _error = 'Could not start on port $kListenPort: $error');
    }
  }

  void _onAgentConnected(WebSocket socket) {
    _agent?.close();
    _agent = socket;
    socket.pingInterval = const Duration(seconds: 10);
    _update(() {
      _connected = true;
      _error = '';
    });
    socket.listen(
      _handleMessage,
      onDone: () {
        if (!mounted) return;
        if (identical(_agent, socket)) _agent = null;
        _update(() {
          _connected = false;
          _running = {};
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        if (identical(_agent, socket)) _agent = null;
        _update(() => _connected = false);
      },
      cancelOnError: true,
    );
  }

  void _handleMessage(dynamic data) {
    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      final type = message['type'];
      if (type == 'metrics') {
        _update(() => _metrics = Metrics.fromJson(message));
      } else if (type == 'apps') {
        final items = (message['apps'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => RemoteApp.fromJson(item.cast<String, dynamic>()))
            .toList();
        final favs =
            (message['favorites'] as List? ?? const []).map((e) => '$e').toSet();
        _update(() {
          _apps = items;
          _favorites = favs;
        });
      } else if (type == 'icons') {
        final raw = (message['icons'] as Map?) ?? const {};
        final decoded = <String, Uint8List>{};
        raw.forEach((key, value) {
          if (value is String) {
            try {
              decoded['$key'] = base64Decode(value);
            } catch (_) {}
          }
        });
        _update(() => _icons.addAll(decoded));
      } else if (type == 'running') {
        final ids =
            (message['ids'] as List? ?? const []).map((e) => '$e').toSet();
        _update(() => _running = ids);
      } else if (type == 'launchResult') {
        final appName = message['name'] ?? 'App';
        final ok = message['ok'] == true;
        _toast(ok ? 'Opening $appName on PC…' : 'Failed: $appName');
      } else if (type == 'error') {
        setState(() => _error = '${message['message'] ?? 'Agent error'}');
      }
    } catch (error) {
      setState(() => _error = 'Bad message from PC: $error');
    }
  }

  void _toast(String text) {
    rootMessengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 1400),
          backgroundColor: _panel2,
          content: Text(text, style: const TextStyle(color: _textc)),
        ),
      );
  }

  void _send(Map<String, dynamic> msg) {
    final socket = _agent;
    if (socket == null || socket.readyState != WebSocket.open) {
      _toast('PC is not connected yet.');
      return;
    }
    socket.add(jsonEncode(msg));
  }

  void _launch(RemoteApp app) => _send({'type': 'launch', 'id': app.id});

  void _closeApp(RemoteApp app) {
    _send({'type': 'close', 'id': app.id});
    _toast('Closing ${app.name}…');
  }

  void _toggleFavorite(RemoteApp app) {
    final isFav = _favorites.contains(app.id);
    _update(() {
      if (isFav) {
        _favorites.remove(app.id);
      } else {
        _favorites.add(app.id);
      }
    });
    _agent?.add(jsonEncode(
        {'type': 'setFavorite', 'id': app.id, 'value': !isFav}));
  }

  Widget _appIcon(RemoteApp app, double size) {
    final bytes = _icons[app.id];
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: size,
        height: size,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => Icon(Icons.apps, size: size, color: _muted),
      );
    }
    return Icon(Icons.apps, size: size, color: _muted);
  }

  void _openQuickPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QuickPage(
          revision: _rev,
          favoriteApps: () =>
              _apps.where((a) => _favorites.contains(a.id)).toList(),
          allApps: () => _apps,
          isFavorite: (id) => _favorites.contains(id),
          isRunning: (id) => _running.contains(id),
          iconBuilder: _appIcon,
          onLaunch: _launch,
          onClose: _closeApp,
          onToggleFavorite: _toggleFavorite,
        ),
      ),
    );
  }

  Future<String> _loadOrCreateToken() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/tbr_token.txt');
      if (await file.exists()) {
        final existing = (await file.readAsString()).trim();
        if (existing.isNotEmpty) return existing;
      }
      final token = _randomToken();
      await file.writeAsString(token);
      return token;
    } catch (_) {
      return _randomToken();
    }
  }

  String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<String> _localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      final addresses =
          interfaces.expand((i) => i.addresses).map((a) => a.address).toList();
      for (final address in addresses) {
        if (address.startsWith('192.168.') ||
            address.startsWith('10.') ||
            RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(address)) {
          return address;
        }
      }
      return addresses.isNotEmpty ? addresses.first : '0.0.0.0';
    } catch (_) {
      return '0.0.0.0';
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _apps
        .where((a) => _query.isEmpty || a.name.toLowerCase().contains(_query))
        .toList();

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(connected: _connected, ip: _myIp, onQuick: _openQuickPage),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                children: [
                  if (!_connected)
                    _ConnectCard(ip: _myIp, token: _token, error: _error),
                  if (!_connected) const SizedBox(height: 16),
                  _MetricsGrid(metrics: _metrics),
                  const SizedBox(height: 18),
                  _SearchField(controller: _searchController),
                  const SizedBox(height: 16),
                  _Eyebrow('All apps · ${_apps.length}'),
                  const SizedBox(height: 10),
                  if (filtered.isEmpty)
                    const _Empty()
                  else
                    ...filtered.map(
                      (app) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _AppRow(
                          app: app,
                          icon: _appIcon(app, 30),
                          inQuick: _favorites.contains(app.id),
                          onTap: () => _launch(app),
                          onToggle: () => _toggleFavorite(app),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- Header ----------------
class _Header extends StatelessWidget {
  const _Header(
      {required this.connected, required this.ip, required this.onQuick});
  final bool connected;
  final String ip;
  final VoidCallback onQuick;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TASKBAR REMOTE',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                    color: _textc,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: connected ? _green : _amber,
                        boxShadow: [
                          BoxShadow(
                            color: (connected ? _green : _amber).withValues(
                                alpha: 0.6),
                            blurRadius: 7,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      connected ? 'LINKED · $ip' : 'WAITING FOR PC',
                      style: TextStyle(
                        fontFamily: _mono,
                        fontSize: 10.5,
                        letterSpacing: 0.5,
                        color: connected ? _green : _amber,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onQuick,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF3A2A12), Color(0xFF241A0D)],
                ),
                border: Border.all(color: const Color(0xFF5A4220)),
              ),
              child: const Icon(Icons.bolt, color: _amberHi, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- Connect card (waiting) ----------------
class _ConnectCard extends StatelessWidget {
  const _ConnectCard(
      {required this.ip, required this.token, required this.error});
  final String ip;
  final String token;
  final String error;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Run the agent on your PC and enter:',
              style: TextStyle(color: _muted, fontSize: 13)),
          const SizedBox(height: 10),
          _kv('PHONE IP', '$ip:$kListenPort'),
          const SizedBox(height: 7),
          _kv('TOKEN', token),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(error,
                style: const TextStyle(color: _red, fontSize: 12.5)),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF0E131B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(k,
                style: const TextStyle(
                    fontFamily: _mono,
                    fontSize: 10,
                    letterSpacing: 1,
                    color: _dim)),
          ),
          Expanded(
            child: SelectableText(v,
                style: const TextStyle(
                    fontFamily: _mono, fontSize: 13, color: _textc)),
          ),
        ],
      ),
    );
  }
}

// ---------------- Metrics ----------------
class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.metrics});
  final Metrics metrics;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 11,
      mainAxisSpacing: 11,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.55,
      children: [
        _MetricTile(
          label: 'CPU',
          value: metrics.cpu,
          unit: '%',
          meter: metrics.cpu,
        ),
        _MetricTile(
          label: 'RAM',
          value: metrics.ram,
          unit: '%',
          meter: metrics.ram,
        ),
        _WifiTile(wifi: metrics.wifi),
        _MetricTile(
          label: 'TEMP',
          value: metrics.temperature,
          unit: ' C',
          missingLabel: 'no sensor',
        ),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.unit,
    this.meter,
    this.missingLabel = '--',
  });
  final String label;
  final double? value;
  final String unit;
  final double? meter;
  final String missingLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(label),
          const Spacer(),
          if (value == null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Text('—',
                    style: TextStyle(
                        fontFamily: _mono,
                        fontSize: 24,
                        color: _dim,
                        fontWeight: FontWeight.bold)),
                const SizedBox(width: 6),
                Text(missingLabel,
                    style: const TextStyle(
                        fontFamily: _mono, fontSize: 11, color: _dim)),
              ],
            )
          else
            RichText(
              text: TextSpan(
                text: value!.round().toString(),
                style: const TextStyle(
                    fontFamily: _mono,
                    fontSize: 27,
                    fontWeight: FontWeight.bold,
                    color: _textc),
                children: [
                  TextSpan(
                      text: unit,
                      style: const TextStyle(
                          fontFamily: _mono,
                          fontSize: 13,
                          fontWeight: FontWeight.normal,
                          color: _muted)),
                ],
              ),
            ),
          if (meter != null) ...[
            const SizedBox(height: 11),
            _SegMeter(value: meter!),
          ],
        ],
      ),
    );
  }
}

class _WifiTile extends StatelessWidget {
  const _WifiTile({required this.wifi});
  final String wifi;

  @override
  Widget build(BuildContext context) {
    final pctMatch = RegExp(r'(\d+)\s*%').firstMatch(wifi);
    final pct = pctMatch != null ? int.tryParse(pctMatch.group(1)!) ?? 0 : 0;
    final name = wifi.replaceAll(RegExp(r'\s*\d+\s*%'), '').trim();
    final lit = (pct / 25).ceil().clamp(0, 4);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('WI-FI'),
          const Spacer(),
          Text(
            name.isEmpty ? '--' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontFamily: _mono,
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: _textc),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(4, (i) {
              return Container(
                width: 5,
                height: 7.0 + i * 4,
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1),
                  color: i < lit ? _green : const Color(0xFF2A3340),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _SegMeter extends StatelessWidget {
  const _SegMeter({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    const segments = 20;
    final lit = (value / 100 * segments).round().clamp(0, segments);
    final hot = value >= 85;
    return SizedBox(
      height: 13,
      child: Row(
        children: List.generate(segments, (i) {
          final on = i < lit;
          return Expanded(
            child: Container(
              height: 13,
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(1),
                color: on
                    ? (hot ? _red : _amber)
                    : const Color(0xFF222B38),
                boxShadow: on
                    ? [
                        BoxShadow(
                            color: (hot ? _red : _amber)
                                .withValues(alpha: 0.4),
                            blurRadius: 4)
                      ]
                    : null,
              ),
            ),
          );
        }),
      ),
    );
  }
}

Widget _label(String s) => Text(
      s,
      style: const TextStyle(
        fontFamily: _mono,
        fontSize: 10,
        letterSpacing: 1.6,
        color: _muted,
      ),
    );

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontFamily: _mono,
          fontSize: 10,
          letterSpacing: 1.6,
          color: _dim,
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});
  final TextEditingController controller;
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontFamily: _mono, fontSize: 14, color: _textc),
      cursorColor: _amber,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
        prefixIcon: const Icon(Icons.search, color: _dim, size: 20),
        hintText: 'search apps',
        hintStyle: const TextStyle(fontFamily: _mono, color: _dim, fontSize: 14),
        filled: true,
        fillColor: const Color(0xFF0E131B),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _amber),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _line),
      ),
      child: const Text('No PC apps yet. Start the agent on your PC.',
          style: TextStyle(color: _muted)),
    );
  }
}

// ---------------- App row (home list) ----------------
class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.icon,
    required this.inQuick,
    required this.onTap,
    required this.onToggle,
  });
  final RemoteApp app;
  final Widget icon;
  final bool inQuick;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onTap: onTap,
      radius: BorderRadius.circular(11),
      builder: (t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Color.lerp(_panel, _panel2, t),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: Color.lerp(_line, _amber, t)!),
        ),
        child: Row(
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(7), child: icon),
            const SizedBox(width: 13),
            Expanded(
              child: Text(app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: _textc)),
            ),
            _MiniBtn(
              onTap: onToggle,
              filled: inQuick,
              child: Icon(inQuick ? Icons.check : Icons.add,
                  size: inQuick ? 16 : 17,
                  color: inQuick ? const Color(0xFF1A1206) : _muted),
            ),
            const SizedBox(width: 9),
            _MiniBtn(
              onTap: onTap,
              child: const Icon(Icons.play_arrow, size: 16, color: _amberHi),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  const _MiniBtn(
      {required this.child, required this.onTap, this.filled = false});
  final Widget child;
  final VoidCallback onTap;
  final bool filled;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: filled ? _amber : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: filled ? _amber : _line),
        ),
        child: Center(child: child),
      ),
    );
  }
}

// ---------------- Pressable (guaranteed amber pulse) ----------------
class _Pressable extends StatefulWidget {
  const _Pressable(
      {required this.builder, required this.onTap, required this.radius});
  final Widget Function(double t) builder;
  final VoidCallback onTap;
  final BorderRadius radius;
  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
    reverseDuration: const Duration(milliseconds: 180),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _pulse() {
    _c.forward(from: 0).then((_) {
      if (mounted) _c.reverse();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeOut.transform(_c.value);
        return Transform.scale(
          scale: 1 - 0.06 * t,
          child: Material(
            color: Colors.transparent,
            borderRadius: widget.radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: widget.radius,
              splashColor: _amber.withValues(alpha: 0.32),
              highlightColor: Colors.transparent,
              onTap: () {
                widget.onTap();
                _pulse();
              },
              child: widget.builder(t),
            ),
          ),
        );
      },
    );
  }
}

// ---------------- Quick page ----------------
class QuickPage extends StatelessWidget {
  const QuickPage({
    super.key,
    required this.revision,
    required this.favoriteApps,
    required this.allApps,
    required this.isFavorite,
    required this.isRunning,
    required this.iconBuilder,
    required this.onLaunch,
    required this.onClose,
    required this.onToggleFavorite,
  });

  final Listenable revision;
  final List<RemoteApp> Function() favoriteApps;
  final List<RemoteApp> Function() allApps;
  final bool Function(String id) isFavorite;
  final bool Function(String id) isRunning;
  final Widget Function(RemoteApp app, double size) iconBuilder;
  final void Function(RemoteApp app) onLaunch;
  final void Function(RemoteApp app) onClose;
  final void Function(RemoteApp app) onToggleFavorite;

  void _openAddSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF10141C),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        side: BorderSide(color: _line),
      ),
      builder: (_) => _AddSheet(
        revision: revision,
        allApps: allApps,
        isFavorite: isFavorite,
        iconBuilder: iconBuilder,
        onToggle: onToggleFavorite,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
              decoration:
                  const BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, color: _textc),
                  ),
                  const Text('QUICK',
                      style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.6,
                          color: _textc)),
                ],
              ),
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: revision,
                builder: (context, _) {
                  final favs = favoriteApps();
                  return GridView.count(
                    crossAxisCount: 3,
                    padding: const EdgeInsets.all(18),
                    crossAxisSpacing: 13,
                    mainAxisSpacing: 13,
                    childAspectRatio: 0.62,
                    children: [
                      ...favs.map((app) => _QuickTile(
                            app: app,
                            icon: iconBuilder(app, 42),
                            running: isRunning(app.id),
                            onTap: () => onLaunch(app),
                            onRemove: () => onToggleFavorite(app),
                            onClose: () => onClose(app),
                          )),
                      _AddTile(onTap: () => _openAddSheet(context)),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.app,
    required this.icon,
    required this.running,
    required this.onTap,
    required this.onRemove,
    required this.onClose,
  });
  final RemoteApp app;
  final Widget icon;
  final bool running;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onTap: onTap,
      radius: BorderRadius.circular(14),
      builder: (t) => Container(
        decoration: BoxDecoration(
          color: Color.lerp(_panel, _panel2, t),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Color.lerp(_line, _amber, t)!),
        ),
        child: Stack(
          children: [
            Column(
              children: [
                // Icon + name centered in the space above the Close button.
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 16, 6, 2),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: icon),
                          const SizedBox(height: 8),
                          Text(app.name,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                  color: _textc)),
                        ],
                      ),
                    ),
                  ),
                ),
                // Close pinned to the bottom — never overflows.
                if (running)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GestureDetector(
                      onTap: onClose,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A1518),
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(color: const Color(0xFF5E2329)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(Icons.close_rounded,
                                size: 11, color: Color(0xFFF6A9A3)),
                            SizedBox(width: 4),
                            Text('Close',
                                style: TextStyle(
                                    fontFamily: _mono,
                                    fontSize: 9.5,
                                    letterSpacing: 0.5,
                                    color: Color(0xFFF6A9A3))),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            // green running dot (top-left, inside bounds)
            if (running)
              Positioned(
                top: 9,
                left: 9,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _green,
                    boxShadow: [
                      BoxShadow(
                          color: _green.withValues(alpha: 0.6), blurRadius: 6),
                    ],
                  ),
                ),
              ),
            // red remove X (top-right, inside bounds)
            Positioned(
              top: 2,
              right: 2,
              child: GestureDetector(
                onTap: onRemove,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(7),
                  child: Icon(Icons.close, size: 15, color: _red),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onTap: onTap,
      radius: BorderRadius.circular(14),
      builder: (t) => DottedBorderBox(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: const Color(0xFF2A2010),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.add, color: _amberHi, size: 26),
            ),
            const SizedBox(height: 9),
            const Text('Add app',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: _amberHi)),
          ],
        ),
      ),
    );
  }
}

class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashPainter(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 26, 6, 10),
        child: Center(child: child),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF34414F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(14));
    final path = Path()..addRRect(rrect);
    const dash = 5.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        canvas.drawPath(
            metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------- Add sheet ----------------
class _AddSheet extends StatefulWidget {
  const _AddSheet({
    required this.revision,
    required this.allApps,
    required this.isFavorite,
    required this.iconBuilder,
    required this.onToggle,
  });
  final Listenable revision;
  final List<RemoteApp> Function() allApps;
  final bool Function(String id) isFavorite;
  final Widget Function(RemoteApp app, double size) iconBuilder;
  final void Function(RemoteApp app) onToggle;

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  final _ctrl = TextEditingController();
  String _q = '';

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() => _q = _ctrl.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF33414F),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const Text('Add to Quick',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _textc)),
              const SizedBox(height: 13),
              _SearchField(controller: _ctrl),
              const SizedBox(height: 6),
              Expanded(
                child: AnimatedBuilder(
                  animation: widget.revision,
                  builder: (context, _) {
                    final list = widget
                        .allApps()
                        .where((a) =>
                            _q.isEmpty || a.name.toLowerCase().contains(_q))
                        .toList();
                    return ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final app = list[i];
                        final on = widget.isFavorite(app.id);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                            children: [
                              ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: widget.iconBuilder(app, 26)),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Text(app.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 14, color: _textc)),
                              ),
                              _Toggle(
                                  value: on,
                                  onChanged: () => widget.onToggle(app)),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});
  final bool value;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChanged,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 38,
        height: 22,
        decoration: BoxDecoration(
          color: value ? _amber : const Color(0xFF323D4B),
          borderRadius: BorderRadius.circular(11),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 150),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? const Color(0xFF1A1206) : const Color(0xFFCBD5E1),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- Models ----------------
class Metrics {
  const Metrics({
    required this.cpu,
    required this.ram,
    required this.wifi,
    required this.temperature,
  });

  factory Metrics.empty() =>
      const Metrics(cpu: null, ram: null, wifi: '', temperature: null);

  factory Metrics.fromJson(Map<String, dynamic> json) {
    double? asDouble(Object? v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }

    return Metrics(
      cpu: asDouble(json['cpu']),
      ram: asDouble(json['ram']),
      wifi: '${json['wifi'] ?? ''}',
      temperature: asDouble(json['temperature']),
    );
  }

  final double? cpu;
  final double? ram;
  final String wifi;
  final double? temperature;
}

class RemoteApp {
  const RemoteApp({required this.id, required this.name, required this.path});

  factory RemoteApp.fromJson(Map<String, dynamic> json) => RemoteApp(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? 'Unknown'}',
        path: '${json['path'] ?? ''}',
      );

  final String id;
  final String name;
  final String path;
}
