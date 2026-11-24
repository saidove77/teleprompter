import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'prompter_panel.dart';
import 'script_store.dart';
import 'settings.dart';
import 'theme.dart';

/// جذر النافذة العائمة (يُشغَّل من overlayMain في main.dart)
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const OverlayHome(),
    );
  }
}

class OverlayHome extends StatefulWidget {
  const OverlayHome({super.key});

  @override
  State<OverlayHome> createState() => _OverlayHomeState();
}

class _OverlayHomeState extends State<OverlayHome> {
  PrompterSettings? _settings;
  String? _text; // null = لم يصل النص بعد
  bool _failed = false;
  double _w = 360;
  double _h = 500;
  Size _screen = const Size(360, 800);
  StreamSubscription? _sub;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    _screen = _screenDp();
    _sub = FlutterOverlayWindow.overlayListener.listen(_onMessage);
    _init();
  }

  /// حجم الشاشة الفعلي بوحدة dp (وليس حجم النافذة العائمة)
  Size _screenDp() {
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final d = view.display;
      return Size(d.size.width / d.devicePixelRatio,
          d.size.height / d.devicePixelRatio);
    } catch (_) {
      return const Size(360, 800);
    }
  }

  Future<void> _init() async {
    PrompterSettings s;
    try {
      s = await PrompterSettings.load();
    } catch (_) {
      s = PrompterSettings();
    }
    String? t;
    try {
      t = await ScriptStore.activeText(); // قراءة مباشرة من التخزين
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _settings = s;
      if ((_text ?? '').isEmpty && (t ?? '').isNotEmpty) _text = t;
      _w = _screen.width * s.frameW;
      _h = _screen.height * s.frameH;
    });

    // نطلب النص من التطبيق أيضاً (يصل غالباً أحدث)
    try {
      await FlutterOverlayWindow.shareData(jsonEncode({'type': 'ready'}));
    } catch (_) {}

    _timeout = Timer(const Duration(seconds: 5), () {
      if (mounted && (_text ?? '').isEmpty) setState(() => _failed = true);
    });
  }

  void _onMessage(dynamic event) {
    if (event is! String || !mounted) return;
    try {
      final m = jsonDecode(event);
      if (m is Map) {
        final t = m['text'];
        if (t is String && t.isNotEmpty && t != _text) {
          setState(() {
            _text = t;
            _failed = false;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _resize(double factor) async {
    _w = (_w * factor).clamp(220.0, _screen.width).toDouble();
    _h = (_h * factor).clamp(200.0, _screen.height * 0.95).toDouble();
    try {
      await FlutterOverlayWindow.resizeOverlay(_w.toInt(), _h.toInt(), true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Widget _loadingCard() {
    return Container(
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_failed) const CircularProgressIndicator(),
                  const SizedBox(height: 14),
                  Text(
                    _failed
                        ? 'تعذر تحميل النص. أغلق النافذة وأعد تشغيلها من التطبيق.'
                        : 'جارٍ تحميل النص…',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 14, color: AppColors.textDim),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 6,
            left: 6,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white70),
              onPressed: () => FlutterOverlayWindow.closeOverlay(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    final hasText = (_text ?? '').isNotEmpty;
    return Material(
      type: MaterialType.transparency,
      child: (s == null || !hasText)
          ? _loadingCard()
          : Padding(
              padding: const EdgeInsets.all(3),
              child: PrompterPanel(
                text: _text!,
                settings: s,
                compact: true,
                onClose: () => FlutterOverlayWindow.closeOverlay(),
                onResize: _resize,
                onSettingsChanged: (v) => v.saveLook(),
              ),
            ),
    );
  }
}