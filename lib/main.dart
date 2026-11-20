import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ───────────── نقطة دخول النافذة العائمة ─────────────
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayApp());
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TeleprompterApp());
}

// ───────────── التطبيق الرئيسي ─────────────
class TeleprompterApp extends StatelessWidget {
  const TeleprompterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'الملقن',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _script = TextEditingController();
  final _scroll = ScrollController();
  final _db = ValueNotifier<double>(0);

  bool _prompterMode = false;
  bool _scrolling = false;
  bool _keepOn = true;
  bool _voice = false;
  bool _overlayActive = false;

  double _fontSize = 28;
  double _speed = 35; // بكسل/ثانية
  double _opacity = 0.85;
  double _frameW = 0.92;
  double _frameH = 0.72;
  double _threshold = 55;

  Timer? _scrollTimer;
  Timer? _silenceTimer;
  Timer? _saveDebounce;
  StreamSubscription<NoiseReading>? _noiseSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncOverlayState();
  }

  Future<void> _syncOverlayState() async {
    try {
      final active = await FlutterOverlayWindow.isActive();
      if (mounted && active != _overlayActive) {
        setState(() => _overlayActive = active);
      }
    } catch (_) {}
  }

  // ───────── الإعدادات ─────────
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _script.text = p.getString('script') ??
          'مرحباً بك في الملقن.\n\nاكتب نصك هنا أو الصقه، ثم اضغط «ملقن» لبدء القراءة.';
      _fontSize = p.getDouble('font') ?? 28;
      _speed = p.getDouble('speed') ?? 35;
      _opacity = p.getDouble('opacity') ?? 0.85;
      _frameW = p.getDouble('fw') ?? 0.92;
      _frameH = p.getDouble('fh') ?? 0.72;
      _keepOn = p.getBool('keepOn') ?? true;
      _threshold = p.getDouble('threshold') ?? 55;
    });
    _applyWakelock();
    _syncOverlayState();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('script', _script.text);
    await p.setDouble('font', _fontSize);
    await p.setDouble('speed', _speed);
    await p.setDouble('opacity', _opacity);
    await p.setDouble('fw', _frameW);
    await p.setDouble('fh', _frameH);
    await p.setBool('keepOn', _keepOn);
    await p.setDouble('threshold', _threshold);
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _applyWakelock() async {
    try {
      _keepOn ? await WakelockPlus.enable() : await WakelockPlus.disable();
    } catch (_) {}
  }

  // ───────── التمرير ─────────
  void _startScrolling() {
    if (_scrolling || !_scroll.hasClients) return;
    if (_scroll.offset >= _scroll.position.maxScrollExtent) return;
    setState(() => _scrolling = true);
    _scrollTimer?.cancel();
    const tick = 30;
    _scrollTimer = Timer.periodic(const Duration(milliseconds: tick), (_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      final next = _scroll.offset + _speed * tick / 1000;
      if (next >= max) {
        _scroll.jumpTo(max);
        _stopScrolling();
      } else {
        _scroll.jumpTo(next);
      }
    });
  }

  void _stopScrolling() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    if (mounted && _scrolling) setState(() => _scrolling = false);
  }

  void _toggleScrolling() => _scrolling ? _stopScrolling() : _startScrolling();

  // ───────── التحكم بالصوت ─────────
  Future<void> _toggleVoice() async {
    if (_voice) {
      await _stopVoice();
      return;
    }
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _snack('يجب السماح بالميكروفون لاستخدام التحكم بالصوت');
      if (status.isPermanentlyDenied) openAppSettings();
      return;
    }
    try {
      _noiseSub = NoiseMeter().noise.listen(
        _onNoise,
        onError: (_) {
          _stopVoice();
          _snack('تعذر الوصول إلى الميكروفون');
        },
      );
      setState(() => _voice = true);
    } catch (_) {
      _snack('تعذر تشغيل التحكم بالصوت');
    }
  }

  void _onNoise(NoiseReading r) {
    _db.value = r.meanDecibel;
    if (!_prompterMode) return;
    if (r.meanDecibel >= _threshold) {
      _silenceTimer?.cancel();
      _silenceTimer = null;
      if (!_scrolling) _startScrolling();
    } else if (_scrolling && _silenceTimer == null) {
      // لا نوقف التمرير إلا بعد صمت متواصل
      _silenceTimer = Timer(const Duration(milliseconds: 900), () {
        _silenceTimer = null;
        _stopScrolling();
      });
    }
  }

  Future<void> _stopVoice() async {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    await _noiseSub?.cancel();
    _noiseSub = null;
    _db.value = 0;
    if (mounted) setState(() => _voice = false);
  }

  // ───────── النافذة العائمة ─────────
  Map<String, dynamic> _overlayPayload({bool withSize = false}) {
    final size = MediaQuery.of(context).size;
    return {
      'text': _script.text,
      'font': _fontSize,
      'speed': _speed,
      'opacity': _opacity,
      if (withSize) 'w': (size.width * _frameW).toInt(),
      if (withSize) 'h': (size.height * _frameH).toInt(),
    };
  }

  /// إرسال الإعدادات الحالية (شفافية، سرعة، خط) إلى النافذة العائمة مباشرة
  Future<void> _pushOverlay() async {
    if (!_overlayActive) return;
    try {
      await FlutterOverlayWindow.shareData(jsonEncode(_overlayPayload()));
    } catch (_) {}
  }

  /// تغيير حجم النافذة العائمة حسب سلايدر عرض/ارتفاع الإطار
  Future<void> _resizeOverlay() async {
    if (!_overlayActive) return;
    final size = MediaQuery.of(context).size;
    try {
      await FlutterOverlayWindow.resizeOverlay(
        (size.width * _frameW).toInt(),
        (size.height * _frameH).toInt(),
        true,
      );
    } catch (_) {}
  }

  Future<void> _toggleOverlay() async {
    try {
      if (!await FlutterOverlayWindow.isPermissionGranted()) {
        await FlutterOverlayWindow.requestPermission();
        _snack('فعّل «العرض فوق التطبيقات» ثم اضغط الزر مرة أخرى');
        return;
      }
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
        setState(() => _overlayActive = false);
        return;
      }
      await _save();
      final h = MediaQuery.of(context).size.height * _frameH;
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: 'الملقن',
        overlayContent: 'النافذة العائمة تعمل',
        flag: OverlayFlag.defaultFlag,
        visibility: NotificationVisibility.visibilityPublic,
        positionGravity: PositionGravity.auto,
        width: WindowSize.matchParent,
        height: h.toInt().clamp(250, 1200),
      );
      // يجب إرسال البيانات بعد ظهور النافذة
      await Future.delayed(const Duration(milliseconds: 700));
      await FlutterOverlayWindow.shareData(
          jsonEncode(_overlayPayload(withSize: true)));
      setState(() => _overlayActive = true);
    } catch (e) {
      _snack('تعذر تشغيل النافذة العائمة: $e');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollTimer?.cancel();
    _silenceTimer?.cancel();
    _saveDebounce?.cancel();
    _noiseSub?.cancel();
    WakelockPlus.disable();
    _script.dispose();
    _scroll.dispose();
    _db.dispose();
    super.dispose();
  }

  // ───────── الواجهة ─────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_prompterMode ? 'وضع الملقن' : 'تحرير النص'),
        actions: [
          IconButton(
            tooltip: 'منع انطفاء الشاشة',
            icon: Icon(
              _keepOn ? Icons.screen_lock_portrait : Icons.bedtime_off,
              color: _keepOn ? Colors.greenAccent : Colors.grey,
            ),
            onPressed: () {
              setState(() => _keepOn = !_keepOn);
              _applyWakelock();
              _scheduleSave();
            },
          ),
          IconButton(
            tooltip: 'التحكم بالصوت',
            icon: Icon(
              _voice ? Icons.mic : Icons.mic_off,
              color: _voice ? Colors.amberAccent : Colors.grey,
            ),
            onPressed: _toggleVoice,
          ),
          IconButton(
            tooltip: 'النافذة العائمة',
            icon: Icon(
              _overlayActive
                  ? Icons.picture_in_picture_alt
                  : Icons.picture_in_picture,
              color: _overlayActive ? Colors.lightBlueAccent : null,
            ),
            onPressed: _toggleOverlay,
          ),
          IconButton(
            tooltip: _prompterMode ? 'تحرير' : 'ملقن',
            icon: Icon(_prompterMode ? Icons.edit : Icons.play_circle),
            onPressed: () async {
              await _save();
              if (_prompterMode) _stopScrolling();
              setState(() => _prompterMode = !_prompterMode);
            },
          ),
        ],
      ),
      body: _prompterMode ? _prompterView() : _editorView(),
    );
  }

  Widget _editorView() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: TextField(
              controller: _script,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontSize: 18, height: 1.5),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'اكتب أو الصق نص التلقين هنا...',
              ),
              onChanged: (_) => _scheduleSave(),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () async {
                await _save();
                setState(() => _prompterMode = true);
              },
              icon: const Icon(Icons.slideshow),
              label: const Text('الانتقال إلى وضع الملقن'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _prompterView() {
    return Column(
      children: [
        if (_voice)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: ValueListenableBuilder<double>(
              valueListenable: _db,
              builder: (_, v, __) => Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('الصوت: ${v.toStringAsFixed(0)} dB'),
                  Text('العتبة: ${_threshold.toStringAsFixed(0)} dB'),
                ],
              ),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => Center(
              child: Container(
                width: c.maxWidth * _frameW,
                height: c.maxHeight * _frameH.clamp(0.3, 1.0),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: _opacity),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24),
                ),
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: Text(
                    _script.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: _fontSize,
                      height: 1.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        _controls(),
      ],
    );
  }

  Widget _slider(
    String label,
    double v,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    bool resize = false,
  }) {
    return Row(
      children: [
        SizedBox(
            width: 78,
            child: Text(label, style: const TextStyle(fontSize: 12))),
        Expanded(
          child: Slider(
            min: min,
            max: max,
            value: v.clamp(min, max),
            onChanged: (x) {
              setState(() => onChanged(x));
              _scheduleSave();
              if (resize) {
                _resizeOverlay();
              } else {
                _pushOverlay();
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _controls() {
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                FloatingActionButton.small(
                  heroTag: 'play',
                  onPressed: _toggleScrolling,
                  child: Icon(_scrolling ? Icons.pause : Icons.play_arrow),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'من البداية',
                  icon: const Icon(Icons.replay),
                  onPressed: () {
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  },
                ),
                Expanded(
                  child: _slider('السرعة', _speed, 10, 140, (x) => _speed = x),
                ),
              ],
            ),
            _slider('حجم الخط', _fontSize, 16, 72, (x) => _fontSize = x),
            _slider('الشفافية', _opacity, 0.2, 1.0, (x) => _opacity = x),
            _slider('عرض الإطار', _frameW, 0.4, 1.0, (x) => _frameW = x,
                resize: true),
            _slider('ارتفاع الإطار', _frameH, 0.3, 1.0, (x) => _frameH = x,
                resize: true),
            if (_voice)
              _slider('عتبة الصوت', _threshold, 30, 90, (x) => _threshold = x),
          ],
        ),
      ),
    );
  }
}

