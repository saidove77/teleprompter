import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'l10n.dart';
import 'settings.dart';
import 'speech_follower.dart';
import 'theme.dart';

enum _Voice { off, follow, level }

/// لوحة الملقن: تُستخدم في النافذة العائمة وفي شاشة الملقن داخل التطبيق.
/// - زر دائري للتشغيل/الإيقاف في حافة الشاشة (قابل للسحب) وآخر كبير في الوسط عند التوقف.
/// - الضغط على النص يشغّل/يوقف، والتمرير بالإصبع (للأعلى/للأسفل) يحرّك النص يدوياً.
/// - زر «إعادة» يرجع إلى بداية النص.
/// - الميكروفون: «تمرير بالصوت» (صامت تماماً) أو «تتبع النص» (تعرّف على الكلام).
class PrompterPanel extends StatefulWidget {
  const PrompterPanel({
    super.key,
    required this.text,
    required this.settings,
    this.onClose,
    this.onResize,
    this.onSettingsChanged,
    this.onRefresh,
    this.onMoveStart,
    this.onMove,
    this.compact = false,
  });

  final String text;
  final PrompterSettings settings;
  final VoidCallback? onClose;

  /// تكبير/تصغير النافذة العائمة (معامل ضرب). null = لا تظهر الأزرار.
  final void Function(double factor)? onResize;
  final void Function(PrompterSettings settings)? onSettingsChanged;

  /// تُستدعى عند الضغط على «إعادة من البداية» (مثلاً لإعادة جلب النص)
  final VoidCallback? onRefresh;

  /// سحب النافذة العائمة من المقبض (يظهر فقط إن وُجدت هذه الدوال)
  final VoidCallback? onMoveStart;
  final void Function(Offset delta)? onMove;

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
  final _db = ValueNotifier<double>(0);
  final _progress = ValueNotifier<double>(0);
  final _matcher = ScriptMatcher();
  late final SpeechFollower _follower;
  late final VoiceLevelDetector _level;

  _Voice _voice = _Voice.off;
  bool _playing = false;
  bool _busy = false;
  bool _speaking = false; // التمرير بالصوت: هل يتكلم المستخدم الآن
  bool _userDragging = false; // المستخدم يمرّر النص بإصبعه
  bool _showSettings = false;
  int? _counting;
  int _countToken = 0;
  String? _notice;
  Timer? _noticeTimer;
  Timer? _autoTimer;
  Timer? _saveTimer;
  Offset? _fabPos;

