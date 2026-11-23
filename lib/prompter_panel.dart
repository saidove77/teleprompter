import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'settings.dart';
import 'speech_follower.dart';
import 'theme.dart';

/// لوحة الملقن: تُستخدم في النافذة العائمة وفي شاشة الملقن داخل التطبيق.
/// - زر دائري للتشغيل/الإيقاف في حافة الشاشة (قابل للسحب) وآخر كبير في الوسط عند التوقف.
/// - الضغط على النص يشغّل/يوقف.
/// - زر الميكروفون: النص يتبع قراءتك فقط ويتوقف عند الكلام خارج النص.
/// - شفافية وسرعة وحجم خط من درج الإعدادات.
class PrompterPanel extends StatefulWidget {
  const PrompterPanel({
    super.key,
    required this.text,
    required this.settings,
    this.onClose,
    this.onResize,
    this.onSettingsChanged,
    this.compact = false,
  });

  final String text;
  final PrompterSettings settings;
  final VoidCallback? onClose;

  /// تكبير/تصغير النافذة العائمة (معامل ضرب). null = لا تظهر الأزرار.
  final void Function(double factor)? onResize;
  final void Function(PrompterSettings settings)? onSettingsChanged;

  /// وضع مضغوط للنافذة العائمة
  final bool compact;

  @override
  State<PrompterPanel> createState() => _PrompterPanelState();
}

