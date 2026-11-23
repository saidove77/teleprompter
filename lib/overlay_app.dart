import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'prompter_panel.dart';
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
  String _text = '';
  double _w = 360;
  double _h = 500;
  Size _screen = const Size(360, 800);
  StreamSubscription? _sub;

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
    final s = await PrompterSettings.load();
    final t = await PrompterSettings.loadScript();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _text = t;
      _w = _screen.width * s.frameW;
      _h = _screen.height * s.frameH;
    });
  }

  void _onMessage(dynamic event) {
    if (event is! String || !mounted) return;
    try {
      final m = jsonDecode(event) as Map<String, dynamic>;
      final t = m['text'] as String?;
      if (t != null) setState(() => _text = t);
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
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    return Material(
      type: MaterialType.transparency,
      child: s == null
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(3),
              child: PrompterPanel(
                text: _text,
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
