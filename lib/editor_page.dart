import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:permission_handler/permission_handler.dart';

import 'overlay_bridge.dart';
import 'prompter_page.dart';
import 'script_store.dart';
import 'settings.dart';
import 'theme.dart';

/// صفحة تحرير نص واحد، ومنها يبدأ التلقين (داخل التطبيق أو في نافذة عائمة)
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.script,
    required this.settings,
    this.isNew = false,
  });

  final Script script;
  final PrompterSettings settings;
  final bool isNew;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> with WidgetsBindingObserver {
  late final TextEditingController _title;
  late final TextEditingController _text;
  late bool _created; // هل حُفظ النص في المكتبة؟
  bool _overlayActive = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _title = TextEditingController(text: widget.script.title);
    _text = TextEditingController(text: widget.script.text);
    _created = !widget.isNew;
    _syncOverlay();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _persistNow();
    } else if (state == AppLifecycleState.resumed) {
      _syncOverlay();
    }
  }

  Future<void> _syncOverlay() async {
    try {
      final active = await FlutterOverlayWindow.isActive();
      if (mounted && active != _overlayActive) {
        setState(() => _overlayActive = active);
      }
    } catch (_) {}
  }

  Future<void> _persistNow() async {
    final title = _title.text.trim().isEmpty ? 'بدون عنوان' : _title.text.trim();
    final text = _text.text;
    // نص جديد فارغ لا نحفظه حتى لا تتراكم نصوص فارغة
    if (!_created && text.trim().isEmpty) return;
    _created = true;
    widget.script.title = title;
    widget.script.text = text;
    widget.script.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await ScriptStore.upsert(widget.script);
  }

  void _onChanged() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _persistNow();
      if (_overlayActive) {
        OverlayBridge.text = _text.text;
        OverlayBridge.title = _title.text;
        OverlayBridge.push(); // تحديث النافذة العائمة مباشرة
      }
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  int get _wordCount {
    final t = _text.text.trim();
    return t.isEmpty ? 0 : t.split(RegExp(r'\s+')).length;
  }

  // ───────── التشغيل ─────────
  Future<void> _openInApp() async {
    if (_text.text.trim().isEmpty) {
      _snack('أضف نصاً أولاً');
      return;
    }
    await _persistNow();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PrompterPage(text: _text.text, settings: widget.settings),
      ),
    );
  }

  Future<void> _toggleOverlay() async {
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
        if (mounted) setState(() => _overlayActive = false);
        return;
      }
      if (_text.text.trim().isEmpty) {
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

      await _persistNow();
      await ScriptStore.setActive(widget.script.id);
      await widget.settings.save();
      OverlayBridge.text = _text.text;
      OverlayBridge.title = widget.script.title;

      if (!mounted) return;
      final size = MediaQuery.of(context).size;
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: 'الملقن الذكي',
        overlayContent: 'النافذة العائمة تعمل',
        flag: OverlayFlag.defaultFlag,
        visibility: NotificationVisibility.visibilityPublic,
        positionGravity: PositionGravity.auto,
        width: (size.width * widget.settings.frameW).toInt(),
        height: (size.height * widget.settings.frameH).toInt(),
      );
      if (mounted) setState(() => _overlayActive = true);
      OverlayBridge.pushRepeatedly(); // يضمن وصول النص إلى النافذة
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
    _text.text = text;
    _onChanged();
  }

  Future<void> _clear() async {
    if (_text.text.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('مسح النص؟'),
        content: const Text('سيتم حذف محتوى هذا النص.'),
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
      _text.clear();
      _onChanged();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _persistNow(); // يقرأ النصوص فوراً قبل التخلص من المتحكّمات
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  // ───────── الواجهة ─────────
  @override
  Widget build(BuildContext context) {
    final mins = (_wordCount / 130).ceil();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _title,
          onChanged: (_) => _onChanged(),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: 'عنوان النص',
            hintStyle: TextStyle(color: AppColors.textDim),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'لصق',
            icon: const Icon(Icons.content_paste_rounded),
            onPressed: _paste,
          ),
          IconButton(
            tooltip: 'مسح',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _clear,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: AppColors.outline),
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          maxLines: null,
                          expands: true,
                          textAlignVertical: TextAlignVertical.top,
                          style: const TextStyle(fontSize: 18, height: 1.7),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'اكتب أو الصق نص التلقين هنا…',
                            hintStyle: TextStyle(color: AppColors.textDim),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                          ),
                          onChanged: (_) => _onChanged(),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                        child: Row(
                          children: [
                            _chip(Icons.text_fields_rounded,
                                '$_wordCount كلمة'),
                            const SizedBox(width: 8),
                            _chip(Icons.schedule_rounded,
                                _wordCount == 0 ? '—' : '≈ $mins د'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _actions(),
            ],
          ),
        ),
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
}
