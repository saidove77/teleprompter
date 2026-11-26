import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// هل تُقاس أبعاد «الفتح الأولي» للنافذة العائمة بالبكسل الفعلي (true) أم بوحدات dp (false)؟
///
/// إن ظهرت النافذة عند فتحها كبيرة جداً أو صغيرة جداً، غيّر هذه القيمة.
const bool kOverlayUsesPixels = true;

/// معامل تحويل dp إلى وحدة الحزمة عند الفتح
double overlayScale(double devicePixelRatio) =>
    kOverlayUsesPixels ? devicePixelRatio : 1.0;

/// حجم الشاشة الفعلي بوحدة dp وكثافة البكسل (من الشاشة وليس من حجم النافذة).
/// يُستخدم في التطبيق وفي النافذة العائمة ليتفقا على نفس الحساب.
({double w, double h, double dpr}) displayInfo(ui.FlutterView view) {
  try {
    final d = view.display;
    final dpr = d.devicePixelRatio;
    return (w: d.size.width / dpr, h: d.size.height / dpr, dpr: dpr);
  } catch (_) {
    final dpr = view.devicePixelRatio;
    return (
      w: view.physicalSize.width / dpr,
      h: view.physicalSize.height / dpr,
      dpr: dpr,
    );
  }
}

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