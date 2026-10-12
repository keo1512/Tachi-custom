import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/settings/presentation/backup_restore_progress_screen.dart';
import 'package:tachi_books/features/settings/presentation/help_licenses_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native notice asset keeps all declared resource hashes and full original text', () async {
    final notices = await loadNativeNotices();
    expect(notices.length, greaterThan(10));
    final packages = <String>{};
    for (final notice in notices) {
      expect(
        sha256
            .convert(
              notice['sourceBytes'] == null
                  ? utf8.encode(notice['text'] as String)
                  : base64Decode(notice['sourceBytes'] as String),
            )
            .toString(),
        notice['sha256'],
      );
      for (final resource in notice['resources'] as List) {
        packages.add(resource['package'] as String);
        expect(resource['path'], isNotEmpty);
      }
    }
    expect(
      packages,
      containsAll([
        'OpenJDK / Tachi runtime',
        'vBook runtime',
        'SwiftSoup 2.11.3',
        'Tachi runtime / extension-dependencies.jar',
      ]),
    );
  });

  for (final width in [320.0, 430.0]) {
    testWidgets('searchable feature help opens at $width with large text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const HelpLicensesScreen(),
        ),
      );
      await tester.enterText(find.byType(CupertinoSearchTextField), 'Mihon');
      await tester.pumpAndSettle();
      expect(find.text('Trao đổi Tachimanga và Mihon'), findsOneWidget);
      await tester.tap(find.text('Trao đổi Tachimanga và Mihon'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('không thay thế bản TachiBooks đầy đủ media'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'restore progress closes with real result and preserves atomic recovery',
    (tester) async {
      final from = MemoryLibraryRepository();
      await from.save(LibraryBook(id: 'book', title: 'Offline'));
      final to = MemoryLibraryRepository();
      final service = BackupService(to);
      final preview = await service.preview(await BackupService(from).export());
      int? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showBackupRestoreProgress(
                  context,
                  service,
                  preview,
                  restoreConfiguration: false,
                );
              },
              child: const Text('Restore'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(result, 1);
      expect(find.text('Khôi phục bản sao lưu'), findsNothing);
      expect((await to.find('book'))!.title, 'Offline');
      expect(await to.recoverySnapshot(), isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
}
