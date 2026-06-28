import 'package:flutter_test/flutter_test.dart';

import 'package:taskbar_remote/main.dart';

void main() {
  testWidgets('renders remote dashboard', (WidgetTester tester) async {
    await tester.pumpWidget(const TaskbarRemoteApp());

    expect(find.text('Taskbar Remote'), findsOneWidget);
    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('RAM'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.text('Temp'), findsOneWidget);
  });
}
