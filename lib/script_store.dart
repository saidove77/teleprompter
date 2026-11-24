import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const String kDefaultScript =
    'مرحباً بك في الملقن الذكي.\n\n'
    'اكتب نصك هنا أو الصقه، ثم شغّل الملقن. '
    'يمكنك تفعيل الميكروفون ليتحرك النص مع قراءتك فقط، '
    'ويتوقف عندما تتكلم خارج النص لتشرح ما تريد.';

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
        title: (j['title'] as String?) ?? 'بدون عنوان',
        text: (j['text'] as String?) ?? '',
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );

  int get wordCount {
    final t = text.trim();
    return t.isEmpty ? 0 : t.split(RegExp(r'\s+')).length;
  }
}

/// مكتبة النصوص (تُحفظ في SharedPreferences)
class ScriptStore {
  ScriptStore._();

  static const _key = 'scripts_v1';
  static const _activeKey = 'active_script';

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

  /// تحميل كل النصوص. عند أول تشغيل ينقل النص القديم (إن وجد) إلى المكتبة.
  static Future<List<Script>> load() async {
    final p = await _prefs();
    var list = <Script>[];
    final raw = p.getString(_key);
    if (raw != null) {
      try {
        list = _parse(raw);
      } catch (_) {}
    }
    if (list.isEmpty) {
      final old = p.getString('script');
      list.add(Script(
        id: newId(),
        title: 'نصي الأول',
        text: (old != null && old.trim().isNotEmpty) ? old : kDefaultScript,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await saveAll(list);
    }
    return list;
  }

  static Future<void> saveAll(List<Script> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(list.map((s) => s.toJson()).toList()));
  }

  static Future<void> upsert(Script s) async {
    final list = await load();
    final i = list.indexWhere((x) => x.id == s.id);
    if (i >= 0) {
      list[i] = s;
    } else {
      list.add(s);
    }
    await saveAll(list);
  }

  static Future<void> delete(String id) async {
    final list = await load();
    list.removeWhere((x) => x.id == id);
    await saveAll(list);
  }

  static Future<void> setActive(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_activeKey, id);
  }

  /// نص النص النشط (تقرؤه النافذة العائمة عند التشغيل)
  static Future<String?> activeText() async {
    final p = await _prefs();
    final raw = p.getString(_key);
    if (raw == null) return p.getString('script');
    try {
      final list = _parse(raw);
      final id = p.getString(_activeKey);
      final s = list.firstWhere((x) => x.id == id, orElse: () => list.first);
      return s.text;
    } catch (_) {
      return null;
    }
  }
}
