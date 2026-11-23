import 'dart:async';
import 'dart:math' show min;

import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// كلمة من النص مع موضعها (رقم الحرف) في النص الأصلي
class ScriptWord {
  final String norm;
  final int start;
  const ScriptWord(this.norm, this.start);
}

enum MatchEvent { none, advanced, wentOff, backOn, finished }

class MatchResult {
  final MatchEvent event;
  final int pos;
  const MatchResult(this.event, this.pos);
}

/// يقارن ما نطقه المستخدم بالنص المكتوب ويحدد موضع القراءة.
/// - إن طابق النص: يتقدم الموضع.
/// - إن تكلم بكلام غير موجود في النص: يصبح «خارج النص» ويتوقف التقدم.
/// - إن عاد فقرأ كلمتين متتاليتين من النص: يستأنف.
class ScriptMatcher {
  List<ScriptWord> words = [];
  int pos = 0; // رقم الكلمة التالية المتوقع قراءتها
  bool offScript = false;
  int _misses = 0;

  /// توحيد الكلمات العربية لتسهيل المقارنة (حذف التشكيل وتوحيد الألف والياء...)
  static String normalize(String s) {
    var t = s.replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '');
    t = t.replaceAll(RegExp(r'[إأآٱ]'), 'ا');
    t = t
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي');
    t = t.replaceAll(RegExp(r'[^\u0621-\u064A0-9a-zA-Z]'), '');
    return t.toLowerCase();
  }

  static int _lev(String a, String b) {
    final m = a.length, n = b.length;
    var prev = List<int>.generate(n + 1, (j) => j);
    for (var i = 1; i <= m; i++) {
      final cur = List<int>.filled(n + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
      }
      prev = cur;
    }
    return prev[n];
  }

  static bool _same(String a, String b) {
    if (a == b) return true;
    if (a.length >= 4 && b.length >= 4 && (a.length - b.length).abs() <= 1) {
      return _lev(a, b) <= 1; // تسامح مع خطأ حرف واحد
    }
    return false;
  }

  void setText(String text) {
    words = [];
    for (final m in RegExp(r'\S+').allMatches(text)) {
      final n = normalize(m.group(0)!);
      if (n.isNotEmpty) words.add(ScriptWord(n, m.start));
    }
    reset();
  }

  void reset() {
    pos = 0;
    _misses = 0;
    offScript = false;
  }

  MatchResult feed(String recognized) {
    final n = words.length;
    if (n == 0) return MatchResult(MatchEvent.none, pos);

    final spoken = recognized
        .split(RegExp(r'\s+'))
        .map(normalize)
        .where((w) => w.isNotEmpty)
        .toList();
    if (spoken.isEmpty) return MatchResult(MatchEvent.none, pos);

    final tail =
        spoken.length > 5 ? spoken.sublist(spoken.length - 5) : spoken;
    final minRun = offScript ? 2 : 1; // للعودة إلى النص نطلب كلمتين متتاليتين
    final lo = (pos - (offScript ? 60 : 10)).clamp(0, n - 1).toInt();
    final hi = (pos + (offScript ? 60 : 25)).clamp(0, n - 1).toInt();

    var bestEnd = -1, bestRun = 0, bestT = -1, bestDist = 1 << 30;
    for (var t = tail.length - 1; t >= 0; t--) {
      for (var e = lo; e <= hi; e++) {
        if (!_same(tail[t], words[e].norm)) continue;
        var run = 1;
        while (t - run >= 0 &&
            e - run >= 0 &&
            _same(tail[t - run], words[e - run].norm)) {
          run++;
        }
        // كلمة قصيرة وحدها غير كافية (مثل: في، من)
        if (run == 1 && tail[t].length < 3) continue;
        final dist = (e - pos).abs();
        if (run > bestRun ||
            (run == bestRun && t == bestT && dist < bestDist)) {
          bestRun = run;
          bestEnd = e;
          bestT = t;
          bestDist = dist;
        }
      }
    }

    if (bestEnd >= 0 && bestRun >= minRun) {
      _misses = 0;
      final wasOff = offScript;
      offScript = false;
      pos = (bestEnd + 1).clamp(0, n).toInt();
      if (pos >= n) return MatchResult(MatchEvent.finished, pos);
      return MatchResult(wasOff ? MatchEvent.backOn : MatchEvent.advanced, pos);
    }

    if (spoken.length >= 2) {
      _misses++;
      if (_misses >= 2 && !offScript) {
        offScript = true;
        return MatchResult(MatchEvent.wentOff, pos);
      }
    }
    return MatchResult(MatchEvent.none, pos);
  }
}

