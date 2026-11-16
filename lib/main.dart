import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const int kPort = 8000;
const int kRepeatGapMs = 1500;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const CashierApp());
}

class CashierApp extends StatelessWidget {
  const CashierApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ماسح الكاشير',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0E0A2B),
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const ScanPage(),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> with WidgetsBindingObserver {
  final MobileScannerController cam = MobileScannerController(
    facing: CameraFacing.front,
    cameraResolution: const Size(1920, 1080),
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 100,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
    ],
  );

  WebSocket? _ws;
  String? _host;
  bool _connected = false;
  bool _looping = false;
  String _status = 'جاري البحث عن الكاشير...';
  String _lastCode = '';
  String _info = 'ضع الباركود أمام الكاميرا';
  final List<String> _recent = [];
  final Map<String, int> _seen = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ws?.close();
    cam.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WakelockPlus.enable();
      if (_ws == null) _connectLoop();
    }
  }

  Future<void> _start() async {
    final p = await SharedPreferences.getInstance();
    _host = p.getString('host');
    _connectLoop();
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  // ---------- الاتصال بالكمبيوتر ----------
  Future<bool> _alive(String ip) async {
    final c = HttpClient();
    c.connectionTimeout = const Duration(milliseconds: 900);
    try {
      final req = await c
          .getUrl(Uri.parse('http://$ip:$kPort/api/ping'))
          .timeout(const Duration(milliseconds: 1200));
      final res = await req.close().timeout(const Duration(milliseconds: 1500));
      final body = await res.transform(utf8.decoder).join();
      return body.contains('smart-cashier');
    } catch (_) {
      return false;
    } finally {
      c.close(force: true);
    }
  }

  Future<String?> _discover() async {
    final prefixes = <String>{};
    try {
      final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in ifs) {
        for (final a in i.addresses) {
          final parts = a.address.split('.');
          if (parts.length == 4) {
            prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
          }
        }
      }
    } catch (_) {}
    for (final pre in prefixes) {
      final results = await Future.wait(List.generate(254, (i) async {
        final ip = '$pre.${i + 1}';
        return (await _alive(ip)) ? ip : null;
      }));
      for (final r in results) {
        if (r != null) return r;
      }
    }
    return null;
  }

  Future<void> _connectLoop() async {
    if (_looping) return;
    _looping = true;
    while (mounted) {
      if (_ws == null) {
        String? h = _host;
        if (h == null || !await _alive(h)) {
          _set(() => _status = 'جاري البحث عن الكاشير...');
          h = await _discover();
        }
        if (h != null) {
          await _open(h);
        } else {
          _set(() => _status = 'لم أجد الكاشير، تأكد أن البرنامج شغّال بنفس الشبكة');
        }
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    _looping = false;
  }

  Future<void> _open(String h) async {
    try {
      final ws = await WebSocket.connect('ws://$h:$kPort/ws?role=phone')
          .timeout(const Duration(seconds: 4));
      ws.pingInterval = const Duration(seconds: 5);
      _ws = ws;
      _host = h;
      final p = await SharedPreferences.getInstance();
      await p.setString('host', h);
      _set(() {
        _connected = true;
        _status = 'متصل بالكاشير ($h)';
      });
      ws.listen(
        _onMessage,
        onDone: _closed,
        onError: (_) => _closed(),
        cancelOnError: true,
      );
    } catch (_) {
      _ws = null;
      _set(() {
        _connected = false;
        _status = 'فشل الاتصال، أعيد المحاولة...';
      });
    }
  }

  void _closed() {
    _ws = null;
    _set(() {
      _connected = false;
      _status = 'انقطع الاتصال، أعيد الاتصال...';
    });
  }

  void _onMessage(dynamic data) {
    try {
      final m = jsonDecode(data as String);
      if (m['type'] == 'scan' && m['code'] == _lastCode) {
        final pr = m['product'];
        _set(() {
          _info = pr == null
              ? 'باركود جديد، أضف بياناته من شاشة الكمبيوتر'
              : '${pr['emoji']} ${pr['name']} - ${pr['price'].round()} د.ع';
        });
      }
    } catch (_) {}
  }

  // ---------- المسح ----------
  void _onDetect(BarcodeCapture cap) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final b in cap.barcodes) {
      f
