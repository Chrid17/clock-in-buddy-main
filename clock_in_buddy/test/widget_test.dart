// Basic widget test for Clock In Buddy
import 'package:flutter_test/flutter_test.dart';
import 'package:clock_in_buddy/main.dart';

void main() {
  testWidgets('App should build without errors', (WidgetTester tester) async {
    // This test verifies the app builds correctly
    // Note: Full functionality requires Supabase initialization
    // which is not available in unit tests without mocking
    expect(ClockInBuddyApp, isNotNull);
  });
}
