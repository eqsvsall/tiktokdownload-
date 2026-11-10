import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// ====== PENGATURAN (ganti di sini kalau URL / nama berubah) ======
const String kSiteUrl = 'https://cfstiktokdownloader.vercel.app/';
const String kAppTitle = 'TIKTOK DOWNLOADER';
const Duration kMinSplash = Duration(milliseconds: 3500);
const Duration kMaxWait = Duration(seconds: 20);
const Color kSplashBg = Color(0xFF0B0B0D); // background splash (dark minimal)
const Color kSiteBg = Color(0xFF0B0B0D); // background website (dark)
/// =================================================================

const MethodChannel _native = MethodChannel('cfs/native');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TikTok Downloader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.black),
      home: const Root(),
    );
  }
}

/// Script yang disuntik ke website: membuat tombol "simpan" mengirim file
/// ke app (potongan base64), karena WebView tidak bisa download blob sendiri.
const String kBridgeJs = r'''
(function () {
  if (window.__sallBridge) return;
  window.__sallBridge = true;
  var CH = 786432; // kelipatan 3 supaya base64 per potongan valid
  window.saveBlob = function (blob, name) {
    var id = Date.now() + '' + Math.random().toString(36).slice(2, 6);
    function send(o) { SallApp.postMessage(JSON.stringify(o)); }
    send({ t: 'start', id: id, name: name, mime: blob.type || '' });
    var off = 0;
    (function next() {
      if (off >= blob.size) { send({ t: 'end', id: id }); return; }
      var fr = new FileReader();
      fr.onload = function () {
        var s = fr.result;
        send({ t: 'chunk', id: id, d: s.substring(s.indexOf(',') + 1) });
        off += CH;
        setTimeout(next, 0);
      };
      fr.onerror = function () { send({ t: 'error', id: id }); };
      fr.readAsDataURL(blob.slice(off, off + CH));
    })();
  };
})();
''';

class _Incoming {
  _Incoming(this.name, this.mime);
  final String name;
  final String mime;
  late File file;
  IOSink? sink;
  Future<void> chain = Future.value();
}

/// Menerima file dari website, menyimpan ke folder Download, lalu notifikasi.
class DownloadBridge {
  final Map<String, _Incoming> _items = {};
  int _notifId = 100;

  Future<void> requestPermission() async {
    try {
      await _native.invokeMethod('requestNotif');
    } catch (_) {}
  }

  void handle(String raw) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = m['id'] as String? ?? '';
    switch (m['t']) {
      case 'start':
        final it = _Incoming(_cleanName(m['name'] as String?), _mime(m['mime'] as String?, m['name'] as String?));
        _items[id] = it;
        it.chain = it.chain.then((_) async {
          final dir = await getTemporaryDirectory();
          it.file = File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}_${it.name}');
          it.sink = it.file.openWrite();
        });
        break;
      case 'chunk':
        final it = _items[id];
        if (it == null) return;
        final bytes = base64Decode(m['d'] as String);
        it.chain = it.chain.then((_) async {
          it.sink?.add(bytes);
        });
        break;
      case 'end':
        final it = _items.remove(id);
        if (it == null) return;
        it.chain = it.chain.then((_) => _finish(it));
        break;
      case 'error':
        final it = _items.remove(id);
        if (it == null) return;
        it.chain = it.chain.then((_) async {
          await it.sink?.close();
          await _notify('Download gagal', it.name);
        });
        break;
    }
  }

  Future<void> _finish(_Incoming it) async {
    try {
      await it.sink?.flush();
      await it.sink?.close();
      await _native.invokeMethod('saveToDownloads', {
        'path': it.file.path,
        'name': it.name,
        'mime': it.mime,
      });
      await _notify('Download selesai', '${it.name} tersimpan di folder Download/TikTokDownloader');
    } catch (_) {
      await _notify('Download gagal', it.name);
    } finally {
      try {
        if (await it.file.exists()) await it.file.delete();
      } catch (_) {}
    }
  }

  Future<void> _notify(String title, String body) async {
    try {
      await _native.invokeMethod('notify', {'id': _notifId++, 'title': title, 'body': body});
    } catch (_) {}
  }

  String _cleanName(String? n) {
    final s = (n ?? 'tiktok').replaceAll(RegExp(r'[^\w.\- ]+'), '_');
    return s.isEmpty ? 'tiktok' : s;
  }

  String _mime(String? m, String? name) {
    if (m != null && m.isNotEmpty) return m;
    final n = (name ?? '').toLowerCase();
    if (n.endsWith('.mp4')) return 'video/mp4';
    if (n.endsWith('.mp3')) return 'audio/mpeg';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }
}

enum Phase { splash, web, error }

