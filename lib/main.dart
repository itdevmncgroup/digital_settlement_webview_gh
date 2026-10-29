import 'dart:async';

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

class _WebShellState extends State<WebShell> {
  static const _bg = Color(0xFF0B1220);

  late final WebViewController _controller;
  final _imagePicker = ImagePicker();
  Timer? _loadTimer;
  String _pageUrl = '';
  int _progress = 0;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final c = WebViewController();

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
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _pageUrl = url;
            _armLoadTimer();
            setState(() => _failed = false);
          },
          onPageFinished: (_) => _loadTimer?.cancel(),
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
    _load();
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    super.dispose();
  }

  void _load() {
    _armLoadTimer();
    _controller.loadRequest(Uri.parse(kAppUrl));
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
    return PopScope(
      canPop: kIsWeb, // the iframe has no history API; let the browser handle back
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Stack(
            children: [
              if (!_failed) WebViewWidget(controller: _controller),
              if (_failed)
                _ErrorView(onRetry: () {
                  setState(() => _failed = false);
                  _load();
                }),
              if (!kIsWeb && !_failed && _progress < 100)
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
