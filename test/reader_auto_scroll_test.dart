import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/reader/presentation/reader_auto_scroll.dart';

void main() {
  test('timed pages use their own viewport readiness and do not need a continuous scroll client', () {
    final scroll = ScrollController();
    var now = DateTime(2026, 10, 18), ready = true, pages = 0;
    final auto = ReaderAutoScroll(
      scroll,
      canScroll: () => true,
      pageReady: () => ready,
      clock: () => now,
      onNextPage: () => pages++,
    );
    auto.startTimed(2);
    for (var i = 0; i < 21; i++) {
      now = now.add(const Duration(milliseconds: 100));
      auto.tick();
    }
    expect(pages, 1);
    ready = false;
    for (var i = 0; i < 25; i++) {
      now = now.add(const Duration(milliseconds: 100));
      auto.tick();
    }
    expect(pages, 1);
    ready = true;
    for (var i = 0; i < 21; i++) {
      now = now.add(const Duration(milliseconds: 100));
      auto.tick();
    }
    expect(pages, 2);
    auto.dispose();
    scroll.dispose();
  });
  testWidgets(
    'continuous auto-scroll respects speed, blocked reader, bottom and paused timer',
    (tester) async {
      var now = DateTime.utc(2026, 10, 11), allowed = true;
      final scroll = ScrollController();
      final auto = ReaderAutoScroll(
        scroll,
        canScroll: () => allowed,
        clock: () => now,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: const SizedBox(height: 5000, child: Text('Content')),
            ),
          ),
        ),
      );
      auto.start(100);
      now = now.add(const Duration(milliseconds: 50));
      auto.tick();
      expect(scroll.offset, 5);
      allowed = false;
      now = now.add(const Duration(milliseconds: 50));
      auto.tick();
      expect(scroll.offset, 5);
      allowed = true;
      now = now.add(const Duration(seconds: 10));
      auto.tick();
      expect(
        scroll.offset,
        15,
        reason: 'A suspended frame must not jump ten seconds ahead.',
      );
      scroll.jumpTo(scroll.position.maxScrollExtent - 1);
      now = now.add(const Duration(milliseconds: 50));
      auto.tick();
      expect(scroll.offset, scroll.position.maxScrollExtent);
      auto.pause();
      expect(auto.running, false);
      final bottom = scroll.offset;
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, bottom);
      auto.dispose();
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
}