class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  late final WebViewController _c;
  final DownloadBridge _bridge = DownloadBridge();
  Phase _phase = Phase.splash;
  bool _ready = false; // website sudah selesai dimuat
  Completer<bool> _loaded = Completer<bool>();

  @override
  void initState() {
    super.initState();
    final siteHost = Uri.parse(kSiteUrl).host;

    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(kSiteBg)
      ..addJavaScriptChannel('SallApp', onMessageReceived: (m) => _bridge.handle(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) {
          final u = Uri.tryParse(r.url);
          if (u == null) return NavigationDecision.prevent;
          if (u.host == siteHost || u.scheme == 'about' || u.scheme == 'blob' || u.scheme == 'data') {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
        onPageFinished: (_) {
          _c.runJavaScript(kBridgeJs);
          if (!_loaded.isCompleted) _loaded.complete(true);
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame != true) return;
          if (!_loaded.isCompleted) {
            _loaded.complete(false);
          } else if (mounted) {
            setState(() => _phase = Phase.error);
          }
        },
      ));

    _bridge.requestPermission();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _phase = Phase.splash;
      _ready = false;
    });
    if (_loaded.isCompleted) _loaded = Completer<bool>();
    _c.loadRequest(Uri.parse(kSiteUrl));

    final minWait = Future<void>.delayed(kMinSplash);
    final ok = await _loaded.future.timeout(kMaxWait, onTimeout: () => false);
    if (mounted) setState(() => _ready = ok);
    await minWait;
    await Future<void>.delayed(const Duration(milliseconds: 300)); // biar bar penuh dulu
    if (!mounted) return;
    setState(() => _phase = ok ? Phase.web : Phase.error);
  }

  Future<void> _onBack() async {
    if (_phase == Phase.web && await _c.canGoBack()) {
      await _c.goBack();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    switch (_phase) {
      case Phase.splash:
        child = SplashView(key: const ValueKey('splash'), ready: _ready);
        break;
      case Phase.web:
        child = AnnotatedRegion<SystemUiOverlayStyle>(
          key: const ValueKey('web'),
          value: _lightIcons,
          child: Scaffold(
            backgroundColor: kSiteBg,
            body: SafeArea(child: WebViewWidget(controller: _c)),
          ),
        );
        break;
      case Phase.error:
        child = ErrorView(key: const ValueKey('error'), onRetry: _boot);
        break;
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 700),
        switchInCurve: Curves.easeOut,
        transitionBuilder: (c, anim) {
          if (c.key == const ValueKey('splash')) {
            // splash keluar dengan zoom-through + fade
            return FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 1.18, end: 1.0).animate(anim),
                child: c,
              ),
            );
          }
          return FadeTransition(opacity: anim, child: c);
        },
        child: child,
      ),
    );
  }
}

const Color kAccent = Color(0xFF25F4EE);

const SystemUiOverlayStyle _lightIcons = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
);
const SystemUiOverlayStyle _darkIcons = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.dark,
);

class _Particle {
  const _Particle(this.x, this.y, this.speed, this.size, this.alpha);
  final double x, y, speed, size, alpha;
}

/// Titik-titik halus yang melayang pelan di background.
class _DriftPainter extends CustomPainter {
  _DriftPainter(this.t, this.ps) : super(repaint: t);
  final Animation<double> t;
  final List<_Particle> ps;

