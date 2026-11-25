import 'dart:convert';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// هل تُقاس أبعاد ومواضع النافذة العائمة في هذه الحزمة بالبكسل الفعلي (true)
/// أم بوحدات dp (false)؟
///
/// سبب صغر النافذة سابقاً: كنا نرسل أرقاماً بوحدة dp بينما الحزمة تقرؤها بالبكسل.
/// إن ظهرت النافذة الآن كبيرة جداً أو صغيرة جداً، غيّر هذه القيمة إلى false.
const bool kOverlayUsesPixels = true;

/// معامل تحويل dp إلى وحدة الحزمة
double overlayScale(double devicePixelRatio) =>
    kOverlayUsesPixels ? devicePixelRatio : 1.0;

/// جسر بين التطبيق والنافذة العائمة لإرسال النص.
/// - النافذة العائمة ترسل «ready» عند فتحها، فيردّ التطبيق بالنص.
/// - كما يُرسل النص عدة مرات بعد فتح النافذة لضمان وصوله.
class OverlayBridge {
  OverlayBridge._();

  static String text = '';
  static String title = '';
  static bool _started = false;

  /// تُستدعى مرة واحدة في main()
  static void start() {
    if (_started) return;
    _started = true;
    try {
      FlutterOverlayWindow.overlayListener.listen((event) {
        if (event is! String) return;
        try {
          final m = jsonDecode(event);
          if (m is Map && m['type'] == 'ready') push();
        } catch (_) {}
      });
    } catch (_) {}
  }

  static Future<void> push() async {
    try {
      await FlutterOverlayWindow.shareData(
        jsonEncode({'text': text, 'title': title}),
      );
    } catch (_) {}
  }

  static Future<void> pushRepeatedly() async {
    for (final ms in const [500, 1200, 2500]) {
      await Future.delayed(Duration(milliseconds: ms));
      await push();
    }
  }
}