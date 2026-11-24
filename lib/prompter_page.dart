import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'prompter_panel.dart';
import 'settings.dart';

/// شاشة الملقن داخل التطبيق (نفس لوحة النافذة العائمة بملء الشاشة)
class PrompterPage extends StatefulWidget {
  const PrompterPage({super.key, required this.text, required this.settings});

  final String text;
  final PrompterSettings settings;

  @override
  State<PrompterPage> createState() => _PrompterPageState();
}

class _PrompterPageState extends State<PrompterPage> {
  @override
  void initState() {
    super.initState();
    // وضع ملء الشاشة بلا أشرطة النظام
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (widget.settings.keepScreenOn) {
      try {
        WakelockPlus.enable();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    try {
      WakelockPlus.disable();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: PrompterPanel(
            text: widget.text,
            settings: widget.settings,
            onClose: () => Navigator.of(context).pop(),
            onSettingsChanged: (s) => s.saveLook(),
          ),
        ),
      ),
    );
  }
}
