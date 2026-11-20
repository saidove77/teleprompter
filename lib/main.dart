import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayTeleprompterApp());
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
        useMaterial3: true,
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
  final TextEditingController _scriptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isPrompterMode = false;
  bool _isScrolling = false;
  bool _keepScreenOn = true;
  bool _voiceControlEnabled = false;
  bool _isOverlayActive = false;

  double _fontSize = 28.0;
  double _scrollSpeed = 35.0; // بكسل في الثانية
  double _opacity = 0.85;
  double _frameWidthFactor = 0.92;
  double _frameHeightFactor = 0.72;
  double _voiceThresholdDb = 55.0;

  Timer? _scrollTimer;
  NoiseMeter? _noiseMeter;
  StreamSubscription<NoiseReading>? _noiseSubscription;
  double _currentDb = 0.0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _applyWakelock();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _scriptController.text = prefs.getString('saved_script') ??
          'مرحباً بك في تطبيق الملقن الذكي.\n\nيمكنك تعديل هذا النص أو لصق نصك الكامل من شاشة التحرير، ثم الانتقال إلى وضع الملقن للتحكم في الشفافية وحجم الخط والإطار والتشغيل بالصوت أو النافذة العائمة.';
      _fontSize = prefs.getDouble('font_size') ?? 28.0;
      _scrollSpeed = prefs.getDouble('scroll_speed') ?? 35.0;
      _opacity = prefs.getDouble('opacity') ?? 0.85;
      _frameWidthFactor = prefs.getDouble('frame_width') ?? 0.92;
      _frameHeightFactor = prefs.getDouble('frame_height') ?? 0.72;
      _keepScreenOn = prefs.getBool('keep_screen_on') ?? true;
      _voiceControlEnabled = prefs.getBool('voice_control') ?? false;
      _voiceThresholdDb = prefs.getDouble('voice_threshold') ?? 55.0;
    });
    _applyWakelock();
    if (_voiceControlEnabled) {
      await _startVoiceListener();
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_script', _scriptController.text);
    await prefs.setDouble('font_size', _fontSize);
    await prefs.setDouble('scroll_speed', _scrollSpeed);
    await prefs.setDouble('opacity', _opacity);
    await prefs.setDouble('frame_width', _frameWidthFactor);
    await prefs.setDouble('frame_height', _frameHeightFactor);
    await prefs.setBool('keep_screen_on', _keepScreenOn);
    await prefs.setBool('voice_control', _voiceControlEnabled);
    await prefs.setDouble('voice_threshold', _voiceThresholdDb);
  }

  Future<void> _applyWakelock() async {
    try {
      if (_keepScreenOn) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  }

  void _startScrolling() {
    if (_isScrolling) return;
    setState(() => _isScrolling = true);
    _scrollTimer?.cancel();
    const tickMs = 30;
    _scrollTimer = Timer.periodic(const Duration(milliseconds: tickMs), (timer) {
      if (!_scrollController.hasClients) return;
      final maxExtent = _scrollController.position.maxScrollExtent;
      final nextPos = _scrollController.offset + (_scrollSpeed * tickMs / 1000.0);
      if (nextPos >= maxExtent) {
        _scrollController.jumpTo(maxExtent);
        _stopScrolling();
      } else {
        _scrollController.jumpTo(nextPos);
      }
    });
  }

  void _stopScrolling() {
    _scrollTimer?.cancel();
    if (mounted && _isScrolling) {
      setState(() => _isScrolling = false);
    }
  }

  void _toggleScrolling() {
    if (_isScrolling) {
      _stopScrolling();
    } else {
      _startScrolling();
    }
  }

  Future<void> _toggleVoiceControl() async {
    final nextState = !_voiceControlEnabled;
    setState(() => _voiceControlEnabled = nextState);
    if (nextState) {
      await _startVoiceListener();
    } else {
      await _stopVoiceListener();
    }
    await _saveSettings();
  }

  Future<void> _startVoiceListener() async {
    try {
      _noiseMeter ??= NoiseMeter();
      await _noiseSubscription?.cancel();
      _noiseSubscription = _noiseMeter!.noise.listen(
        (NoiseReading reading) {
          if (!mounted || !_voiceControlEnabled) return;
          setState(() => _currentDb = reading.meanDecibel);
          if (reading.meanDecibel >= _voiceThresholdDb) {
            if (!_isScrolling && _isPrompterMode) {
              _startScrolling();
            }
          } else {
            if (_isScrolling) {
              _stopScrolling();
            }
          }
        },
        onError: (_) {
          if (mounted) {
            setState(() => _voiceControlEnabled = false);
          }
        },
      );
    } catch (_) {
      if (mounted) {
        setState(() => _voiceControlEnabled = false);
      }
    }
  }

  Future<void> _stopVoiceListener() async {
    await _noiseSubscription?.cancel();
    _noiseSubscription = null;
    if (mounted) {
      setState(() => _currentDb = 0.0);
    }
  }

  Future<void> _toggleFloatingWindow() async {
    try {
      final isGranted = await FlutterOverlayWindow.isPermissionGranted();
      if (!isGranted) {
        await FlutterOverlayWindow.requestPermission();
        return;
      }

      if (_isOverlayActive) {
        await FlutterOverlayWindow.closeOverlay();
        setState(() => _isOverlayActive = false);
      } else {
        await _saveSettings();
        await FlutterOverlayWindow.shareData(_scriptController.text);
        await FlutterOverlayWindow.showOverlay(
          enableDrag: true,
          overlayTitle: 'ملقن عائم',
          overlayContent: 'جاري العرض',
          flag: OverlayFlag.defaultFlag,
          visibility: NotificationVisibility.visibilityPublic,
          positionGravity: PositionGravity.auto,
          width: (360 * _frameWidthFactor).clamp(240, 600).toInt(),
          height: (420 * _frameHeightFactor).clamp(180, 700).toInt(),
        );
        setState(() => _isOverlayActive = true);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تشغيل النافذة العائمة: $e')),
      );
    }
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _noiseSubscription?.cancel();
    _scriptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: _opacity),
      appBar: AppBar(
        title: Text(_isPrompterMode ? 'وضع الملقن' : 'تحرير النص'),
        actions: [
          IconButton(
            tooltip: 'منع انطفاء الشاشة',
            icon: Icon(
              _keepScreenOn ? Icons.screen_lock_portrait : Icons.bedtime_off,
              color: _keepScreenOn ? Colors.greenAccent : Colors.grey,
            ),
            onPressed: () async {
              setState(() => _keepScreenOn = !_keepScreenOn);
              await _applyWakelock();
              await _saveSettings();
            },
          ),
          IconButton(
            tooltip: 'التحكم بالصوت',
            icon: Icon(
              _voiceControlEnabled ? Icons.mic : Icons.mic_off,
              color: _voiceControlEnabled ? Colors.amberAccent : Colors.grey,
            ),
            onPressed: _toggleVoiceControl,
          ),
          IconButton(
            tooltip: 'النافذة العائمة',
            icon: Icon(
              _isOverlayActive ? Icons.picture_in_picture_alt : Icons.picture_in_picture,
              color: _isOverlayActive ? Colors.lightBlueAccent : Colors.white,
            ),
            onPressed: _toggleFloatingWindow,
          ),
          TextButton.icon(
            onPressed: () async {
              await _saveSettings();
              if (!_isPrompterMode) {
                setState(() => _isPrompterMode = true);
              } else {
                _stopScrolling();
                setState(() => _isPrompterMode = false);
              }
            },
            icon: Icon(_isPrompterMode ? Icons.edit : Icons.play_arrow),
            label: Text(_isPrompterMode ? 'تحرير' : 'ملقن'),
          ),
        ],
      ),
      body: _isPrompterMode ? _buildPrompterView() : _buildEditorView(),
    );
  }

  Widget _buildEditorView() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: TextField(
              controller: _scriptController,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontSize: 18, height: 1.5),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'اكتب أو الصق نص التلقين هنا...',
              ),
              onChanged: (_) => _saveSettings(),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async {
                await _saveSettings();
                setState(() => _isPrompterMode = true);
              },
              icon: const Icon(Icons.slideshow),
              label: const Text('الانتقال إلى وضع الملقن'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrompterView() {
    final screenSize = MediaQuery.of(context).size;
    final boxWidth = screenSize.width * _frameWidthFactor;
    final boxHeight = screenSize.height * _frameHeightFactor;

    return Column(
      children: [
        if (_voiceControlEnabled)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('مستوى الصوت: ${_currentDb.toStringAsFixed(1)} dB'),
                Text('العتبة: ${_voiceThresholdDb.toStringAsFixed(0)} dB'),
              ],
            ),
          ),
        Expanded(
          child: Center(
            child: Container(
              width: boxWidth,
              height: boxHeight,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey.shade900.withValues(alpha: _opacity),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white24),
              ),
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Text(
                  _scriptController.text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: _fontSize,
                    height: 1.5,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
        _buildControlsPanel(),
      ],
    );
  }

  Widget _buildControlsPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.grey.shade900,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              FloatingActionButton.small(
                onPressed: _toggleScrolling,
                child: Icon(_isScrolling ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 12),
              IconButton(
                onPressed: () {
                  if (_scrollController.hasClients) {
                    _scrollController.jumpTo(0);
                  }
                },
                icon: const Icon(Icons.replay),
                tooltip: 'إعادة للبداية',
              ),
              const SizedBox(width: 8),
              const Text('السرعة'),
              Expanded(
                child: Slider(
                  min: 10,
                  max: 140,
                  value: _scrollSpeed,
                  onChanged: (v) {
                    setState(() => _scrollSpeed = v);
                    _saveSettings();
                  },
                ),
              ),
            ],
          ),
          Row(
            children: [
              const Text('الخط'),
              Expanded(
                child: Slider(
                  min: 16,
                  max: 72,
                  value: _fontSize,
                  onChanged: (v) {
                    setState(() => _fontSize = v);
                    _saveSettings();
                  },
                ),
              ),
              const Text('الشفافية'),
              Expanded(
                child: Slider(
                  min: 0.2,
                  max: 1.0,
                  value: _opacity,
                  onChanged: (v) {
                    setState(() => _opacity = v);
                    _saveSettings();
                  },
                ),
              ),
            ],
          ),
          Row(
            children: [
              const Text('عرض الإطار'),
              Expanded(
                child: Slider(
                  min: 0.4,
                  max: 1.0,
                  value: _frameWidthFactor,
                  onChanged: (v) {
                    setState(() => _frameWidthFactor = v);
                    _saveSettings();
                  },
                ),
              ),
              const Text('ارتفاع الإطار'),
              Expanded(
                child: Slider(
                  min: 0.25,
                  max: 0.9,
                  value: _frameHeightFactor,
                  onChanged: (v) {
                    setState(() => _frameHeightFactor = v);
                    _saveSettings();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class OverlayTeleprompterApp extends StatefulWidget {
  const OverlayTeleprompterApp({super.key});

  @override
  State<OverlayTeleprompterApp> createState() => _OverlayTeleprompterAppState();
}

class _OverlayTeleprompterAppState extends State<OverlayTeleprompterApp> {
  String _text = 'نافذة الملقن العائمة نشطة';

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((event) {
      if (event is String && mounted) {
        setState(() => _text = event);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.78),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            child: Text(
              _text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    );
  }
}