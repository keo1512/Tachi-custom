import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/deep_links/domain/app_deep_link.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/tasks/application/task_notifications.dart';
import 'package:tachi_books/features/tasks/data/task_platform.dart';

import 'support/unlocked_app_lock.dart';

class _Notices implements TaskPlatform, LibraryUpdateNotificationPlatform {
  final books = <(String, int)>[];
  final completions = <(int, int, int)>[];
  final cancellations = <String>[];
  Completer<void>? pending;
  int cleared = 0;
  @override
  Stream<void> get backgroundExpired => const Stream.empty();
  @override
  Future<bool> beginBackground() async => true;
  @override
  Future<void> endBackground() async {}
  @override
  Future<bool> requestNotificationPermission() async => true;
  @override
  Future<bool> notify(String kind, int completed, int failed) async => true;
  @override
  Future<void> clearNotifications() async {
    cleared++;
  }

  @override
  void dispose() {}
  @override
  Future<bool> notifyBookUpdate(String bookId, int addedChapters) async {
    books.add((bookId, addedChapters));
    await pending?.future;
    return true;
  }

  @override
  Future<void> cancelBookUpdate(String bookId) async =>
      cancellations.add(bookId);
  @override
  Future<bool> notifyUpdateCompletion(
    int checked,
    int added,
    int failed,
  ) async {
    completions.add((checked, added, failed));
    return true;
  }
}

class _Source extends SourceRepository {
  _Source() : super(tachimangaUrl: '', vbookUrl: '');
  List<CatalogueChapter> rows = const [];
  bool fail = false;
  Completer<void>? pending;
  int calls = 0;
  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async {
    calls++;
    await pending?.future;
    if (fail) throw StateError('HTTP 503');
    return rows;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<(ProviderContainer, MemoryLibraryRepository, _Notices, _Source)>
  fixture() async {
    SharedPreferences.setMockInitialValues({
      TaskNotifications.preferenceKey: true,
    });
    final prefs = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    await repo.save(
      LibraryBook(
        id: 'id/Việt%..',
        title: 'Tên riêng không gửi',
        engine: 'tachimanga',
        sourceId: '64',
        sourceRef: '/private-source',
        chapters: const [BookChapter(id: 'old', title: 'Cũ', index: 0)],
      ),
    );
    final notices = _Notices();
    final source = _Source()
      ..rows = const [
        CatalogueChapter(ref: 'new', title: 'Mới', index: 0),
        CatalogueChapter(ref: 'old', title: 'Cũ', index: 1),
      ];
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        taskPlatformProvider.overrideWithValue(notices),
        appLockProvider.overrideWith(UnlockedAppLock.new),
        sourceRepositoryProvider.overrideWithValue(source),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    return (container, repo, notices, source);
  }

  test('new chapter notifies exact book once, repeated check with zero new still reports completion; errors report separately', () async {
    final (container, _, notices, source) = await fixture();
    final vm = container.read(libraryProvider.notifier);
    await vm.updateBooks(['id/Việt%..']);
    expect(notices.books, [('id/Việt%..', 1)]);
    expect(notices.completions, [(1, 1, 0)]);
    await vm.updateBooks(['id/Việt%..']);
    expect(notices.books.length, 1);
    expect(notices.completions.last, (1, 0, 0));
    source.fail = true;
    await vm.updateBooks(['id/Việt%..']);
    expect(notices.completions.last, (0, 0, 1));
  });
  test(
    'concurrent scopes share fetch/commit and only one per-book notice',
    () async {
      final (container, _, notices, source) = await fixture();
      source.pending = Completer<void>();
      final vm = container.read(libraryProvider.notifier);
      final first = vm.updateBooks(['id/Việt%..']);
      final second = vm.updateBooks(['id/Việt%..']);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      source.pending!.complete();
      await Future.wait([first, second]);
      expect(source.calls, 1);
      expect(notices.books, [('id/Việt%..', 1)]);
    },
  );
  test('incognito or restore invalidates notices without retrying committed source data', () async {
    final (container, repo, notices, source) = await fixture();
    source.pending = Completer<void>();
    final work = container.read(libraryProvider.notifier).updateBooks([
      'id/Việt%..',
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await container.read(settingsProvider.notifier).update(incognitoMode: true);
    source.pending!.complete();
    await work;
    expect(notices.books, isEmpty);
    expect(notices.completions, isEmpty);
    expect((await repo.find('id/Việt%..'))!.chapters.length, 2);
    await container
        .read(settingsProvider.notifier)
        .update(incognitoMode: false);
    source.pending = Completer<void>();
    final stale = container.read(libraryProvider.notifier).updateBooks([
      'id/Việt%..',
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final snapshot = await repo.snapshot();
    await repo.replaceSnapshot(
      snapshot,
      expectedFingerprint: snapshot.fingerprint,
    );
    source.pending!.complete();
    await stale;
    expect(notices.completions, isEmpty);
  });
  test('privacy changed while platform notification is pending cancels that book notice', () async {
    final (container, _, notices, _) = await fixture();
    notices.pending = Completer<void>();
    final work = container.read(libraryProvider.notifier).updateBooks([
      'id/Việt%..',
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await container.read(settingsProvider.notifier).update(incognitoMode: true);
    notices.pending!.complete();
    await work;
    expect(notices.cancellations, ['id/Việt%..']);
    expect(notices.completions, isEmpty);
  });
  test('native contract carries bounded opaque ID/count only and zero-new completion', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('dev.tachibooks/tasks');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final platform = NativeTaskPlatform();
    addTearDown(platform.dispose);
    expect(await platform.notifyBookUpdate('id/Việt%..', 2), true);
    expect(calls.single.arguments, {'bookId': 'id/Việt%..', 'added': 2});
    expect(await platform.notifyUpdateCompletion(3, 0, 0), true);
    expect(calls.last.arguments, {'checked': 3, 'added': 0, 'failed': 0});
    await expectLater(
      platform.notifyBookUpdate('bad\nID', 1),
      throwsArgumentError,
    );
    await expectLater(platform.notifyBookUpdate('b', 0), throwsArgumentError);
    await expectLater(
      platform.notifyUpdateCompletion(-1, 0, 0),
      throwsArgumentError,
    );
    expect(
      calls.any((c) => c.method == 'requestNotificationPermission'),
      false,
    );
  });
  test('notification links preserve opaque ID and cannot inject reader or repository query', () {
    for (final id in ['id/Việt%..', '.', '..', 'https://source.test/path']) {
      final value = LibraryDeepLink(id, notification: true).identity;
      final parsed = AppDeepLink.parse(value) as LibraryDeepLink;
      expect(parsed.bookId, id);
      expect(parsed.notification, true);
      expect(parsed.reader, false);
    }
    expect(
      () => AppDeepLink.parse('tachibooks://notification-book/b?chapterId=c'),
      throwsFormatException,
    );
  });
}
