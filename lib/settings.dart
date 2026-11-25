import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// وضع الصوت:
/// follow = تتبع النص (تعرّف على الكلام، يتوقف عند الكلام خارج النص)
/// level  = تمرير بالصوت (يتحرك النص عندما تتكلم ويتوقف عند الصمت، صامت تماماً ويعمل بلا إنترنت)
enum VoiceMode { follow, level }

/// ألوان النص المتاحة
const List<Color> kTextColors = [
  Color(0xFFFFFFFF),
  Color(0xFFFFE066),
  Color(0xFF86EFAC),
  Color(0xFF67E8F9),
  Color(0xFFFDBA74),
];

/// إعدادات الملقن. تُحفظ في SharedPreferences ويقرأها التطبيق والنافذة العائمة معاً.
class PrompterSettings {
  PrompterSettings({
    this.fontSize = 30,
    this.speed = 40,
    this.opacity = 0.85,
    this.lineHeight = 1.6,
    this.margin = 20,
    this.colorIndex = 0,
    this.mirror = false,
    this.alignCenter = true,
    this.countdown = 3,
    this.voiceMode = VoiceMode.level,
    this.sensitivity = 55,
    this.speechLang = '',
    this.frameW = 0.9,
    this.frameH = 0.45,
    this.keepScreenOn = true,
  });

  double fontSize;
  double speed; // بكسل/ثانية
  double opacity; // شفافية خلفية الملقن
  double lineHeight; // تباعد الأسطر
  double margin; // هوامش النص الجانبية
  int colorIndex; // لون النص
  bool mirror; // وضع المرآة
  bool alignCenter; // توسيط النص (وإلا إلى اليمين/البداية)
  int countdown; // العد التنازلي قبل البدء (ثوانٍ، 0 = بدون)
  VoiceMode voiceMode;
  double sensitivity; // عتبة الصوت بالديسيبل (للتمرير بالصوت)
  String speechLang; // لغة الكلام للتتبع ('' = نفس لغة التطبيق)
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
    final vm = (p.getInt('vmode') ?? 1)
        .clamp(0, VoiceMode.values.length - 1)
        .toInt();
    final ci = (p.getInt('color') ?? 0)
        .clamp(0, kTextColors.length - 1)
        .toInt();
    return PrompterSettings(
      fontSize: p.getDouble('font') ?? 30,
      speed: p.getDouble('speed') ?? 40,
      opacity: p.getDouble('opacity') ?? 0.85,
      lineHeight: p.getDouble('lh') ?? 1.6,
      margin: p.getDouble('margin') ?? 20,
      colorIndex: ci,
      mirror: p.getBool('mirror') ?? false,
      alignCenter: p.getBool('alignC') ?? true,
      countdown: p.getInt('countdown') ?? 3,
      voiceMode: VoiceMode.values[vm],
      sensitivity: p.getDouble('thr') ?? 55,
      speechLang: p.getString('slang') ?? '',
      frameW: p.getDouble('fw') ?? 0.9,
      frameH: p.getDouble('fh') ?? 0.45,
      keepScreenOn: p.getBool('keepOn') ?? true,
    );
  }

  /// حفظ مظهر الملقن والصوت (من داخل الملقن أو النافذة العائمة)
  Future<void> saveLook() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('font', fontSize);
    await p.setDouble('speed', speed);
    await p.setDouble('opacity', opacity);
    await p.setDouble('lh', lineHeight);
    await p.setDouble('margin', margin);
    await p.setInt('color', colorIndex);
    await p.setBool('mirror', mirror);
    await p.setBool('alignC', alignCenter);
    await p.setInt('countdown', countdown);
    await p.setInt('vmode', voiceMode.index);
    await p.setDouble('thr', sensitivity);
    await p.setString('slang', speechLang);
  }

  /// حفظ كل الإعدادات (من الشاشة الرئيسية)
  Future<void> save() async {
    await saveLook();
    final p = await SharedPreferences.getInstance();
    await p.setDouble('fw', frameW);
    await p.setDouble('fh', frameH);
    await p.setBool('keepOn', keepScreenOn);
  }
}