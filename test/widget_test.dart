import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liquid_control/main.dart';

void main() {
  testWidgets('LiquidControlApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const LiquidControlApp());
    // App should start and show a loading indicator
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