// ───────────── النافذة العائمة ─────────────
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const OverlayPage(),
    );
  }
}

class OverlayPage extends StatefulWidget {
  const OverlayPage({super.key});

  @override
  State<OverlayPage> createState() => _OverlayPageState();
}

class _OverlayPageState extends State<OverlayPage> {
  final _scroll = ScrollController();
  StreamSubscription? _sub;
  Timer? _timer;

  String _text = 'بانتظار النص...';
  double _font = 24;
  double _speed = 35;
  double _opacity = 0.85;
  int _w = 360;
  int _h = 500;
  bool _playing = false;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _sub = FlutterOverlayWindow.overlayListener.listen((event) {
      if (event is! String || !mounted) return;
      try {
        final m = jsonDecode(event) as Map<String, dynamic>;
        setState(() {
          _text = m['text'] as String? ?? _text;
          _font = (m['font'] as num?)?.toDouble() ?? _font;
          _speed = (m['speed'] as num?)?.toDouble() ?? _speed;
          _opacity = (m['opacity'] as num?)?.toDouble() ?? _opacity;
          _w = (m['w'] as num?)?.toInt() ?? _w;
          _h = (m['h'] as num?)?.toInt() ?? _h;
        });
      } catch (_) {
        setState(() => _text = event);
      }
    });
  }

  void _toggle() {
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    const tick = 30;
    _timer = Timer.periodic(const Duration(milliseconds: tick), (_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      final next = _scroll.offset + _speed * tick / 1000;
      if (next >= max) {
        _scroll.jumpTo(max);
        _timer?.cancel();
        if (mounted) setState(() => _playing = false);
      } else {
        _scroll.jumpTo(next);
      }
    });
  }

  Future<void> _resize(int dw, int dh) async {
    _w = (_w + dw).clamp(200, 1200).toInt();
    _h = (_h + dh).clamp(200, 2000).toInt();
    try {
      await FlutterOverlayWindow.resizeOverlay(_w, _h, true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Widget _miniSlider(IconData icon, double v, double min, double max,
      ValueChanged<double> onChanged) {
    return Row(
      children: [
        const SizedBox(width: 8),
        Icon(icon, size: 18),
        Expanded(
          child: Slider(
            min: min,
            max: max,
            value: v.clamp(min, max),
            onChanged: (x) => setState(() => onChanged(x)),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: _opacity),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                onPressed: _toggle,
              ),
              IconButton(
                icon: const Icon(Icons.replay),
                onPressed: () {
                  if (_scroll.hasClients) _scroll.jumpTo(0);
                },
              ),
              IconButton(
                icon: const Icon(Icons.zoom_in_map),
                tooltip: 'تصغير',
                onPressed: () => _resize(-60, -80),
              ),
              IconButton(
                icon: const Icon(Icons.zoom_out_map),
                tooltip: 'تكبير',
                onPressed: () => _resize(60, 80),
              ),
              IconButton(
                icon: Icon(_showControls ? Icons.tune : Icons.tune_outlined),
                tooltip: 'إظهار/إخفاء الإعدادات',
                onPressed: () => setState(() => _showControls = !_showControls),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => FlutterOverlayWindow.closeOverlay(),
              ),
            ],
          ),
          if (_showControls) ...[
            _miniSlider(Icons.opacity, _opacity, 0.1, 1.0, (x) => _opacity = x),
            _miniSlider(Icons.speed, _speed, 10, 140, (x) => _speed = x),
            _miniSlider(Icons.format_size, _font, 16, 60, (x) => _font = x),
          ],
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                _text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: _font,
                  height: 1.5,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}