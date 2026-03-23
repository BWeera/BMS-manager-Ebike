import 'package:flutter_test/flutter_test.dart';

import 'package:bms_manager/main.dart';

void main() {
  testWidgets('app shows dashboard title', (WidgetTester tester) async {
    await tester.pumpWidget(const BmsManagerApp());

    expect(find.text('eBike BMS Bluetooth Reader'), findsOneWidget);
    expect(find.text('Main Metrics'), findsOneWidget);
  });
}
