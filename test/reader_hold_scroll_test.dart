import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/reader/presentation/reader_auto_scroll.dart';
import 'package:tachi_books/features/reader/presentation/reader_hold_scroll.dart';

void main() {
  testWidgets(
    'hold scroll moves viewport, speed changes in steps, release stops',
    (tester) async {
      final scroll = ScrollController();
      var now = DateTime.utc(2026, 10, 11);
      final auto = ReaderAutoScroll(
        scroll,
        canScroll: () => true,
        clock: () => now,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderHoldScroll(
              enabled: true,
              speed: 40,
              onSpeed: auto.start,
              onStop: auto.pause,
              child: SingleChildScrollView(
                controller: scroll,
                child: const SizedBox(
                  width: double.infinity,
                  height: 5000,
                  child: ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(const Offset(150, 280));
      await tester.pump(const Duration(milliseconds: 600));
      expect(auto.running, true);
      now = now.add(const Duration(milliseconds: 100));
      auto.tick();
      expect(scroll.offset, 4);
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(auto.speed, 60);
      now = now.add(const Duration(milliseconds: 100));
      auto.tick();
      expect(scroll.offset, 10);
      await gesture.moveBy(const Offset(0, 160));
      await tester.pump();
      expect(auto.speed, 20);
      await gesture.up();
      await tester.pump();
      expect(auto.running, false);
      final stopped = scroll.offset;
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, stopped);
      await tester.pumpWidget(const SizedBox());
      auto.dispose();
      scroll.dispose();
    },
  );

  testWidgets(
    'timed scroll does not skip pages after blocked or suspended frames',
    (tester) async {
      final scroll = ScrollController();
      var now = DateTime.utc(2026), allowed = true, pages = 0;
      final auto = ReaderAutoScroll(
        scroll,
        canScroll: () => allowed,
        clock: () => now,
        onNextPage: () {
          pages++;
          scroll.jumpTo(scroll.offset + 100);
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SingleChildScrollView(
            controller: scroll,
            child: const SizedBox(height: 5000),
          ),
        ),
      );
      auto.startTimed(2);
      void tick(int count) {
        for (var i = 0; i < count; i++) {
          now = now.add(const Duration(milliseconds: 100));
          auto.tick();
        }
      }

      tick(20);
      expect(pages, 1);
      expect(scroll.offset, 100);
      tick(10);
      allowed = false;
      tick(40);
      expect(pages, 1);
      allowed = true;
      tick(10);
      expect(pages, 1, reason: 'Blocked time must not advance the timer.');
      now = now.add(const Duration(minutes: 2));
      auto.tick();
      expect(pages, 1, reason: 'Resuming must not jump many pages.');
      tick(10);
      expect(pages, 2);
      auto.pause();
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
}
