import 'package:flutter_test/flutter_test.dart';

import 'package:video_call/main.dart';

void main() {
  testWidgets('join screen loads', (WidgetTester tester) async {
    await tester.pumpWidget(const VideoCallApp());
    expect(find.text('1对1 视频通话'), findsOneWidget);
    expect(find.text('加入通话'), findsOneWidget);
  });
}
