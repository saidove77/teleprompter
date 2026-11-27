import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'l10n.dart';

/// نص واحد في المكتبة
class Script {
  Script({
    required this.id,
    required this.title,
    required this.text,
    required this.updatedAt,
  });

  String id;
  String title;
  String text;
  int updatedAt; // milliseconds since epoch

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'text': text,
        'updatedAt': updatedAt,
      };

  factory Script.fromJson(Map<String, dynamic> j) => Script(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? tr('untitled'),
        text: (j['text'] as String?) ?? '',
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );

  int get wordCount {
    final t = text.trim();
    return t.isEmpty ? 0 : t.split(RegExp(r'\s+')).length;
  }
}

/// مكتبة النصوص (تُحفظ في SharedPreferences).
/// كل العمليات تُنفَّذ بالتتابع (قفل) حتى لا يمحو حفظٌ حفظاً آخر.
class ScriptStore {
  ScriptStore._();

  static const _key = 'scripts_v1';
  static const _activeKey = 'active_script';

  static Future<void> _chain = Future<void>.value();

  static Future<T> _locked<T>(Future<T> Function() action) {
    final c = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        c.complete(await action());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  static Future<SharedPreferences> _prefs() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    return p;
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  static List<Script> _parse(String raw) {
    final data = jsonDecode(raw) as List;
    return data
        .map((e) => Script.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  static Future<void> _saveUnlocked(List<Script> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(list.map((s) => s.toJson()).toList()));
  }

  static Future<List<Script>> _loadUnlocked() async {
    final p = await _prefs();
    var list = <Script>[];
    final raw = p.getString(_key);
    if (raw != null) {
      try {
        list = _parse(raw);
      } catch (_) {}
    }
    if (list.isEmpty) {
      // أول تشغيل: ننقل النص القديم (إن وُجد) أو نضع نص الترحيب
      final old = p.getString('script');
      list.add(Script(
        id: newId(),
        title: tr('first_script'),
        text: (old != null && old.trim().isNotEmpty)
            ? old
            : tr('welcome_text'),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await _saveUnlocked(list);
    }
    return list;
  }

  /// تحميل كل النصوص
  static Future<List<Script>> load() => _locked(_loadUnlocked);

  static Future<void> saveAll(List<Script> list) =>
      _locked(() => _saveUnlocked(list));

  /// حفظ نص (إضافة أو تحديث)
  static Future<void> upsert(Script s) => _locked(() async {
        final list = await _loadUnlocked();
        final i = list.indexWhere((x) => x.id == s.id);
        if (i >= 0) {
          list[i] = s;
        } else {
          list.add(s);
        }
        await _saveUnlocked(list);
      });

  static Future<void> delete(String id) => _locked(() async {
        final list = await _loadUnlocked();
        list.removeWhere((x) => x.id == id);
        await _saveUnlocked(list);
      });

  static Future<void> setActive(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_activeKey, id);
  }

  /// نص النص النشط (تقرؤه النافذة العائمة عند التشغيل)
  static Future<String?> activeText() => _locked(() async {
        final p = await _prefs();
        final raw = p.getString(_key);
        if (raw == null) return p.getString('script');
        try {
          final list = _parse(raw);
          final id = p.getString(_activeKey);
          final s =
              list.firstWhere((x) => x.id == id, orElse: () => list.first);
          return s.text;
        } catch (_) {
          return null;
        }
      });
}
