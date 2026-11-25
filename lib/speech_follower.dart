import 'dart:async';
import 'dart:math' show min;

import 'package:noise_meter/noise_meter.dart';
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

/// يقارن ما نطقه المستخدم بالنص المكتوب ويحدد موضع القراءة (عربي، إنجليزي، فرنسي...).
/// - إن طابق النص: يتقدم الموضع.
/// - إن تكلم بكلام غير موجود في النص: يصبح «خارج النص» ويتوقف التقدم.
/// - إن عاد فقرأ كلمتين متتاليتين من النص: يستأنف.
class ScriptMatcher {
  List<ScriptWord> words = [];
  int pos = 0; // رقم الكلمة التالية المتوقع قراءتها
  bool offScript = false;
  int _misses = 0;

  static const Map<String, String> _latin = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
    'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ı': 'i',
    'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ý': 'y', 'ÿ': 'y', 'ğ': 'g', 'ş': 's', 'œ': 'oe', 'æ': 'ae',
  };

  /// توحيد الكلمات لتسهيل المقارنة:
  /// العربية: حذف التشكيل وتوحيد الألف والياء والتاء المربوطة.
  /// اللاتينية: أحرف صغيرة وحذف علامات التشكيل (é → e ...).
  static String normalize(String s) {
    var t = s.replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '');
    t = t.replaceAll(RegExp(r'[إأآٱ]'), 'ا');
    t = t
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي');
    t = t.toLowerCase();
    final b = StringBuffer();
    for (final r in t.runes) {
      final ch = String.fromCharCode(r);
      b.write(_latin[ch] ?? ch);
    }
    t = b.toString().replaceAll('ß', 'ss');
    // نُبقي الحروف والأرقام من كل اللغات فقط
    t = t.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    return t;
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

  /// يضع موضع القراءة عند كلمة معينة (بعد تمرير المستخدم النص بإصبعه)
  void jumpTo(int index) {
    pos = words.isEmpty ? 0 : index.clamp(0, words.length - 1).toInt();
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
        // كلمة قصيرة وحدها غير كافية (مثل: في، من، of، de)
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

/// نتيجة تهيئة الميكروفون / خدمة الكلام
enum SpeechInit { ok, noPermission, unavailable }

/// استماع متواصل عبر خدمة التعرف على الكلام، بلغة النص، مع تجربة عدة لهجات
/// وإعادة تشغيل تلقائية.
class SpeechFollower {
  SpeechFollower({
    required this.matcher,
    required this.onResult,
    this.onFatal,
  });

  final ScriptMatcher matcher;
  final void Function(MatchResult result, String heard) onResult;

  /// messageKey (مفتاح ترجمة) + هل المشكلة في اللغة/الخدمة (فيُحوَّل إلى التمرير بالصوت)
  final void Function(String messageKey, bool languageIssue)? onFatal;

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _ready = false;
  String _lang = '';
  List<String> _candidates = [];
  int _candIdx = 0;
  int _errCount = 0;
  bool _want = false;
  bool _foreground = true;
  Timer? _restartTimer;

  static const Map<String, List<String>> _prefs = {
    'ar': ['ar_sa', 'ar_ae', 'ar_eg', 'ar_ma', 'ar_dz', 'ar'],
    'en': ['en_us', 'en_gb', 'en_au', 'en_ca', 'en'],
    'fr': ['fr_fr', 'fr_ca', 'fr_be', 'fr_ch', 'fr'],
    'es': ['es_es', 'es_mx', 'es_us', 'es_ar', 'es'],
    'de': ['de_de', 'de_at', 'de_ch', 'de'],
    'tr': ['tr_tr', 'tr'],
  };

  static const Map<String, String> _blind = {
    'ar': 'ar_SA',
    'en': 'en_US',
    'fr': 'fr_FR',
    'es': 'es_ES',
    'de': 'de_DE',
    'tr': 'tr_TR',
  };

  /// [lang] رمز اللغة: ar / en / fr / es / de / tr
  Future<SpeechInit> init(String lang) async {
    if (_ready && _candidates.isNotEmpty && _lang == lang) {
      return SpeechInit.ok;
    }

    var st = await Permission.microphone.status;
    if (!st.isGranted) st = await Permission.microphone.request();
    if (!st.isGranted) return SpeechInit.noPermission;

    if (!_ready) {
      try {
        _ready = await _speech.initialize(
          onStatus: _onStatus,
          onError: _onError,
        );
      } catch (_) {
        _ready = false;
      }
    }
    if (!_ready) return SpeechInit.unavailable;

    // نجمع لهجات اللغة المطلوبة المتاحة ونرتبها حسب الأفضلية
    final locales = await _speech.locales();
    final order = _prefs[lang] ?? [lang];
    int rank(String id) {
      final i = order.indexOf(id.replaceAll('-', '_').toLowerCase());
      return i < 0 ? order.length : i;
    }

    final found = locales
        .map((l) => l.localeId as String)
        .where((id) => id.replaceAll('-', '_').toLowerCase().split('_').first == lang)
        .toList()
      ..sort((a, b) => rank(a).compareTo(rank(b)));

    // إن لم تُدرج اللغة نجرّب مباشرة (بعض الأجهزة لا تُظهر القائمة كاملة)
    _candidates = found.isNotEmpty ? found : [_blind[lang] ?? lang, lang];
    _candIdx = 0;
    _errCount = 0;
    _lang = lang;
    return SpeechInit.ok;
  }

  Future<void> start() async {
    if (!_ready || _candidates.isEmpty) return;
    _want = true;
    if (_speech.isListening) return;
    try {
      await _speech.listen(
        onResult: (dynamic r) {
          if (!_want) return;
          _errCount = 0;
          final String words = r.recognizedWords as String;
          onResult(matcher.feed(words), words);
        },
        localeId: _candidates[_candIdx],
        listenFor: const Duration(minutes: 30),
        pauseFor: const Duration(seconds: 20),
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
      onFatal?.call('err_no_permission', false);
      return;
    }

    // مشكلة لغة: نجرّب لهجة أخرى، وإن انتهت الخيارات نعلن الفشل
    if (msg.contains('language')) {
      if (_candIdx + 1 < _candidates.length) {
        _candIdx++;
        if (_want && _foreground) {
          _scheduleRestart(const Duration(milliseconds: 300));
        }
        return;
      }
      _want = false;
      onFatal?.call('err_lang_unsupported', true);
      return;
    }

    // أخطاء الشبكة/الخادم المتكررة
    if (msg == 'error_network' ||
        msg == 'error_network_timeout' ||
        msg == 'error_server' ||
        msg == 'error_server_disconnected') {
      _errCount++;
      if (_errCount >= 6) {
        _want = false;
        _errCount = 0;
        onFatal?.call('err_network', true);
        return;
      }
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

/// كاشف الصوت (صامت تماماً): يعلن «يتكلم» عندما يرتفع مستوى الصوت فوق العتبة
/// و«صمت» بعد 0.8 ثانية من الهدوء. لا يحتاج لخدمة Google، ويعمل بأي لغة وبدون إنترنت،
/// ولا يُصدر أي نقرة أو صوت.
class VoiceLevelDetector {
  VoiceLevelDetector({
    required this.onSpeaking,
    required this.onSilence,
    required this.onLevel,
  });

  final void Function() onSpeaking;
  final void Function() onSilence;
  final void Function(double db) onLevel;

  double threshold = 55;

  NoiseMeter? _meter;
  StreamSubscription<NoiseReading>? _sub;
  Timer? _silenceTimer;
  bool _speaking = false;

  Future<SpeechInit> start() async {
    var st = await Permission.microphone.status;
    if (!st.isGranted) st = await Permission.microphone.request();
    if (!st.isGranted) return SpeechInit.noPermission;
    if (_sub != null) return SpeechInit.ok;
    try {
      _meter ??= NoiseMeter();
      _sub = _meter!.noise.listen(
        _onReading,
        onError: (_) {
          stop();
        },
      );
      return SpeechInit.ok;
    } catch (_) {
      return SpeechInit.unavailable;
    }
  }

  void _onReading(NoiseReading r) {
    final db = r.meanDecibel;
    onLevel(db);
    if (db >= threshold) {
      _silenceTimer?.cancel();
      _silenceTimer = null;
      if (!_speaking) {
        _speaking = true;
        onSpeaking();
      }
    } else if (_speaking && _silenceTimer == null) {
      _silenceTimer = Timer(const Duration(milliseconds: 800), () {
        _silenceTimer = null;
        _speaking = false;
        onSilence();
      });
    }
  }

  Future<void> stop() async {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _speaking = false;
    await _sub?.cancel();
    _sub = null;
  }
}