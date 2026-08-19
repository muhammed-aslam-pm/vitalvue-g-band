import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gband_monitor/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const GBandMonitorApp());

    // Verify that the splash screen or login screen appears
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });
}
