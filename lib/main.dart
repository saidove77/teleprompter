import 'package:flutter/material.dart';

import 'home_page.dart';
import 'l10n.dart';
import 'overlay_app.dart';
import 'overlay_bridge.dart';

/// نقطة دخول النافذة العائمة. يجب أن تبقى هنا في main.dart وباسمها هذا.
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayApp());
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await L10n.load(); // لغة التطبيق المحفوظة (أو لغة الهاتف)
  OverlayBridge.start(); // يستمع لطلبات النص من النافذة العائمة
  runApp(const TeleprompterApp());
}

class TeleprompterApp extends StatelessWidget {
  const TeleprompterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return localizedApp(home: const HomePage());
  }
}