/// غلاف حول خدمة التعرف على الكلام: استماع متواصل مع إعادة تشغيل تلقائية.
class SpeechFollower {
  SpeechFollower({
    required this.matcher,
    required this.onResult,
    this.onFatal,
  });

  final ScriptMatcher matcher;
  final void Function(MatchResult result, String heard) onResult;
  final void Function(String message)? onFatal;

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _ready = false;
  String? _localeId;
  bool _want = false;
  bool _foreground = true;
  Timer? _restartTimer;

  /// يجهّز الخدمة. يعيد null عند النجاح، أو رسالة خطأ بالعربية.
  Future<String?> init() async {
    if (_ready && _localeId != null) return null;

    var st = await Permission.microphone.status;
    if (!st.isGranted) st = await Permission.microphone.request();
    if (!st.isGranted) {
      return 'يلزم السماح بالميكروفون من إعدادات التطبيق';
    }

    try {
      _ready = await _speech.initialize(
        onStatus: _onStatus,
        onError: _onError,
      );
    } catch (_) {
      _ready = false;
    }
    if (!_ready) return 'خدمة التعرف على الكلام غير متوفرة هنا';

    final locales = await _speech.locales();
    String? pick;
    for (final l in locales) {
      if (l.localeId.replaceAll('-', '_').toLowerCase() == 'ar_sa') {
        pick = l.localeId;
        break;
      }
    }
    if (pick == null) {
      for (final l in locales) {
        if (l.localeId.toLowerCase().startsWith('ar')) {
          pick = l.localeId;
          break;
        }
      }
    }
    if (pick == null) {
      return 'اللغة العربية غير متوفرة في خدمة التعرف على الكلام';
    }
    _localeId = pick;
    return null;
  }

  Future<void> start() async {
    if (!_ready) return;
    _want = true;
    if (_speech.isListening) return;
    try {
      await _speech.listen(
                onResult: (dynamic r) {
          if (!_want) return;
          final String words = r.recognizedWords as String;
          onResult(matcher.feed(words), words);
        },
        localeId: _localeId,
        listenFor: const Duration(minutes: 10),
        pauseFor: const Duration(seconds: 8),
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
        ),
      );
    } catch (_) {}
  }

  Future<void> pause() async {
    _want = false;
    _restartTimer?.cancel();
    try {
      await _speech.stop();
    } catch (_) {}
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) {
      _restartTimer?.cancel();
      if (_speech.isListening) _speech.stop();
    } else if (_want) {
      _scheduleRestart(const Duration(milliseconds: 300));
    }
  }

  void _onStatus(String status) {
    if ((status == 'done' || status == 'notListening') &&
        _want &&
        _foreground) {
      _scheduleRestart(const Duration(milliseconds: 400));
    }
  }

    void _onError(dynamic e) {
    String msg;
    try {
      msg = (e.errorMsg as String?) ?? '';
    } catch (_) {
      msg = e.toString();
    }
    if (msg == 'error_permission') {
      _want = false;
      onFatal?.call('لا يوجد إذن للميكروفون');
      return;
    }
    if (msg.contains('language')) {
      _want = false;
      onFatal?.call('اللغة العربية غير مدعومة في خدمة التعرف على الكلام');
      return;
    }
    if (_want && _foreground) {
      _scheduleRestart(const Duration(milliseconds: 700));
    }
  }

  void _scheduleRestart(Duration d) {
    _restartTimer?.cancel();
    _restartTimer = Timer(d, () {
      if (_want && _foreground && !_speech.isListening) start();
    });
  }

  void dispose() {
    _want = false;
    _restartTimer?.cancel();
    _speech.cancel();
  }
}
