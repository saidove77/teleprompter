import 'package:flutter/material.dart';

import 'editor_page.dart';
import 'script_store.dart';
import 'settings.dart';
import 'theme.dart';

/// الشاشة الرئيسية: مكتبة النصوص
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<Script> _scripts = [];
  PrompterSettings _settings = PrompterSettings();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final list = await ScriptStore.load();
    final s = await PrompterSettings.load();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!mounted) return;
    setState(() {
      _scripts = list;
      _settings = s;
      _loading = false;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open(Script s, {bool isNew = false}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            EditorPage(script: s, settings: _settings, isNew: isNew),
      ),
    );
    // ننتظر لحظة حتى يكتمل حفظ المحرر ثم نحدّث القائمة
    await Future.delayed(const Duration(milliseconds: 350));
    _load();
  }

  void _newScript() {
    _open(
      Script(
        id: ScriptStore.newId(),
        title: 'نص جديد',
        text: '',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
      isNew: true,
    );
  }

  Future<void> _duplicate(Script s) async {
    final copy = Script(
      id: ScriptStore.newId(),
      title: '${s.title} (نسخة)',
      text: s.text,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await ScriptStore.upsert(copy);
    _load();
  }

  Future<void> _confirmDelete(Script s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف النص؟'),
        content: Text('سيتم حذف «${s.title}» نهائياً.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ScriptStore.delete(s.id);
      _snack('تم الحذف');
      _load();
    }
  }

  String _ago(int ms) {
    if (ms <= 0) return '';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'قبل ${diff.inMinutes} د';
    if (diff.inHours < 24) return 'قبل ${diff.inHours} س';
    return 'قبل ${diff.inDays} يوم';
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newScript,
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.onAccent,
        icon: const Icon(Icons.add_rounded),
        label: const Text('نص جديد',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _scripts.isEmpty
                ? _empty()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    itemCount: _scripts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => _card(_scripts[i]),
                  ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.subtitles_rounded,
                  size: 46, color: AppColors.accent),
            ),
            const SizedBox(height: 20),
            const Text('لا توجد نصوص بعد',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('اضغط «نص جديد» لإضافة أول نص تلقين',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textDim)),
          ],
        ),
      ),
    );
  }

  Widget _card(Script s) {
    final preview = s.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final mins = (s.wordCount / 130).ceil();
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => _open(s),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.outline),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.article_rounded,
                    color: AppColors.accent, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16.5, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      preview.isEmpty ? 'نص فارغ' : preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.5,
                          color: AppColors.textDim),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${s.wordCount} كلمة · ≈ ${s.wordCount == 0 ? 0 : mins} د · ${_ago(s.updatedAt)}',
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textDim),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                color: AppColors.surfaceHigh,
                icon: const Icon(Icons.more_vert_rounded,
                    color: AppColors.textDim),
                onSelected: (v) {
                  if (v == 'dup') _duplicate(s);
                  if (v == 'del') _confirmDelete(s);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'dup', child: Text('نسخ')),
                  PopupMenuItem(value: 'del', child: Text('حذف')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────── الإعدادات العامة ─────────
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
                      _settings.save();
                    },
                  ),
                ),
                SizedBox(
                  width: 46,
                  child: Text('${(v * 100).round()}%',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ],
            );
          }

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
                  const SizedBox(height: 10),
                  const Text('حجم النافذة العائمة عند تشغيلها',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accent)),
                  slider('العرض', _settings.frameW, 0.4, 1.0,
                      (x) => _settings.frameW = x),
                  slider('الارتفاع', _settings.frameH, 0.25, 0.9,
                      (x) => _settings.frameH = x),
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
                      _settings.save();
                    },
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'إعدادات القراءة (الخط، السرعة، الألوان، المرآة، الصوت…) '
                    'تجدها داخل الملقن نفسه عند الضغط على زر الإعدادات.',
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