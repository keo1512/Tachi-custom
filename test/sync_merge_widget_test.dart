import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sync/application/sync_controller.dart';
import 'package:tachi_books/features/sync/data/google_session.dart';
import 'package:tachi_books/features/sync/presentation/sync_merge_screen.dart';

import 'support/sync_fakes.dart';

class LibrarySyncLocal extends FakeSyncLocal {
  LibrarySyncLocal(Uint8List bytes) : super(bytes: bytes);
  @override
  void validate(Uint8List bytes) =>
      BackupService(MemoryLibraryRepository()).validate(bytes);
}

void main() {
  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'record choices wrap and apply only after confirmation at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final library = MemoryLibraryRepository();
        final title = 'Tên truyện dài để kiểm tra lựa chọn từng bản và bố cục';
        await library.save(
          LibraryBook(id: 'a', title: title, notes: 'Trên máy'),
        );
        final local = LibrarySyncLocal(await BackupService(library).export());
        await library.save(
          LibraryBook(id: 'a', title: title, notes: 'Trên cloud'),
        );
        final remote = FakeSyncRemote()
          ..seed(await BackupService(library).export());
        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(library),
            syncAuthProvider.overrideWithValue(
              FakeSyncAuth()..user = const SyncUser(uid: 'alice'),
            ),
            syncLocalProvider.overrideWithValue(local),
            syncRemoteFactoryProvider.overrideWithValue((_) => remote),
          ],
        );
        addTearDown(container.dispose);
        await container.read(syncProvider.notifier).resume();
        await container.read(syncProvider.notifier).sync(enable: true);
        final conflict = container.read(syncProvider.notifier).pendingConflict!;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.5)),
                child: child!,
              ),
              home: SyncMergeScreen(conflict: conflict),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Giữ trên cloud'), 120);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Giữ trên cloud'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Hợp nhất và đồng bộ'), 120);
      await tester.pumpAndSettle();
        await tester.tap(find.text('Hợp nhất và đồng bộ'));
        await tester.pumpAndSettle();
        expect(remote.publishes, 0);
        await tester.tap(find.text('Hủy'));
        await tester.pumpAndSettle();
        expect(local.replaces, 0);
        await tester.tap(find.text('Hợp nhất và đồng bộ'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hợp nhất'));
        await tester.pumpAndSettle();
        expect(remote.publishes, 1);
        expect(local.replaces, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