  @override
  void paint(Canvas canvas, Size s) {
    final paint = Paint();
    for (final p in ps) {
      final y = (p.y - t.value * p.speed) % 1.0;
      final twinkle = 0.65 + 0.35 * sin(t.value * 2 * pi * 3 + p.x * 12);
      paint.color = Color.fromRGBO(255, 255, 255, (p.alpha * twinkle).clamp(0.0, 1.0));
      canvas.drawCircle(Offset(p.x * s.width, y * s.height), p.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DriftPainter old) => false;
}

/// Cincin tipis yang memancar dari belakang logo.
class _RingPainter extends CustomPainter {
  _RingPainter(this.pulse, this.intro) : super(repaint: Listenable.merge([pulse, intro]));
  final Animation<double> pulse;
  final Animation<double> intro;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final appear = const Interval(0.10, 0.50, curve: Curves.easeOut).transform(intro.value);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (int i = 0; i < 3; i++) {
      final ph = (pulse.value + i / 3) % 1.0;
      final r = size.width * 0.20 + ph * size.width * 0.45;
      final a = (1 - ph) * 0.26 * appear;
      paint.color = Color.fromRGBO(37, 244, 238, a.clamp(0.0, 1.0));
      canvas.drawCircle(c, r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => false;
}

class SplashView extends StatefulWidget {
  const SplashView({super.key, required this.ready});
  final bool ready;

  @override
  State<SplashView> createState() => _SplashViewState();
}

class _SplashViewState extends State<SplashView> with TickerProviderStateMixin {
  late final AnimationController _intro =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..forward();
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3600))..repeat();
  late final AnimationController _drift =
      AnimationController(vsync: this, duration: const Duration(seconds: 22))..repeat();
  late final List<_Particle> _ps = _makeParticles();

  List<_Particle> _makeParticles() {
    final r = Random(7);
    return List.generate(
      36,
      (i) => _Particle(
        r.nextDouble(),
        r.nextDouble(),
        r.nextBool() ? 1.0 : 2.0,
        0.6 + r.nextDouble() * 1.6,
        0.10 + r.nextDouble() * 0.30,
      ),
    );
  }

  @override
  void dispose() {
    _intro.dispose();
    _pulse.dispose();
    _drift.dispose();
    super.dispose();
  }

  Widget _letter(String ch, int i) {
    if (ch == ' ') return const SizedBox(width: 12);
    final s = 0.50 + i * 0.022;
    final e = (s + 0.15).clamp(0.0, 1.0).toDouble();
    final t = Interval(s, e, curve: Curves.easeOutCubic).transform(_intro.value);
    return Opacity(
      opacity: t,
      child: Transform.translate(
        offset: Offset(0, (1 - t) * 12),
        child: Text(
          ch,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 3,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final logoW = (w * 0.6).clamp(180.0, 380.0).toDouble();
    final box = logoW * 1.5;
    final chars = kAppTitle.split('');

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _lightIcons,
      child: Scaffold(
        backgroundColor: kSplashBg,
        body: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(painter: _DriftPainter(_drift, _ps)),
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: box,
                    height: box * 0.62,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(painter: _RingPainter(_pulse, _intro)),
                        ),
                        AnimatedBuilder(
                          animation: _intro,
                          child: Image.asset('assets/logo-white.png', width: logoW, fit: BoxFit.contain),
                          builder: (_, child) {
                            final v = _intro.value;
                            final fade = const Interval(0.0, 0.35, curve: Curves.easeIn).transform(v);
                            final sc = 0.7 + 0.3 * const Interval(0.0, 0.6, curve: Curves.easeOutBack).transform(v);
                            final sw = const Interval(0.45, 0.85, curve: Curves.easeInOut).transform(v);
                            final p = -0.3 + sw * 1.6;
                            return Opacity(
                              opacity: fade.clamp(0.0, 1.0),
                              child: Transform.scale(
                                scale: sc,
                                child: ShaderMask(
                                  blendMode: BlendMode.srcATop,
                                  shaderCallback: (rect) => LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    colors: const [Colors.transparent, kAccent, Colors.transparent],
                                    stops: [
                                      (p - 0.18).clamp(0.0, 1.0).toDouble(),
                                      p.clamp(0.0, 1.0).toDouble(),
                                      (p + 0.18).clamp(0.0, 1.0).toDouble(),
                                    ],
                                  ).createShader(rect),
                                  child: child,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  AnimatedBuilder(
                    animation: _intro,
                    builder: (_, __) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [for (int i = 0; i < chars.length; i++) _letter(chars[i], i)],
                    ),
                  ),
                  const SizedBox(height: 12),
                  AnimatedBuilder(
                    animation: _intro,
                    builder: (_, __) => Opacity(
                      opacity: const Interval(0.8, 1.0, curve: Curves.easeOut).transform(_intro.value),
                      child: const Text(
                        'Preparing your experience...',
                        style: TextStyle(fontSize: 13, color: Color(0xFF8A8A93), letterSpacing: 0.6),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  AnimatedBuilder(
                    animation: _intro,
                    builder: (_, child) => Opacity(
                      opacity: const Interval(0.7, 1.0, curve: Curves.easeOut).transform(_intro.value),
                      child: child,
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: const [BoxShadow(color: Color(0x5925F4EE), blurRadius: 10)],
                      ),
                      child: SizedBox(
                        width: 170,
                        height: 2,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0, end: widget.ready ? 1.0 : 0.9),
                            duration: widget.ready
                                ? const Duration(milliseconds: 300)
                                : const Duration(milliseconds: 3000),
                            curve: Curves.easeInOut,
                            builder: (_, v, __) => LinearProgressIndicator(
                              value: v,
                              minHeight: 2,
                              backgroundColor: const Color(0x22FFFFFF),
                              valueColor: const AlwaysStoppedAnimation<Color>(kAccent),
                            ),
                          ),
                        ),
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

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _lightIcons,
      child: Scaffold(
        backgroundColor: kSplashBg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/logo-white.png', width: 180),
                const SizedBox(height: 18),
                const Text(
                  'Gagal memuat',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Cek koneksi internet kamu, lalu coba lagi.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF8A8A93)),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                  onPressed: onRetry,
                  child: const Text('Coba lagi'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
