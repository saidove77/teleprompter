import 'package:flutter_test/flutter_test.dart';
import 'package:teleprompter_app/speech_follower.dart';

void main() {
  test('المطابقة: يتبع النص، يتوقف خارج النص، ثم يستأنف', () {
    final m = ScriptMatcher()
      ..setText('بسم الله الرحمن الرحيم هذا نص تجريبي للقراءة');

    // قراءة من النص: يتقدم
    var r = m.feed('بسم الله الرحمن');
    expect(r.event, MatchEvent.advanced);
    expect(r.pos, 3);

    // كلام خارج النص: يتوقف بعد محاولتين
    r = m.feed('كلام غريب تماما خارج');
    expect(r.event, MatchEvent.none);
    r = m.feed('كلام غريب تماما خارج');
    expect(r.event, MatchEvent.wentOff);
    expect(m.offScript, isTrue);

    // العودة إلى النص: يستأنف
    r = m.feed('هذا نص تجريبي');
    expect(r.event, MatchEvent.backOn);
    expect(m.offScript, isFalse);

    // نهاية النص
    r = m.feed('للقراءة');
    expect(r.event, MatchEvent.finished);
  });
}