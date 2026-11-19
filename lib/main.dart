import 'package:flutter/material.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const TeleprompterApp());
}

class TeleprompterApp extends StatelessWidget {
  const TeleprompterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pro Teleprompter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
      ),
      home: const TeleprompterHomePage(),
    );
  }
}

class TeleprompterHomePage extends StatefulWidget {
  const TeleprompterHomePage({super.key});

  @override
  State<TeleprompterHomePage> createState() => _TeleprompterHomePageState();
}

class _TeleprompterHomePageState extends State<TeleprompterHomePage> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  Timer? _scrollTimer;
  bool _isPlaying = false;
  double _scrollSpeed = 1.0;
  double _fontSize = 28.0;
  double _opacity = 0.85;
  bool _isEditingMode = true;

  @override
  void initState() {
    super.initState();
    _loadSavedText();
  }

  Future<void> _saveText(String text) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('teleprompter_saved_text', text);
  }

  Future<void> _loadSavedText() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedText = prefs.getString('teleprompter_saved_text');
    if (savedText != null && savedText.isNotEmpty) {
      _textController.text = savedText;
    } else {
      _textController.text =
          "مرحباً بك في تطبيق الملقن الاحترافي. يدعم هذا التطبيق النصوص الضخمة لأكثر من 10,000 حرف بكل سلاسة.\n\nاكتب أو الصق نصك هنا، ثم انقر على زر القراءة بالأعلى لبدء البث أو التصوير...\n\n" *
              10;
    }
    setState(() {});
  }

  void _toggleScrolling() {
    if (_isPlaying) {
      _stopScrolling();
    } else {
      _startScrolling();
    }
  }

  void _startScrolling() {
    setState(() {
      _isPlaying = true;
      _isEditingMode = false;
    });

    _scrollTimer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (_scrollController.hasClients) {
        double maxScroll = _scrollController.position.maxScrollExtent;
        double currentScroll = _scrollController.offset;

        if (currentScroll >= maxScroll) {
          _stopScrolling();
        } else {
          _scrollController.jumpTo(currentScroll + _scrollSpeed);
        }
      }
    });
  }

  void _stopScrolling() {
    _scrollTimer?.cancel();
    setState(() {
      _isPlaying = false;
    });
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withOpacity(_opacity),
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: Text(_isEditingMode
            ? 'إدارة النص (أكثر من 10,000 حرف)'
            : 'وضع الملقن العائم (Teleprompter)'),
        actions: [
          if (_isEditingMode)
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: 'حفظ النص',
              onPressed: () {
                _saveText(_textController.text);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تم حفظ النص بنجاح!')),
                );
              },
            ),
          IconButton(
            icon: Icon(_isEditingMode ? Icons.play_arrow : Icons.edit),
            tooltip: _isEditingMode ? 'بدء القراءة' : 'تعديل النص',
            onPressed: () {
              if (_isEditingMode) {
                if (_textController.text.isEmpty) return;
                _saveText(_textController.text);
                setState(() => _isEditingMode = false);
              } else {
                _stopScrolling();
                setState(() => _isEditingMode = true);
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_isEditingMode)
            Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Wrap(
                spacing: 15,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _toggleScrolling,
                    icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                    label: Text(_isPlaying ? 'إيقاف' : 'تشغيل'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isPlaying ? Colors.orange : Colors.green,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('السرعة:'),
                      SizedBox(
                        width: 100,
                        child: Slider(
                          value: _scrollSpeed,
                          min: 0.5,
                          max: 5.0,
                          divisions: 9,
                          label: _scrollSpeed.toStringAsFixed(1),
                          onChanged: (val) => setState(() => _scrollSpeed = val),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('الخط:'),
                      SizedBox(
                        width: 100,
                        child: Slider(
                          value: _fontSize,
                          min: 18.0,
                          max: 60.0,
                          divisions: 21,
                          label: _fontSize.round().toString(),
                          onChanged: (val) => setState(() => _fontSize = val),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('الشفافية:'),
                      SizedBox(
                        width: 100,
                        child: Slider(
                          value: _opacity,
                          min: 0.3,
                          max: 1.0,
                          divisions: 7,
                          label: _opacity.toStringAsFixed(1),
                          onChanged: (val) => setState(() => _opacity = val),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: _isEditingMode
                  ? TextField(
                      controller: _textController,
                      maxLines: null,
                      expands: true,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 16, color: Colors.white),
                      decoration: const InputDecoration(
                        hintText:
                            'اكتب أو الصق نصك هنا (يدعم أكثر من 10,000 حرف بكل سلاسة)...',
                        hintStyle: TextStyle(color: Colors.grey),
                        border: OutlineInputBorder(),
                      ),
                    )
                  : GestureDetector(
                      onTap: _toggleScrolling,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        physics: const BouncingScrollPhysics(),
                        child: Directionality(
                          textDirection: TextDirection.rtl,
                          child: Text(
                            _textController.text,
                            style: TextStyle(
                              fontSize: _fontSize,
                              color: Colors.white,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}