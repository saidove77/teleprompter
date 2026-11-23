import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'prompter_panel.dart';
import 'settings.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _script = TextEditingController();
  PrompterSettings _settings = PrompterSettings();
  bool _overlayActive = false;
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reloadSettings();
      _syncOverlay();
    }
  }

  Future<void> _load() async {
    final s = await PrompterSettings.load();
    final t = await PrompterSettings.loadScript();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _script.text = t;
    });
    _syncOverlay();
  }

  Future<void> _reloadSettings() async {
    final s = await PrompterSettings.load();
    if (mounted) setState(() => _settings = s);
  }

  Future<void> _syncOverlay() async {
    try {
      final active = await FlutterOverlayWindow.isActive();
      if (mounted && active != _overlayActive) {
        setState(() => _overlayActive = active);
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    await PrompterSettings.saveScript(_script.text);
    await _settings.save();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _persist);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  int get _wordCount => _script.text
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .length;

  // ───────── التشغيل ─────────
  Future<void> _openInApp() async {
    if (_script.text.trim().isEmpty) {
      _snack('أضف نصاً أولاً');
      return;
    }
    await _persist();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PrompterPage(text: _script.text, settings: _settings),
      ),
    );
    _reloadSettings();
  }

  Future<void> _toggleOverlay() async {
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
        if (mounted) setState(() => _overlayActive = false);
        return;
      }
      if (_script.text.trim().isEmpty) {
        _snack('أضف نصاً أولاً');
        return;
      }
      if (!await FlutterOverlayWindow.isPermissionGranted()) {
        await FlutterOverlayWindow.requestPermission();
        _snack('فعّل «العرض فوق التطبيقات الأخرى» ثم اضغط الزر مرة أخرى');
        return;
      }
      // إذن الميكروفون مطلوب قبل تشغيل خدمة النافذة العائمة (نوع الخدمة: ميكروفون)
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        _snack('امنح إذن الميكروفون لتشغيل النافذة العائمة');
        if (mic.isPermanentlyDenied) openAppSettings();
        return;
      }
      await _persist();
      if (!mounted) return;
      final size = MediaQuery.of(context).size;
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: 'الملقن الذكي',
        overlayContent: 'النافذة العائمة تعمل',
        flag: OverlayFlag.defaultFlag,
        visibility: NotificationVisibility.visibilityPublic,
        positionGravity: PositionGravity.auto,
        width: (size.width * _settings.frameW).toInt(),
        height: (size.height * _settings.frameH).toInt(),
      );
      if (mounted) setState(() => _overlayActive = true);
    } catch (e) {
      _snack('تعذر تشغيل النافذة العائمة: $e');
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      _snack('الحافظة فارغة');
      return;
    }
    setState(() => _script.text = text);
    _scheduleSave();
  }

  Future<void> _clear() async {
    if (_script.text.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('مسح النص؟'),
        content: const Text('سيتم حذف كل النص الحالي.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('مسح', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _script.clear());
      _scheduleSave();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveDebounce?.cancel();
    _script.dispose();
    super.dispose();
  }

  // ───────── الواجهة ─────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 76,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('الملقن الذكي',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            SizedBox(height: 2),
            Text('اقرأ بثقة · النص يتبع صوتك',
                style: TextStyle(fontSize: 12.5, color: AppColors.textDim)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'الإعدادات',
            icon: const Icon(Icons.tune_rounded),
            onPressed: _openSettings,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            children: [
              Expanded(child: _editorCard()),
              const SizedBox(height: 14),
              _actions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editorCard() {
    final mins = (_wordCount / 130).ceil();
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
            child: Row(
              children: [
                const Icon(Icons.article_outlined,
                    color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                const Text('نص التلقين',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  tooltip: 'لصق',
                  icon: const Icon(Icons.content_paste_rounded, size: 20),
                  onPressed: _paste,
                ),
                IconButton(
                  tooltip: 'مسح',
                  icon: const Icon(Icons.delete_outline_rounded, size: 21),
                  onPressed: _clear,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.outline.withValues(alpha: 0.7)),
          Expanded(
            child: TextField(
              controller: _script,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontSize: 18, height: 1.7),
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'اكتب أو الصق نص التلقين هنا…',
                hintStyle: TextStyle(color: AppColors.textDim),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onChanged: (_) {
                setState(() {});
                _scheduleSave();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Row(
              children: [
                _chip(Icons.text_fields_rounded, '$_wordCount كلمة'),
                const SizedBox(width: 8),
                _chip(Icons.schedule_rounded,
                    _wordCount == 0 ? '—' : '≈ $mins د'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppColors.textDim),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
        ],
      ),
    );
  }

  Widget _actions() {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _openInApp,
            icon: const Icon(Icons.smartphone_rounded),
            label: const Text('داخل التطبيق'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              shape: shape,
              foregroundColor: Colors.white,
              side: const BorderSide(color: AppColors.outline),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: _toggleOverlay,
            icon: Icon(_overlayActive
                ? Icons.close_rounded
                : Icons.picture_in_picture_alt_rounded),
            label: Text(_overlayActive ? 'إيقاف العائمة' : 'نافذة عائمة'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              shape: shape,
              backgroundColor:
                  _overlayActive ? AppColors.danger : AppColors.accent,
              foregroundColor: AppColors.onAccent,
            ),
          ),
        ),
      ],
    );
  }

  // ───────── الإعدادات ─────────
  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget slider(
            String label,
            double v,
            double min,
            double max,
            String Function(double) fmt,
            void Function(double) apply,
          ) {
            return Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Text(label,
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.textDim)),
                ),
                Expanded(
                  child: Slider(
                    min: min,
                    max: max,
                    value: v.clamp(min, max).toDouble(),
                    onChanged: (x) {
                      setSheet(() => apply(x));
                      setState(() {});
                      _scheduleSave();
                    },
                  ),
                ),
                SizedBox(
                  width: 46,
                  child: Text(fmt(v),
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ],
            );
          }

          Widget title(String t) => Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 2),
                child: Text(t,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.accent)),
              );

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.outline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('الإعدادات',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  title('مظهر الملقن'),
                  slider('حجم الخط', _settings.fontSize, 16, 72,
                      (v) => v.round().toString(), (x) => _settings.fontSize = x),
                  slider('السرعة', _settings.speed, 10, 140,
                      (v) => v.round().toString(), (x) => _settings.speed = x),
                  slider('الشفافية', _settings.opacity, 0.1, 1.0,
                      (v) => '${(v * 100).round()}%', (x) => _settings.opacity = x),
                  title('النافذة العائمة'),
                  slider('العرض', _settings.frameW, 0.4, 1.0,
                      (v) => '${(v * 100).round()}%', (x) => _settings.frameW = x),
                  slider('الارتفاع', _settings.frameH, 0.25, 0.9,
                      (v) => '${(v * 100).round()}%', (x) => _settings.frameH = x),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('إبقاء الشاشة مضاءة'),
                    subtitle: const Text('داخل التطبيق فقط',
                        style:
                            TextStyle(fontSize: 12, color: AppColors.textDim)),
                    value: _settings.keepScreenOn,
                    onChanged: (v) {
                      setSheet(() => _settings.keepScreenOn = v);
                      _scheduleSave();
                    },
                  ),
                  const Text(
                    'تُطبَّق تغييرات حجم النافذة عند تشغيلها في المرة القادمة، '
                    'ويمكنك تغيير الحجم وهي تعمل بأزرار التصغير والتكبير.',
                    style: TextStyle(fontSize: 12, color: AppColors.textDim),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// شاشة الملقن داخل التطبيق (نفس لوحة النافذة العائمة بملء الشاشة)
class PrompterPage extends StatefulWidget {
  const PrompterPage({super.key, required this.text, required this.settings});

  final String text;
  final PrompterSettings settings;

  @override
  State<PrompterPage> createState() => _PrompterPageState();
}

class _PrompterPageState extends State<PrompterPage> {
  @override
  void initState() {
    super.initState();
    if (widget.settings.keepScreenOn) {
      try {
        WakelockPlus.enable();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    try {
      WakelockPlus.disable();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: PrompterPanel(
            text: widget.text,
            settings: widget.settings,
            onClose: () => Navigator.of(context).pop(),
            onSettingsChanged: (s) => s.saveLook(),
          ),
        ),
      ),
    );
  }
}
