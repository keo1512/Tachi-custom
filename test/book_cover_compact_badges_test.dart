import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/widgets/book_cover.dart';

void main() {
  testWidgets(
    'compact covers keep large unread and downloaded badges within their bounds',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 50,
                height: 75,
                child: BookCover(
                  title: 'Truyện',
                  unread: 10000,
                  downloaded: 10000,
                  showDownloadedBadge: true,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
