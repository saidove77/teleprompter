import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'l10n.dart';
import 'overlay_bridge.dart';
import 'prompter_panel.dart';
import 'script_store.dart';
import 'settings.dart';
import 'theme.dart';

/// جذر النافذة العائمة (يُشغَّل من overlayMain في main.dart)
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return localizedApp(home: const OverlayHome());
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

  // الأبعاد بوحدة dp (نحوّلها لوحدة الحزمة عند الإرسال)
  double _w = 360;
  double _h = 400;
  Size _screen = const Size(360, 800);
  double _dpr = 1.0;

  // سحب النافذة
  double _px = 0, _py = 0;
  bool _moveOk = false;

  StreamSubscription? _sub;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    _readScreen();
    L10n.load(); // لغة التطبيق (تُحدَّث الواجهة تلقائياً)
    _sub = FlutterOverlayWindow.overlayListener.listen(_onMessage);
    _init();
  }

  /// حجم الشاشة الفعلي بوحدة dp وكثافة البكسل (وليس حجم النافذة العائمة)
  void _readScreen() {
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final d = view.display;
      _dpr = d.devicePixelRatio;
      _screen = Size(d.size.width / _dpr, d.size.height / _dpr);
    } catch (_) {
      _dpr = 1.0;
      _screen = const Size(360, 800);
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

    _requestText(); // نطلب النص من التطبيق أيضاً (يصل غالباً أحدث)

    _timeout = Timer(const Duration(seconds: 5), () {
      if (mounted && (_text ?? '').isEmpty) setState(() => _failed = true);
    });
  }

  Future<void> _requestText() async {
    try {
      await FlutterOverlayWindow.shareData(jsonEncode({'type': 'ready'}));
    } catch (_) {}
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
    final k = overlayScale(_dpr);
    try {
      await FlutterOverlayWindow.resizeOverlay(
        (_w * k).round(),
        (_h * k).round(),
        false, // السحب يتم من المقبض لا من النافذة كلها
      );
    } catch (_) {}
  }

  // ───────── سحب النافذة من المقبض ─────────
  Future<void> _moveStart() async {
    try {
      final dynamic p = await FlutterOverlayWindow.getOverlayPosition();
      _px = (p?.x as num?)?.toDouble() ?? _px;
      _py = (p?.y as num?)?.toDouble() ?? _py;
      _moveOk = true;
    } catch (_) {
      _moveOk = false;
    }
  }

  void _move(Offset d) {
    if (!_moveOk) return;
    final k = overlayScale(_dpr);
    _px += d.dx * k;
    _py += d.dy * k;
    try {
      FlutterOverlayWindow.moveOverlay(OverlayPosition(_px, _py));
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
                    _failed ? tr('load_failed') : tr('loading_text'),
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
    return LangBuilder(
      builder: (_) {
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
                    onRefresh: _requestText,
                    onMoveStart: _moveStart,
                    onMove: _move,
                    onSettingsChanged: (v) => v.saveLook(),
                  ),
                ),
        );
      },
    );
  }
}