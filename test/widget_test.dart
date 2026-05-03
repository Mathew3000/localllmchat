// Smoke test — verifies the app widget tree can be instantiated.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_llm_chat/main.dart';

void main() {
  testWidgets('App builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const LoomChatApp());
  });
}
