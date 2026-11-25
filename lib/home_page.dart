import 'package:flutter/material.dart';

import 'editor_page.dart';
import 'l10n.dart';
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
        title: tr('new_script'),
        text: '',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
      isNew: true,
    );
  }

  Future<void> _duplicate(Script s) async {
    final copy = Script(
      id: ScriptStore.newId(),
      title: '${s.title} ${tr('copy_suffix')}',
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
        title: Text(tr('delete_title')),
        content: Text(tr('delete_body', {'t': s.title})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('delete'),
                style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ScriptStore.delete(s.id);
      _snack(tr('deleted'));
      _load();
    }
  }

  String _ago(int ms) {
    if (ms <= 0) return '';
    final diff =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 1) return tr('ago_now');
    if (diff.inMinutes < 60) return tr('ago_min', {'n': '${diff.inMinutes}'});
    if (diff.inHours < 24) return tr('ago_hour', {'n': '${diff.inHours}'});
    return tr('ago_day', {'n': '${diff.inDays}'});
  }

  // ───────── الواجهة ─────────
  @override
  Widget build(BuildContext context) {
    return LangBuilder(builder: _buildPage);
  }

  Widget _buildPage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 76,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('app_name'),
                style:
                    const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(tr('tagline'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: tr('settings'),
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
        label: Text(tr('new_script'),
            style: const TextStyle(fontWeight: FontWeight.w700)),
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
            Text(tr('no_scripts'),
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(tr('no_scripts_hint'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textDim)),
          ],
        ),
      ),
    );
  }

  Widget _card(Script s) {
    final preview = s.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final mins = s.wordCount == 0 ? 0 : (s.wordCount / 130).ceil();
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => _open(s),
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 6, 14),
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
                      preview.isEmpty ? tr('empty_text') : preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.5,
                          color: AppColors.textDim),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${tr('words', {'n': '${s.wordCount}'})} · ≈ $mins ${tr('min_short')} · ${_ago(s.updatedAt)}',
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
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'dup', child: Text(tr('duplicate'))),
                  PopupMenuItem(value: 'del', child: Text(tr('delete'))),
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
      builder: (ctx) => LangBuilder(
        builder: (_) => StatefulBuilder(
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

            Widget title(String t) => Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Text(t,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accent)),
                );

            // أحجام جاهزة للنافذة العائمة
            Widget preset(String label, double w, double h) {
              final selected =
                  (_settings.frameW - w).abs() < 0.02 &&
                      (_settings.frameH - h).abs() < 0.02;
              return ChoiceChip(
                label: Text(label),
                selected: selected,
                selectedColor: AppColors.accent.withValues(alpha: 0.28),
                onSelected: (_) {
                  setSheet(() {
                    _settings.frameW = w;
                    _settings.frameH = h;
                  });
                  _settings.save();
                },
              );
            }

            return SafeArea(
              child: SingleChildScrollView(
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
                    Text(tr('settings'),
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800)),
                    title(tr('app_language')),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final l in kLangs)
                          ChoiceChip(
                            label: Text(l.name),
                            selected: L10n.code == l.code,
                            selectedColor:
                                AppColors.accent.withValues(alpha: 0.28),
                            onSelected: (_) async {
                              await L10n.set(l.code);
                              setSheet(() {});
                            },
                          ),
                      ],
                    ),
                    title(tr('overlay_size_title')),
                    Wrap(
                      spacing: 8,
                      children: [
                        preset(tr('size_small'), 0.7, 0.3),
                        preset(tr('size_medium'), 0.9, 0.45),
                        preset(tr('size_large'), 0.96, 0.7),
                      ],
                    ),
                    slider(tr('width'), _settings.frameW, 0.4, 1.0,
                        (x) => _settings.frameW = x),
                    slider(tr('height'), _settings.frameH, 0.25, 0.9,
                        (x) => _settings.frameH = x),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('keep_screen')),
                      subtitle: Text(tr('keep_screen_sub'),
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textDim)),
                      value: _settings.keepScreenOn,
                      onChanged: (v) {
                        setSheet(() => _settings.keepScreenOn = v);
                        _settings.save();
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr('settings_hint'),
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textDim),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}