  PrompterSettings get _s => widget.settings;
  String get _speechLang =>
      _s.speechLang.isEmpty ? L10n.code : _s.speechLang;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _matcher.setText(widget.text);
    _scroll.addListener(_onScroll);
    _follower = SpeechFollower(
      matcher: _matcher,
      onResult: _onSpeech,
      onFatal: _onFatal,
    );
    _level = VoiceLevelDetector(
      onSpeaking: _onSpeaking,
      onSilence: _onSilence,
      onLevel: (db) => _db.value = db,
    )..threshold = _s.sensitivity;
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
    _countToken++;
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      widget.onSettingsChanged?.call(_s);
    }
    _follower.dispose();
    _level.stop();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _heard.dispose();
    _db.dispose();
    _progress.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    _progress.value =
        max <= 0 ? 0.0 : (_scroll.offset / max).clamp(0.0, 1.0).toDouble();
  }

  // ───────── تمرير النص بإصبع المستخدم ─────────
  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      // بدأ المستخدم يمرّر بإصبعه: نوقف الحركة التلقائية مؤقتاً
      _userDragging = true;
      _stopAuto();
    } else if (n is ScrollEndNotification && _userDragging) {
      _userDragging = false;
      _syncPosToScroll();
      // نستأنف الحركة التلقائية من الموضع الجديد
      if (_playing &&
          (_voice == _Voice.off || (_voice == _Voice.level && _speaking))) {
        _startAuto();
      }
    }
    return false;
  }

  /// بعد التمرير اليدوي: نحدّد الكلمة الموجودة عند خط القراءة ليتابع «تتبع النص» منها
  void _syncPosToScroll() {
    if (!_scroll.hasClients || _matcher.words.isEmpty) return;
    final ro = _textKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return;
    final off = _scroll.offset;
    var lo = 0, hi = _matcher.words.length - 1, ans = hi;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final dy = ro
          .getOffsetForCaret(
            TextPosition(offset: _matcher.words[mid].start),
            Rect.zero,
          )
          .dy;
      if (dy >= off - 2) {
        ans = mid;
        hi = mid - 1;
      } else {
        lo = mid + 1;
      }
    }
    _matcher.jumpTo(ans);
    if (mounted) setState(() {});
  }

  // ───────── تشغيل / إيقاف ─────────
  bool get _atStart =>
      (!_scroll.hasClients || _scroll.offset < 8) && _matcher.pos == 0;

  Future<void> _play({bool skipCountdown = false}) async {
    if (_playing || _counting != null) return;
    if (!skipCountdown && _s.countdown > 0 && _atStart) {
      final ok = await _runCountdown();
      if (!ok || !mounted) return;
    }
    setState(() => _playing = true);
    switch (_voice) {
      case _Voice.off:
        _startAuto();
        break;
      case _Voice.follow:
        await _follower.start();
        break;
      case _Voice.level:
        await _startLevel();
        break;
    }
  }

  Future<void> _pause() async {
    _cancelCountdown();
    if (!_playing) return;
    _stopAuto();
    if (mounted) {
      setState(() {
        _playing = false;
        _speaking = false;
      });
    }
    if (_voice == _Voice.follow) await _follower.pause();
    if (_voice == _Voice.level) await _level.stop();
  }

  void _togglePlay() {
    if (_counting != null) {
      _cancelCountdown();
      return;
    }
    _playing ? _pause() : _play();
  }

  Future<bool> _runCountdown() async {
    final token = ++_countToken;
    for (var i = _s.countdown; i > 0; i--) {
      if (!mounted || token != _countToken) return false;
      setState(() => _counting = i);
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted || token != _countToken) return false;
    setState(() => _counting = null);
    return true;
  }

  void _cancelCountdown() {
    _countToken++;
    if (_counting != null && mounted) setState(() => _counting = null);
  }

  void _startAuto() {
    if (_autoTimer?.isActive ?? false) return;
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

  void _stopAuto() {
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  /// إعادة القراءة من البداية (المقدمة) وإيقاف التشغيل حتى يضغط المستخدم تشغيل
  Future<void> _restart() async {
    await _pause();
    _userDragging = false;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _matcher.reset();
    _heard.value = '';
    _progress.value = 0;
    widget.onRefresh?.call();
    if (mounted) setState(() {});
  }

  // ───────── الميكروفون ─────────
  Future<void> _toggleVoice() async {
    if (_busy) return;
    if (_voice != _Voice.off) {
      await _stopEngines();
      if (!mounted) return;
      setState(() {
        _voice = _Voice.off;
        _playing = false;
        _speaking = false;
      });
      _heard.value = '';
      return;
    }
    await _activateVoice(_s.voiceMode);
  }

  Future<void> _stopEngines() async {
    _stopAuto();
    await _follower.pause();
    await _level.stop();
  }

  Future<void> _activateVoice(VoiceMode mode) async {
    setState(() => _busy = true);
    if (mode == VoiceMode.follow) {
      final r = await _follower.init(_speechLang);
      if (!mounted) return;
      setState(() => _busy = false);
      if (r == SpeechInit.noPermission) {
        _flash(tr('err_need_mic'));
        return;
      }
      if (r == SpeechInit.unavailable) {
        _flash('${tr('err_stt_unavailable')} — ${tr('switched_silent')}');
        _s.voiceMode = VoiceMode.level;
        _persist();
        await _activateVoice(VoiceMode.level);
        return;
      }
      setState(() => _voice = _Voice.follow);
    } else {
      setState(() {
        _busy = false;
        _voice = _Voice.level;
      });
    }
    await _play();
  }

  Future<void> _switchMode(VoiceMode mode) async {
    setState(() => _s.voiceMode = mode);
    _persist();
    if (_voice == _Voice.off) return;
    await _stopEngines();
    if (!mounted) return;
    setState(() {
      _voice = _Voice.off;
      _playing = false;
      _speaking = false;
    });
    await _activateVoice(mode);
  }

  Future<void> _startLevel() async {
    _level.threshold = _s.sensitivity;
    final r = await _level.start();
    if (!mounted) return;
    if (r != SpeechInit.ok) {
      _flash(r == SpeechInit.noPermission
          ? tr('err_need_mic')
          : tr('err_mic_failed'));
      setState(() {
        _playing = false;
        _voice = _Voice.off;
      });
    }
  }

  void _onSpeaking() {
    if (!mounted || !_playing || _voice != _Voice.level) return;
    setState(() => _speaking = true);
    if (!_userDragging) _startAuto();
  }

  void _onSilence() {
    if (!mounted) return;
    setState(() => _speaking = false);
    _stopAuto();
  }

  void _onSpeech(MatchResult r, String heard) {
    if (!mounted || _voice != _Voice.follow) return;
    _heard.value = heard;
    if (_userDragging) return; // أثناء تمرير المستخدم لا نحرّك النص
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
        _flash(tr('finished'));
        break;
      case MatchEvent.none:
        break;
    }
  }

  Future<void> _onFatal(String messageKey, bool languageIssue) async {
    if (!mounted) return;
    final msg = tr(messageKey);
    if (languageIssue) {
      // نحوّل تلقائياً إلى التمرير بالصوت (صامت) حتى يبقى الميكروفون مفيداً
      await _follower.pause();
      _s.voiceMode = VoiceMode.level;
      _persist();
      setState(() {
        _playing = false;
        _voice = _Voice.level;
      });
      _flash('$msg — ${tr('switched_silent')}');
      await _play(skipCountdown: true);
    } else {
      setState(() {
        _playing = false;
        _voice = _Voice.off;
      });
      _flash(msg);
    }
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
    if (mounted) setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  void _persist() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      widget.onSettingsChanged?.call(_s);
    });
  }

  String _remaining(double p) {
    double secs;
    if (_voice == _Voice.off && _scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      secs = (max - _scroll.offset) / (_s.speed <= 0 ? 1 : _s.speed);
    } else {
      secs = (1 - p) * _matcher.words.length / (130 / 60);
    }
    final total = secs.isFinite ? secs.round().clamp(0, 359999).toInt() : 0;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  (String, Color) _status() {
    if (_notice != null) return (_notice!, AppColors.warn);
    if (_counting != null) {
      return (tr('s_countdown', {'n': '$_counting'}), AppColors.accent);
    }
    if (_busy) return (tr('s_mic_init'), AppColors.textDim);
    if (_voice == _Voice.follow) {
      if (!_playing) return (tr('s_mic_off'), AppColors.textDim);
      if (_matcher.offScript) return (tr('s_off_script'), AppColors.warn);
      return (tr('s_listening'), AppColors.accent);
    }
    if (_voice == _Voice.level) {
      if (!_playing) return (tr('s_mic_off'), AppColors.textDim);
      return _speaking
          ? (tr('s_hearing'), AppColors.accent)
          : (tr('s_waiting'), AppColors.textDim);
    }
    return _playing
        ? (tr('s_auto'), AppColors.accent)
        : (tr('s_paused'), AppColors.textDim);
  }

  // ───────── الواجهة ─────────
  @override
  Widget build(BuildContext context) {
    return LangBuilder(
      builder: (_) => LayoutBuilder(
        builder: (context, outer) {
          final maxDrawer =
              outer.maxHeight.isFinite ? outer.maxHeight * 0.58 : 320.0;
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
                _progressRow(),
                if (_voice != _Voice.off) _voiceRow(),
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
      ),
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
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      child: Row(
        children: [
          // مقبض سحب النافذة العائمة
          if (widget.onMove != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => widget.onMoveStart?.call(),
              onPanUpdate: (d) => widget.onMove!(d.delta),
              child: Tooltip(
                message: tr('t_move'),
                child: Padding(
                  padding: const EdgeInsets.all(7),
                  child: Icon(Icons.drag_indicator_rounded,
                      size: iconSize, color: Colors.white54),
                ),
              ),
            ),
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
                        maxLines: 2,
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
          btn(Icons.refresh_rounded, tr('t_refresh'), _restart),
          btn(
            _voice != _Voice.off ? Icons.mic_rounded : Icons.mic_off_rounded,
            tr('t_mic'),
            _toggleVoice,
            active: _voice != _Voice.off,
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
            tr('settings'),
            () => setState(() => _showSettings = !_showSettings),
            active: _showSettings,
          ),
          if (widget.onClose != null)
            btn(Icons.close_rounded, tr('t_close'), widget.onClose),
        ],
      ),
    );
  }

  Widget _progressRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: ValueListenableBuilder<double>(
        valueListenable: _progress,
        builder: (_, p, __) => Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: p,
                  minHeight: 3,
                  backgroundColor: Colors.white12,
                  color: AppColors.accent,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _remaining(p),
              style: const TextStyle(fontSize: 11.5, color: AppColors.textDim),
            ),
          ],
        ),
      ),
    );
  }

  Widget _voiceRow() {
    return SizedBox(
      height: 20,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _voice == _Voice.level
            ? ValueListenableBuilder<double>(
                valueListenable: _db,
                builder: (_, db, __) {
                  final v = ((db - 30) / 60).clamp(0.0, 1.0).toDouble();
                  final on = db >= _s.sensitivity;
                  return Row(
                    children: [
                      Icon(Icons.graphic_eq_rounded,
                          size: 14,
                          color: on ? AppColors.accent : AppColors.textDim),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: v,
                            minHeight: 4,
                            backgroundColor: Colors.white12,
                            color: on ? AppColors.accent : AppColors.textDim,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              )
            : ValueListenableBuilder<String>(
                valueListenable: _heard,
                builder: (_, h, __) => Text(
                  h.isEmpty ? '' : tr('heard_prefix', {'t': h}),
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
    final off = _voice == _Voice.follow && _matcher.offScript;
    final busyOrPlaying = _playing || _counting != null;

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
        // العدّ التنازلي
        if (_counting != null)
          Center(
            child: IgnorePointer(
              child: Text(
                '$_counting',
                style: TextStyle(
                  fontSize: widget.compact ? 90 : 140,
                  fontWeight: FontWeight.w800,
                  color: AppColors.accent,
                ),
              ),
            ),
          ),
        // زر كبير دائري في وسط الشاشة (يظهر عند التوقف)
        Center(
          child: IgnorePointer(
            ignoring: busyOrPlaying,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: busyOrPlaying ? 0 : 1,
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
              icon: busyOrPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
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
    final color =
        kTextColors[_s.colorIndex.clamp(0, kTextColors.length - 1).toInt()];
    final base = TextStyle(
      fontSize: _s.fontSize,
      height: _s.lineHeight,
      color: color,
      fontWeight: FontWeight.w600,
    );
    final dim = base.copyWith(color: color.withValues(alpha: 0.38));

    InlineSpan span;
    if (text.isEmpty) {
      span = TextSpan(text: tr('no_text_placeholder'), style: dim);
    } else if (_voice == _Voice.follow &&
        _matcher.pos > 0 &&
        _matcher.pos < _matcher.words.length) {
      // الجزء الذي قُرئ يظهر باهتاً
      final split = _matcher.words[_matcher.pos].start;
      span = TextSpan(children: [
        TextSpan(text: text.substring(0, split), style: dim),
        TextSpan(text: text.substring(split), style: base),
      ]);
    } else {
      span = TextSpan(text: text, style: base);
    }

    Widget scroller = NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black,
            Colors.black,
            Colors.transparent,
          ],
          stops: [0.0, 0.06, 0.94, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: SingleChildScrollView(
          controller: _scroll,
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          padding: EdgeInsets.fromLTRB(_s.margin, h * 0.3, _s.margin, h * 0.7),
          child: SizedBox(
            width: double.infinity,
            child: Text.rich(
              span,
              key: _textKey,
              textAlign: _s.alignCenter ? TextAlign.center : TextAlign.start,
            ),
          ),
        ),
      ),
    );

    if (_s.mirror) {
      scroller = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1.0, 1.0, 1.0),
        child: scroller,
      );
    }
    return scroller;
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

    Widget head(String t) => Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text(
            t,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppColors.accent,
            ),
          ),
        );

    Widget note(String t) => Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text(t,
              style: const TextStyle(
                  fontSize: 11.5, height: 1.4, color: AppColors.textDim)),
        );

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
          SizedBox(width: 58, child: Text(label, style: small)),
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
            width: 46,
            child: Text(fmt(v), textAlign: TextAlign.end, style: small),
          ),
        ],
      );
    }

    Widget seg<T>(
      List<ButtonSegment<T>> segments,
      T selected,
      void Function(T) onSel,
    ) {
      return SizedBox(
        width: double.infinity,
        child: SegmentedButton<T>(
          segments: segments,
          selected: {selected},
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          onSelectionChanged: (set) => onSel(set.first),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          head(tr('d_voice')),
          seg<VoiceMode>(
            [
              ButtonSegment<VoiceMode>(
                  value: VoiceMode.level, label: Text(tr('d_level'))),
              ButtonSegment<VoiceMode>(
                  value: VoiceMode.follow, label: Text(tr('d_follow'))),
            ],
            _s.voiceMode,
            _switchMode,
          ),
          if (_s.voiceMode == VoiceMode.level) ...[
            row(Icons.graphic_eq_rounded, tr('d_threshold'), _s.sensitivity, 35,
                85, (v) => '${v.round()}dB', (x) {
              _s.sensitivity = x;
              _level.threshold = x;
            }),
            note(tr('d_silent_note')),
          ] else ...[
            head(tr('d_speech_lang')),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final l in kLangs)
                  ChoiceChip(
                    label: Text(l.name, style: const TextStyle(fontSize: 12)),
                    selected: _speechLang == l.code,
                    visualDensity: VisualDensity.compact,
                    selectedColor: AppColors.accent.withValues(alpha: 0.28),
                    onSelected: (_) {
                      setState(() => _s.speechLang = l.code);
                      _persist();
                      if (_voice == _Voice.follow) {
                        _switchMode(VoiceMode.follow);
                      }
                    },
                  ),
              ],
            ),
            note(tr('d_beep_note')),
          ],
          head(tr('d_reading')),
          row(Icons.speed_rounded, tr('d_speed'), _s.speed, 10, 140,
              (v) => v.round().toString(), (x) => _s.speed = x,
              enabled: _voice != _Voice.follow),
          row(Icons.format_size_rounded, tr('d_font'), _s.fontSize, 16, 72,
              (v) => v.round().toString(), (x) => _s.fontSize = x),
          row(Icons.format_line_spacing_rounded, tr('d_spacing'), _s.lineHeight,
              1.2, 2.4, (v) => v.toStringAsFixed(1), (x) => _s.lineHeight = x),
          row(Icons.format_indent_increase_rounded, tr('d_margins'), _s.margin,
              8, 60, (v) => v.round().toString(), (x) => _s.margin = x),
          row(Icons.opacity_rounded, tr('d_opacity'), _s.opacity, 0.1, 1.0,
              (v) => '${(v * 100).round()}%', (x) => _s.opacity = x),
          Row(
            children: [
              const Icon(Icons.palette_rounded,
                  size: 18, color: AppColors.textDim),
              const SizedBox(width: 8),
              SizedBox(width: 58, child: Text(tr('d_color'), style: small)),
              for (var i = 0; i < kTextColors.length; i++)
                GestureDetector(
                  onTap: () {
                    setState(() => _s.colorIndex = i);
                    _persist();
                  },
                  child: Container(
                    width: 26,
                    height: 26,
                    margin: const EdgeInsetsDirectional.only(end: 10),
                    decoration: BoxDecoration(
                      color: kTextColors[i],
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _s.colorIndex == i
                            ? AppColors.accent
                            : Colors.white24,
                        width: _s.colorIndex == i ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          seg<bool>(
            [
              ButtonSegment<bool>(value: true, label: Text(tr('d_center'))),
              ButtonSegment<bool>(
                  value: false, label: Text(tr('d_align_start'))),
            ],
            _s.alignCenter,
            (v) {
              setState(() => _s.alignCenter = v);
              _persist();
            },
          ),
          const SizedBox(height: 8),
          seg<int>(
            [
              ButtonSegment<int>(value: 0, label: Text(tr('d_no_count'))),
              ButtonSegment<int>(value: 3, label: Text(tr('d_count3'))),
              ButtonSegment<int>(value: 5, label: Text(tr('d_count5'))),
            ],
            _s.countdown,
            (v) {
              setState(() => _s.countdown = v);
              _persist();
            },
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(tr('d_mirror'), style: const TextStyle(fontSize: 14)),
            subtitle: Text(tr('d_mirror_sub'),
                style:
                    const TextStyle(fontSize: 11.5, color: AppColors.textDim)),
            value: _s.mirror,
            onChanged: (v) {
              setState(() => _s.mirror = v);
              _persist();
            },
          ),
          if (widget.onResize != null) ...[
            head(tr('d_window')),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => widget.onResize!(0.85),
                    icon: const Icon(Icons.photo_size_select_small_rounded,
                        size: 18),
                    label: Text(tr('shrink')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => widget.onResize!(1.18),
                    icon: const Icon(Icons.photo_size_select_large_rounded,
                        size: 18),
                    label: Text(tr('grow')),
                  ),
                ),
              ],
            ),
          ],
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _restart,
              icon: const Icon(Icons.replay_rounded, size: 18),
              label: Text(tr('d_restart')),
            ),
          ),
        ],
      ),
    );
  }
}