class _PrompterPanelState extends State<PrompterPanel>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _textKey = GlobalKey();
  final _heard = ValueNotifier<String>('');
  final _matcher = ScriptMatcher();
  late final SpeechFollower _follower;

  bool _playing = false;
  bool _voice = false;
  bool _showSettings = false;
  bool _busy = false;
  String? _notice;
  Timer? _noticeTimer;
  Timer? _autoTimer;
  Timer? _saveTimer;
  Offset? _fabPos;

  PrompterSettings get _s => widget.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _matcher.setText(widget.text);
    _follower = SpeechFollower(
      matcher: _matcher,
      onResult: _onSpeech,
      onFatal: _onFatal,
    );
  }

  @override
  void didUpdateWidget(covariant PrompterPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _matcher.setText(widget.text);
      _heard.value = '';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _follower.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoTimer?.cancel();
    _noticeTimer?.cancel();
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      widget.onSettingsChanged?.call(_s);
    }
    _follower.dispose();
    _scroll.dispose();
    _heard.dispose();
    super.dispose();
  }

  // ───────── تشغيل / إيقاف ─────────
  Future<void> _play() async {
    if (_playing) return;
    setState(() => _playing = true);
    if (_voice) {
      await _follower.start();
    } else {
      _startAuto();
    }
  }

  Future<void> _pause() async {
    if (!_playing) return;
    _autoTimer?.cancel();
    if (mounted) setState(() => _playing = false);
    if (_voice) await _follower.pause();
  }

  void _togglePlay() => _playing ? _pause() : _play();

  void _startAuto() {
    _autoTimer?.cancel();
    const tick = 30;
    _autoTimer = Timer.periodic(const Duration(milliseconds: tick), (_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      final next = _scroll.offset + _s.speed * tick / 1000;
      if (next >= max) {
        _scroll.jumpTo(max);
        _pause();
      } else {
        _scroll.jumpTo(next);
      }
    });
  }

  void _replay() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _matcher.reset();
    _heard.value = '';
    setState(() {});
  }

  // ───────── الميكروفون ─────────
  Future<void> _toggleVoice() async {
    if (_busy) return;
    if (_voice) {
      await _follower.pause();
      _heard.value = '';
      if (!mounted) return;
      setState(() {
        _voice = false;
        _playing = false;
      });
      return;
    }
    setState(() => _busy = true);
    final err = await _follower.init();
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _flash(err);
      return;
    }
    _autoTimer?.cancel();
    setState(() {
      _voice = true;
      _playing = true;
    });
    await _follower.start();
  }

  void _onSpeech(MatchResult r, String heard) {
    if (!mounted) return;
    _heard.value = heard;
    switch (r.event) {
      case MatchEvent.advanced:
      case MatchEvent.backOn:
        _scrollToWord(r.pos);
        setState(() {});
        break;
      case MatchEvent.wentOff:
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.offset); // إيقاف الحركة
        setState(() {});
        break;
      case MatchEvent.finished:
        _scrollToWord(_matcher.words.length - 1);
        setState(() {});
        _pause();
        _flash('انتهى النص ✓');
        break;
      case MatchEvent.none:
        break;
    }
  }

  void _onFatal(String message) {
    if (!mounted) return;
    _flash(message);
    setState(() {
      _voice = false;
      _playing = false;
    });
  }

  void _scrollToWord(int index) {
    if (!_scroll.hasClients || _matcher.words.isEmpty) return;
    final ro = _textKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return;
    final i = index.clamp(0, _matcher.words.length - 1).toInt();
    final dy = ro
        .getOffsetForCaret(
          TextPosition(offset: _matcher.words[i].start),
          Rect.zero,
        )
        .dy;
    // الحشوة العلوية = 30% من الارتفاع، لذلك الإزاحة = dy تضع السطر عند خط القراءة
    final target = dy.clamp(0.0, _scroll.position.maxScrollExtent).toDouble();
    if ((target - _scroll.offset).abs() < 4) return;
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
  }

  void _flash(String message) {
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  void _persist() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      widget.onSettingsChanged?.call(_s);
    });
  }

  (String, Color) _status() {
    if (_notice != null) return (_notice!, AppColors.warn);
    if (_busy) return ('جارٍ تهيئة الميكروفون…', AppColors.textDim);
    if (_voice) {
      if (!_playing) return ('الميكروفون متوقف', AppColors.textDim);
      if (_matcher.offScript) {
        return ('خارج النص — التمرير متوقف', AppColors.warn);
      }
      return ('أستمع… اقرأ من النص', AppColors.accent);
    }
    if (_playing) return ('تمرير تلقائي', AppColors.accent);
    return ('متوقف', AppColors.textDim);
  }

  // ───────── الواجهة ─────────
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, outer) {
        final maxDrawer =
            outer.maxHeight.isFinite ? outer.maxHeight * 0.55 : 300.0;
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppColors.bg.withValues(alpha: _s.opacity),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Column(
            children: [
              _topBar(),
              if (_voice) _heardLine(),
              Expanded(
                child: LayoutBuilder(builder: (context, c) => _textStack(c)),
              ),
              if (_showSettings)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxDrawer),
                  child: SingleChildScrollView(child: _settingsDrawer()),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _topBar() {
    final iconSize = widget.compact ? 20.0 : 24.0;

    Widget btn(
      IconData icon,
      String tip,
      VoidCallback? onTap, {
      bool active = false,
      Widget? custom,
    }) {
      return IconButton(
        tooltip: tip,
        onPressed: onTap,
        iconSize: iconSize,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(7),
        constraints: const BoxConstraints(),
        icon: custom ??
            Icon(icon, color: active ? AppColors.accent : Colors.white70),
      );
    }

    final (text, color) = _status();

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: widget.compact ? 11 : 12.5,
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          btn(
            _voice ? Icons.mic_rounded : Icons.mic_off_rounded,
            'القراءة بالصوت',
            _toggleVoice,
            active: _voice,
            custom: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
          ),
          btn(
            Icons.tune_rounded,
            'الإعدادات',
            () => setState(() => _showSettings = !_showSettings),
            active: _showSettings,
          ),
          if (widget.onResize != null) ...[
            btn(Icons.photo_size_select_small_rounded, 'تصغير',
                () => widget.onResize!(0.85)),
            btn(Icons.photo_size_select_large_rounded, 'تكبير',
                () => widget.onResize!(1.18)),
          ],
          if (widget.onClose != null)
            btn(Icons.close_rounded, 'إغلاق', widget.onClose),
        ],
      ),
    );
  }

  Widget _heardLine() {
    return SizedBox(
      height: 18,
      child: ValueListenableBuilder<String>(
        valueListenable: _heard,
        builder: (_, h, __) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            h.isEmpty ? '' : 'سُمع: $h',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: Colors.white38),
          ),
        ),
      ),
    );
  }

  Widget _textStack(BoxConstraints c) {
    final h = c.maxHeight;
    final fab = widget.compact ? 48.0 : 56.0;
    final centerSize = widget.compact ? 68.0 : 88.0;
    final pos = _fabPos ?? Offset(c.maxWidth - fab - 10, (h - fab) / 2);
    final off = _voice && _matcher.offScript;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _togglePlay,
            child: _scrollText(h),
          ),
        ),
        // خط القراءة
        Positioned(
          top: h * 0.3 - 8,
          left: 14,
          right: 14,
          child: IgnorePointer(
            child: Container(
              height: 2,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
        // زر كبير دائري في وسط الشاشة (يظهر عند التوقف)
        Center(
          child: IgnorePointer(
            ignoring: _playing,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _playing ? 0 : 1,
              child: _circleButton(
                size: centerSize,
                icon: Icons.play_arrow_rounded,
                onTap: _togglePlay,
              ),
            ),
          ),
        ),
        // زر دائري صغير في حافة الشاشة (قابل للسحب)
        Positioned(
          left: pos.dx,
          top: pos.dy,
          child: GestureDetector(
            onPanUpdate: (d) {
              setState(() {
                _fabPos = Offset(
                  (pos.dx + d.delta.dx).clamp(0.0, c.maxWidth - fab).toDouble(),
                  (pos.dy + d.delta.dy).clamp(0.0, h - fab).toDouble(),
                );
              });
            },
            child: _circleButton(
              size: fab,
              icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              onTap: _togglePlay,
              color: off ? AppColors.warn : AppColors.accent,
            ),
          ),
        ),
      ],
    );
  }

  Widget _scrollText(double h) {
    final text = widget.text;
    final base = TextStyle(
      fontSize: _s.fontSize,
      height: 1.6,
      color: Colors.white,
      fontWeight: FontWeight.w600,
    );
    final dim = base.copyWith(color: Colors.white38);

    InlineSpan span;
    if (text.isEmpty) {
      span = TextSpan(text: 'لا يوجد نص. أضف نصاً من الشاشة الرئيسية.', style: dim);
    } else if (_voice && _matcher.pos > 0 && _matcher.pos < _matcher.words.length) {
      // الجزء الذي قُرئ يظهر باهتاً
      final split = _matcher.words[_matcher.pos].start;
      span = TextSpan(children: [
        TextSpan(text: text.substring(0, split), style: dim),
        TextSpan(text: text.substring(split), style: base),
      ]);
    } else {
      span = TextSpan(text: text, style: base);
    }

    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
        stops: [0.0, 0.06, 0.94, 1.0],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(20, h * 0.3, 20, h * 0.7),
        child: SizedBox(
          width: double.infinity,
          child: Text.rich(span, key: _textKey, textAlign: TextAlign.center),
        ),
      ),
    );
  }

  Widget _circleButton({
    required double size,
    required IconData icon,
    required VoidCallback onTap,
    Color color = AppColors.accent,
  }) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      elevation: 8,
      shadowColor: Colors.black54,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.58, color: AppColors.onAccent),
        ),
      ),
    );
  }

  Widget _settingsDrawer() {
    const small = TextStyle(fontSize: 12, color: AppColors.textDim);

    Widget row(
      IconData icon,
      String label,
      double v,
      double min,
      double max,
      String Function(double) fmt,
      void Function(double) apply, {
      bool enabled = true,
    }) {
      return Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textDim),
          const SizedBox(width: 8),
          SizedBox(width: 56, child: Text(label, style: small)),
          Expanded(
            child: Slider(
              min: min,
              max: max,
              value: v.clamp(min, max).toDouble(),
              onChanged: enabled
                  ? (x) {
                      setState(() => apply(x));
                      _persist();
                    }
                  : null,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(fmt(v), textAlign: TextAlign.end, style: small),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.92),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row(Icons.opacity_rounded, 'الشفافية', _s.opacity, 0.1, 1.0,
              (v) => '${(v * 100).round()}%', (x) => _s.opacity = x),
          row(Icons.speed_rounded, 'السرعة', _s.speed, 10, 140,
              (v) => v.round().toString(), (x) => _s.speed = x,
              enabled: !_voice),
          row(Icons.format_size_rounded, 'الخط', _s.fontSize, 16, 72,
              (v) => v.round().toString(), (x) => _s.fontSize = x),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _replay,
              icon: const Icon(Icons.replay_rounded, size: 18),
              label: const Text('من البداية'),
            ),
          ),
        ],
      ),
    );
  }
}
