import 'package:flutter_test/flutter_test.dart';
import 'package:teleprompter_app/main.dart';

void main() {
  testWidgets('App starts', (WidgetTester tester) async {
    await tester.pumpWidget(const TeleprompterApp());
    expect(find.byType(HomePage), findsOneWidget);
  });
}