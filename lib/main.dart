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
    facing: CameraFacing.back,
    detectionSpeed: DetectionSpeed.normal,
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
  String _info = 'وجّه الكاميرا نحو الباركود';
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
      final v = b.rawValue;
      if (v == null || v.isEmpty) continue;
      final last = _seen[v];
      _seen[v] = now;
      if (last == null || now - last > kRepeatGapMs) {
        _send(v);
      }
    }
    if (_seen.length > 200) {
      _seen.removeWhere((k, t) => now - t > 10000);
    }
  }

  void _send(String code) {
    final ws = _ws;
    if (ws == null || !_connected) {
      _set(() {
        _lastCode = code;
        _info = 'غير متصل بالكاشير';
      });
      return;
    }
    try {
      ws.add(jsonEncode({'type': 'scan', 'code': code}));
      HapticFeedback.mediumImpact();
      SystemSound.play(SystemSoundType.click);
      _set(() {
        _lastCode = code;
        _info = 'تم الإرسال...';
        _recent.insert(0, code);
        if (_recent.length > 6) _recent.removeLast();
      });
    } catch (_) {
      _closed();
    }
  }

  Future<void> _askHost() async {
    final ctl = TextEditingController(text: _host ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('عنوان الكمبيوتر'),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(hintText: '192.168.1.5'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')),
          TextButton(
            onPressed: () => Navigator.pop(c, ctl.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) {
      final p = await SharedPreferences.getInstance();
      await p.setString('host', v);
      _host = v;
      _ws?.close();
      _ws = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final green = const Color(0xFF12D6A0);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              child: Row(
                children: [
                  const Text(
                    '✦ ماسح الكاشير',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFE9C46A),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _askHost,
                    icon: const Icon(Icons.settings),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1B1550),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(
                  color: _connected ? green : const Color(0xFFE5484D),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_connected ? '🟢 ' : '🔴 '),
                  Flexible(child: Text(_status, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFFE9C46A), width: 2),
                ),
                clipBehavior: Clip.antiAlias,
                child: MobileScanner(
                  controller: cam,
                  onDetect: _onDetect,
                  errorBuilder: (context, error) => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        'تعذر تشغيل الكاميرا، اسمح للتطبيق باستخدام الكاميرا من إعدادات الجهاز',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(14),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF1B1550),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF32288A)),
              ),
              child: Column(
                children: [
                  Text(
                    _lastCode.isEmpty ? '—' : _lastCode,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                      color: Color(0xFFF6D98B),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(_info, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                  if (_recent.length > 1) ...[
                    const SizedBox(height: 8),
                    Text(
                      'آخر المسح: ${_recent.skip(1).take(3).join('  •  ')}',
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(fontSize: 12, color: Color(0xFFA9A3D6)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
