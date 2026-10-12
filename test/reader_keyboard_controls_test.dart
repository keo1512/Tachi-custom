import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/reader/presentation/reader_keyboard_controls.dart';

void main() {
  testWidgets(
    'external keys scroll the real viewport, clamp edges, respect loading and require Control to jump chapters',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var ready = true;
      final chapters = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderKeyboardControls(
            scroll: scroll,
            canScroll: () => ready,
            onChapter: chapters.add,
            child: ListView(
              controller: scroll,
              children: const [SizedBox(height: 5000)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(scroll.offset, 80);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      expect(scroll.offset, greaterThan(80));
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(scroll.offset, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(scroll.offset, scroll.position.maxScrollExtent);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(scroll.offset, scroll.position.maxScrollExtent);
      ready = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(scroll.offset, scroll.position.maxScrollExtent);
      ready = true;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(chapters, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(chapters, [1]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
