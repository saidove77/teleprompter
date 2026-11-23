import 'package:shared_preferences/shared_preferences.dart';

const String kDefaultScript =
    'مرحباً بك في الملقن الذكي.\n\n'
    'اكتب نصك هنا أو الصقه، ثم شغّل الملقن. '
    'يمكنك تفعيل الميكروفون ليتحرك النص مع قراءتك فقط، '
    'ويتوقف عندما تتكلم خارج النص لتشرح ما تريد.';

/// إعدادات الملقن. تُحفظ في SharedPreferences ويقرأها التطبيق والنافذة العائمة معاً.
class PrompterSettings {
  PrompterSettings({
    this.fontSize = 30,
    this.speed = 40,
    this.opacity = 0.85,
    this.frameW = 0.92,
    this.frameH = 0.5,
    this.keepScreenOn = true,
  });

  double fontSize;
  double speed; // بكسل/ثانية (للتمرير التلقائي)
  double opacity; // شفافية خلفية الملقن
  double frameW; // عرض النافذة العائمة (نسبة من الشاشة)
  double frameH; // ارتفاع النافذة العائمة (نسبة من الشاشة)
  bool keepScreenOn;

  static Future<SharedPreferences> _prefs() async {
    final p = await SharedPreferences.getInstance();
    await p.reload(); // لقراءة آخر قيم كتبتها النافذة العائمة
    return p;
  }

  static Future<PrompterSettings> load() async {
    final p = await _prefs();
    return PrompterSettings(
      fontSize: p.getDouble('font') ?? 30,
      speed: p.getDouble('speed') ?? 40,
      opacity: p.getDouble('opacity') ?? 0.85,
      frameW: p.getDouble('fw') ?? 0.92,
      frameH: p.getDouble('fh') ?? 0.5,
      keepScreenOn: p.getBool('keepOn') ?? true,
    );
  }

  /// حفظ كل الإعدادات (من الشاشة الرئيسية)
  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('font', fontSize);
    await p.setDouble('speed', speed);
    await p.setDouble('opacity', opacity);
    await p.setDouble('fw', frameW);
    await p.setDouble('fh', frameH);
    await p.setBool('keepOn', keepScreenOn);
  }

  /// حفظ مظهر الملقن فقط (من داخل الملقن أو النافذة العائمة)
  Future<void> saveLook() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('font', fontSize);
    await p.setDouble('speed', speed);
    await p.setDouble('opacity', opacity);
  }

  static Future<String> loadScript() async {
    final p = await _prefs();
    return p.getString('script') ?? kDefaultScript;
  }

  static Future<void> saveScript(String text) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('script', text);
  }
}
