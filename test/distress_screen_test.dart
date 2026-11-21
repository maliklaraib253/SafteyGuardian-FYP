import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_guardian/screens/distress_detection_screen.dart';

void main() {
  testWidgets('DistressDetectionScreen renders all initial cards and sensor rows', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'distress_detection_always_on': true});
    await tester.pumpWidget(
      const MaterialApp(
        home: DistressDetectionScreen(),
      ),
    );

    // Verify App Bar
    expect(find.text('Distress Detection'), findsOneWidget);

    // Verify Initial Status Card (defaults to Active - Monitoring)
    expect(find.text('Detection Status'), findsOneWidget);
    expect(find.text('Active - Monitoring'), findsOneWidget);

    // Verify Sensor Readings
    expect(find.text('Live Sensor Readings'), findsOneWidget);
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Motion Sensor'), findsOneWidget);
    expect(find.text('Location Services'), findsOneWidget);

    // Verify AI Distress Detection Card
    expect(find.text('AI Distress Detection'), findsOneWidget);
    expect(find.text('Shouting & Screaming'), findsOneWidget);
    expect(find.text('Threat & Aggression (Dhamki)'), findsOneWidget);
    expect(find.text('Verbal Abuse & Harassment'), findsOneWidget);
    expect(find.text('Sudden Movement & Fall'), findsOneWidget);

    // Verify Recent Detections
    expect(find.text('Recent Detections'), findsOneWidget);
  });
}
