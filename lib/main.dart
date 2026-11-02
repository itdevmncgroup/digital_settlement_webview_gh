import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Web mobile entry (digital_settlement_fe, route group `/m/*`). `/` redirects
/// to the first page the logged-in user may open, so it works for every role.
/// The FE reaches its backend itself (relative `/api/v1`, proxied server-side),
/// so the app only needs this one address.
///
/// Override per build:
///   flutter run --dart-define=APP_URL=https://digital-settlement.mncgroup.com
const String kAppUrl = String.fromEnvironment(
  'APP_URL',
  defaultValue: 'https://earlobe-neutron-pushchair.ngrok-free.dev',
);

/// A free ngrok tunnel answers any request whose User-Agent looks like a
/// browser with an HTML warning page - including the JS/CSS the app needs, which
/// would leave the page blank. A custom UA skips that page. It keeps "Android" and
/// "Mobile" because the FE picks its mobile layout from those words.
const String kUserAgent = 'DigitalSettlementApp/1.0 (Android; Mobile)';

/// Max time without any load progress before the app gives up and offers
/// "Coba lagi" instead of an endless blank screen.
const Duration kLoadTimeout = Duration(seconds: 20);

/// How often the GPS switch is re-checked while the app is open, so turning it off mid-use
/// brings the "Aktifkan GPS" screen back (there is no push event for it).
const Duration kGpsPollInterval = Duration(seconds: 3);

/// Native side (MainActivity.kt): opens the system Location settings screen.
const MethodChannel kSettingsChannel = MethodChannel('com.mncgroup.digital_settlement_webview/settings');

/// Why the app cannot be used yet. Location is mandatory, so the WebView is only shown while there is no issue.
enum _GpsIssue { permissionDenied, permissionBlocked, serviceOff }

/// JavaScript channel the page reports its background colour on (see [_themeScript]), so the status bar
/// strip above the WebView matches the page instead of staying a fixed dark band over a light page.
const String kThemeChannel = 'ThemeBridge';

const String _themeScript = '''
(function () {
  function send() {
    var c = getComputedStyle(document.body).backgroundColor;
    if (!c || c === 'transparent' || c === 'rgba(0, 0, 0, 0)') c = getComputedStyle(document.documentElement).backgroundColor;
    ThemeBridge.postMessage(c);
  }
  if (window.__dsTheme) { window.__dsTheme(); return; }
  window.__dsTheme = send;
  new MutationObserver(send).observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'data-theme', 'style'] });
  if (window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', send);
  send();
})();
''';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WebviewApp());
}

class WebviewApp extends StatelessWidget {
  const WebviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Digital Settlement',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B1220),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const WebShell(),
    );
  }
}

class WebShell extends StatefulWidget {
  const WebShell({super.key});

  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> with WidgetsBindingObserver {
  static const _bg = Color(0xFF0B1220);

  late final WebViewController _controller;
  final _imagePicker = ImagePicker();
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  Timer? _loadTimer;
  // Page the WebView loads (and "Coba lagi" reloads): the home page, or the https link that opened the app.
  Uri _target = Uri.parse(kAppUrl);
  // The link that launched the app. app_links also replays it on the stream; that one is not a new link.
  Uri? _launchLink;
  String _pageUrl = '';
  int _progress = 0;
  bool _failed = false;
  // Status bar strip colour; follows the page's own background (see _themeScript).
  Color _pageBg = _bg;
  // Status bar height (dp) last pushed to the page by _applyAppStyle.
  double _statusTop = 0;
  // Why GPS blocks the app, or null when location permission and the GPS switch are both on.
  _GpsIssue? _gpsIssue;
  bool _gpsChecked = false;
  bool _checkingGps = false;
  Timer? _gpsTimer;

  @override
  void initState() {
    super.initState();
    final c = WebViewController();

    if (!kIsWeb) {
      WidgetsBinding.instance.addObserver(this);
      _checkGps(request: true);
      _gpsTimer = Timer.periodic(kGpsPollInterval, (_) => _checkGps());
    }

    // Chrome/web renders an <iframe> (webview_flutter_web), which implements
    // only loadRequest - everything below throws UnimplementedError there.
    // Dev preview only; the real target is Android/iOS.
    if (kIsWeb) {
      _controller = c..loadRequest(Uri.parse(kAppUrl));
      return;
    }

    c
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kUserAgent)
      ..setBackgroundColor(_bg)
      ..addJavaScriptChannel(kThemeChannel, onMessageReceived: (m) => _onPageColor(m.message))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _pageUrl = url;
            _armLoadTimer();
            setState(() => _failed = false);
          },
          onPageFinished: (_) {
            _loadTimer?.cancel();
            _controller.runJavaScript(_themeScript);
            _applyAppStyle();
          },
          onProgress: (p) {
            if (p < 100) {
              _armLoadTimer();
            } else {
              _loadTimer?.cancel();
            }
            setState(() => _progress = p);
          },
          onWebResourceError: (e) {
            // Sub-resource failures (images, analytics) must not blank the app.
            if (e.isForMainFrame ?? false) _fail();
          },
          // The page itself answered with an error status (e.g. a tunnel that is
          // offline answers 404): that is not the app, so show the retry view.
          onHttpError: (e) {
            final status = e.response?.statusCode ?? 0;
            if (status >= 400 && e.request?.uri.toString() == _pageUrl) _fail();
          },
        ),
      );

    final platform = c.platform;
    if (platform is AndroidWebViewController) {
      // Android's WebView shows no file chooser unless the host handles it.
      platform.setOnShowFileSelector(_pickFiles);
      // navigator.mediaDevices / getUserMedia
      platform.setOnPlatformPermissionRequest((req) async {
        await [Permission.camera, Permission.microphone].request();
        await req.grant();
      });
      // navigator.geolocation
      platform.setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (_) async {
          final s = await Permission.locationWhenInUse.request();
          return GeolocationPermissionsResponse(allow: s.isGranted, retain: false);
        },
      );
    }

    _controller = c;
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gpsTimer?.cancel();
    _linkSub?.cancel();
    _loadTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the Settings screen the user was sent to.
    if (state == AppLifecycleState.resumed) _checkGps();
  }

  /// Location permission and the GPS switch must both be on. [request] shows the system permission dialog
  /// (startup and the "Izinkan lokasi" button); the periodic/resume checks never prompt.
  Future<void> _checkGps({bool request = false}) async {
    if (_checkingGps) return;
    _checkingGps = true;
    try {
      var permission = await Permission.locationWhenInUse.status;
      if (!permission.isGranted && request) permission = await Permission.locationWhenInUse.request();

      _GpsIssue? issue;
      if (!permission.isGranted) {
        issue = permission.isPermanentlyDenied ? _GpsIssue.permissionBlocked : _GpsIssue.permissionDenied;
      } else if (!await Permission.location.serviceStatus.isEnabled) {
        issue = _GpsIssue.serviceOff;
      }
      if (mounted && (!_gpsChecked || issue != _gpsIssue)) {
        setState(() {
          _gpsChecked = true;
          _gpsIssue = issue;
        });
      }
    } finally {
      _checkingGps = false;
    }
  }

  Future<void> _fixGps() async {
    switch (_gpsIssue) {
      case _GpsIssue.permissionDenied:
        await _checkGps(request: true);
      case _GpsIssue.permissionBlocked:
        await openAppSettings();
      case _GpsIssue.serviceOff:
        try {
          await kSettingsChannel.invokeMethod<void>('openLocationSettings');
        } on MissingPluginException {
          await openAppSettings(); // iOS: no direct link to the Location switch
        } on PlatformException {
          await openAppSettings();
        }
      case null:
        break;
    }
  }

  /// The page's mobile topbar pads itself by `env(safe-area-inset-top)`, which an Android WebView reports
  /// inconsistently (and Flutter used to inset the status bar too, leaving an empty band above the header).
  /// Pin it to exactly the status bar height measured here, so it never depends on that value.
  void _applyAppStyle() {
    final top = _statusTop.toStringAsFixed(1);
    _controller.runJavaScript('''
(function () {
  var s = document.getElementById('ds-app-style');
  if (!s) { s = document.createElement('style'); s.id = 'ds-app-style'; document.head.appendChild(s); }
  s.textContent = '.mobile-topbar { padding-top: calc(10px + ${top}px) !important; }';
})();
''');
  }

  /// `rgb(r, g, b)` / `rgba(r, g, b, a)` from the page; a translucent colour is ignored.
  void _onPageColor(String css) {
    final m = RegExp(r'rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)').firstMatch(css);
    if (m == null || (double.tryParse(m.group(4) ?? '1') ?? 1) < 1) return;
    final color = Color.fromARGB(255, int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
    if (mounted && color != _pageBg) setState(() => _pageBg = color);
  }

  /// First load. When the app was launched from a link (e.g. "Open Settlement (Mobile Mode)" in an
  /// approval email, Android App Link), open that page instead of the home page.
  Future<void> _start() async {
    try {
      final launch = await _appLinks.getInitialLink();
      if (launch != null && _acceptLink(launch) != null) {
        _launchLink = launch;
        _target = launch;
      }
    } catch (_) {
      // no link support on this platform - just open the home page
    }
    _load();
    // App already running (singleTop) when another link is tapped.
    _linkSub = _appLinks.uriLinkStream.listen(_onLink);
  }

  /// Only the web app's own pages may be opened in this WebView (JavaScript, camera and location are
  /// enabled), never an arbitrary link some other app hands over.
  Uri? _acceptLink(Uri link) {
    final app = Uri.parse(kAppUrl);
    return link.host == app.host && link.scheme == app.scheme ? link : null;
  }

  void _onLink(Uri link) {
    if (link == _launchLink) {
      _launchLink = null;
      return;
    }
    _launchLink = null;
    final accepted = _acceptLink(link);
    if (accepted == null) return;
    _target = accepted;
    setState(() => _failed = false);
    _load();
  }

  void _load() {
    _armLoadTimer();
    _controller.loadRequest(_target);
  }

  void _armLoadTimer() {
    _loadTimer?.cancel();
    _loadTimer = Timer(kLoadTimeout, _fail);
  }

  void _fail() {
    _loadTimer?.cancel();
    if (mounted && !_failed) setState(() => _failed = true);
  }

  /// `<input type="file">` handler: camera for receipt photos, otherwise the
  /// system file picker (gallery, PDF invoices). Returns `file://` URIs.
  Future<List<String>> _pickFiles(FileSelectorParams params) async {
    final multiple = params.mode == FileSelectorMode.openMultiple;
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Kamera'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Galeri / File'),
              onTap: () => Navigator.pop(ctx, 'files'),
            ),
          ],
        ),
      ),
    );
    // null = dismissed -> empty list cancels the chooser (required, or the
    // web page's file input stays stuck).
    if (source == null) return const [];

    if (source == 'camera') {
      final shot = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      return shot == null ? const [] : [Uri.file(shot.path).toString()];
    }

    final files = multiple
        ? await FilePicker.pickFiles()
        : [await FilePicker.pickFile()].whereType<PlatformFile>().toList();
    return files
        .map((f) => f.path)
        .whereType<String>()
        .map((p) => Uri.file(p).toString())
        .toList();
  }

  Future<void> _onBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final lightPage = _pageBg.computeLuminance() > 0.5;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: lightPage ? Brightness.dark : Brightness.light,
        statusBarBrightness: lightPage ? Brightness.light : Brightness.dark, // iOS naming is inverted
      ),
      child: _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    // Status bar height in dp == CSS px. Re-applied when it changes (rotation, cutout).
    final statusTop = MediaQuery.paddingOf(context).top;
    if (!kIsWeb && statusTop != _statusTop) {
      _statusTop = statusTop;
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyAppStyle());
    }
    final gpsBlocked = !kIsWeb && _gpsIssue != null;
    final gpsPending = !kIsWeb && !_gpsChecked;
    return PopScope(
      canPop: kIsWeb, // the iframe has no history API; let the browser handle back
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: _pageBg,
        // No top inset here: the WebView runs under the status bar and the page's own topbar pads itself
        // by the status bar height (see _applyAppStyle). Insetting here as well would count it twice.
        body: SafeArea(
          top: false,
          child: Stack(
            children: [
              if (!_failed && !gpsBlocked && !gpsPending) WebViewWidget(controller: _controller),
              if (gpsBlocked) SafeArea(child: _GpsGate(issue: _gpsIssue!, onFix: _fixGps)),
              if (_failed && !gpsBlocked)
                SafeArea(
                  child: _ErrorView(onRetry: () {
                    setState(() => _failed = false);
                    _load();
                  }),
                ),
              if (!kIsWeb && !_failed && !gpsBlocked && _progress < 100)
                LinearProgressIndicator(value: _progress / 100, minHeight: 2),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off, size: 48, color: Colors.white70),
          const SizedBox(height: 12),
          const Text('Tidak dapat terhubung ke server.'),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Coba lagi')),
        ],
      ),
    );
  }
}

/// Full-screen block shown until location permission and the GPS switch are both on.
class _GpsGate extends StatelessWidget {
  const _GpsGate({required this.issue, required this.onFix});
  final _GpsIssue issue;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final (title, message, action) = switch (issue) {
      _GpsIssue.permissionDenied => (
          'Izin lokasi diperlukan',
          'Aplikasi ini wajib mengakses lokasi Anda. Izinkan akses lokasi untuk melanjutkan.',
          'Izinkan lokasi',
        ),
      _GpsIssue.permissionBlocked => (
          'Izin lokasi ditolak',
          'Akses lokasi diblokir. Buka pengaturan aplikasi, lalu izinkan Lokasi untuk melanjutkan.',
          'Buka pengaturan',
        ),
      _GpsIssue.serviceOff => (
          'GPS belum aktif',
          'Aplikasi ini wajib menyalakan GPS. Aktifkan GPS (Lokasi) di perangkat Anda untuk melanjutkan.',
          'Aktifkan GPS',
        ),
    };
    return Container(
      color: const Color(0xFF0B1220),
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.location_off, size: 56, color: Colors.white70),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 20),
          FilledButton(onPressed: onFix, child: Text(action)),
        ],
      ),
    );
  }
}
