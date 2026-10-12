import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/library/domain/library_update_result.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

class _Source extends SourceRepository {
  _Source(this.respond)
    : super(
        tachimangaUrl: 'http://localhost:4567',
        vbookUrl: 'http://localhost:4570',
      );

  final Future<List<CatalogueChapter>> Function(CatalogueBook) respond;
  final calls = <String>[];

  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async {
    calls.add(book.ref);
    return respond(book);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('live update progress retains skip reasons, groups failures and retries only failed IDs', () async {
    var fail = true;
    final source = _Source((book) async {
      if (book.ref == 'ref-second' && fail) throw StateError('HTTP 503');
      return _chapters(['new', 'b', 'a']);
    });
    final fixture = await _open([
      _book('first'),
      _book('second'),
      _book('local', engine: 'local'),
    ], source);
    final changes = <LibraryUpdateProgress>[];
    final result = await fixture.vm.updateBooks([
      'first',
      'second',
      'local',
      'missing',
    ], onProgress: changes.add);
    expect(changes.first.processedBooks, 0);
    expect(changes.last.processedBooks, 4);
    expect(changes.last.fraction, 1);
    expect(result.failuresBySource.keys, ['vbook:source-second']);
    expect(result.skipped.map((skip) => skip.reason), [
      'Truyện trên máy',
      'Truyện không còn trong thư viện',
    ]);
    fail = false;
    final retried = await fixture.vm.retryFailedUpdates(result);
    expect(retried.checkedBooks, 1);
    expect(retried.failures, isEmpty);
    expect(source.calls, ['ref-first', 'ref-second', 'ref-second']);
  });
  test(
    'retry result cannot mutate books after restore changed revision',
    () async {
      final source = _Source((_) async => throw StateError('HTTP 503'));
      final fixture = await _open([_book('first')], source);
      final previous = await fixture.vm.updateBooks(['first']);
      final snapshot = await fixture.repository.snapshot();
      await fixture.repository.replaceSnapshot(
        snapshot,
        expectedFingerprint: snapshot.fingerprint,
      );
      final after = (await fixture.repository.snapshot()).fingerprint;
      final retry = await fixture.vm.retryFailedUpdates(previous);
      expect(retry.failures.single.message, contains('Thư viện'));
      expect((await fixture.repository.snapshot()).fingerprint, after);
      expect(source.calls, ['ref-first']);
    },
  );
  test('scoped updates request only captured remote IDs and preserve remapped data', () async {
    final first = _book('first');
    final second = _book('second', engine: 'tachimanga');
    final local = _book('local', engine: 'local');
    final outside = _book('outside');
    final source = _Source((book) async => _chapters(['new', 'b', 'a']));
    final fixture = await _open([first, second, local, outside], source);
    final result = await fixture.vm.updateBooks([
      first.id,
      second.id,
      local.id,
      'missing',
      first.id,
    ]);
    expect(result.requestedBooks, 4);
    expect(result.checkedBooks, 2);
    expect(result.addedChapters, 2);
    expect(result.skippedBooks, 2);
    expect(result.failures, isEmpty);
    expect(source.calls, [first.sourceRef, second.sourceRef]);
    for (final original in [first, second]) {
      final saved = (await fixture.repository.find(original.id))!;
      expect(saved.chapters.map((chapter) => chapter.id), ['new', 'b', 'a']);
      expect(saved.chapters.map((chapter) => chapter.read), [
        false,
        false,
        true,
      ]);
      expect(saved.chapters.map((chapter) => chapter.downloaded), [
        false,
        true,
        true,
      ]);
      expect(saved.currentChapter, 1);
      expect(saved.progress, .5);
      expect(saved.bookmarks, ['2:0.2500', '1:0.5000']);
      expect(saved.notes, original.notes);
      expect(saved.collection, original.collection);
      expect(saved.lastRead, original.lastRead);
      expect(await fixture.repository.readChapter(original.id, 0), isNull);
      expect((await fixture.repository.readChapter(original.id, 1))!.html, 'b');
      expect((await fixture.repository.readChapter(original.id, 2))!.html, 'a');
    }
    expect((await fixture.repository.find(local.id))!.toJson(), local.toJson());
    expect(
      (await fixture.repository.find(outside.id))!.toJson(),
      outside.toJson(),
    );
    expect(
      fixture.container
          .read(libraryProvider)
          .requireValue
          .map((book) => book.toJson()),
      (await fixture.repository.list()).map((book) => book.toJson()),
    );
  });

  test(
    'edits made while chapters load survive the fresh identity-based commit',
    () async {
      final started = Completer<void>();
      final response = Completer<List<CatalogueChapter>>();
      final original = _book('first');
      final source = _Source((_) {
        started.complete();
        return response.future;
      });
      final fixture = await _open([original], source);
      final update = fixture.vm.updateBooks([original.id]);
      await started.future;
      await fixture.vm.updateProgress(original.id, 'b', .8);
      await fixture.vm.toggleBookmark(original.id, 'a', .42);
      await fixture.vm.markChapterRead(original.id, 'b', true);
      await fixture.vm.updateMetadata(
        original.id,
        notes: 'Mới chỉnh',
        collection: 'Kệ mới',
      );
      final beforeCommit = (await fixture.repository.find(original.id))!;
      response.complete(_chapters(['new', 'b', 'a']));
      final result = await update;
      expect(result.checkedBooks, 1);
      expect(result.addedChapters, 1);
      final saved = (await fixture.repository.find(original.id))!;
      expect(saved.progress, closeTo(.6, .000001));
      expect(saved.lastRead, beforeCommit.lastRead);
      expect(saved.notes, 'Mới chỉnh');
      expect(saved.collection, 'Kệ mới');
      expect(saved.bookmarks, ['2:0.2500', '1:0.5000', '2:0.4200']);
      expect(saved.chapters.map((chapter) => chapter.read), [
        false,
        true,
        true,
      ]);
      expect((await fixture.repository.readChapter(original.id, 1))!.html, 'b');
      expect((await fixture.repository.readChapter(original.id, 2))!.html, 'a');
    },
  );

  test('overlapping category pulls and updateAll share one in-flight chapter request', () async {
    final started = Completer<void>();
    final response = Completer<List<CatalogueChapter>>();
    final source = _Source((_) {
      if (!started.isCompleted) started.complete();
      return response.future;
    });
    final fixture = await _open([_book('first')], source);
    final first = fixture.vm.updateBooks(['first', 'first']);
    await started.future;
    final second = fixture.vm.updateAll();
    await Future<void>.delayed(Duration.zero);
    expect(source.calls, ['ref-first']);
    response.complete(_chapters(['new', 'b', 'a']));
    expect((await first).addedChapters, 1);
    expect(await second, 1);
    expect(source.calls, ['ref-first']);
    // Completed requests are removed from the dedup map, so a later pull checks again.
    expect((await fixture.vm.updateBooks(['first'])).addedChapters, 0);
    expect(source.calls, ['ref-first', 'ref-first']);
  });

  test(
    'partial source errors retain failed books and still update healthy books',
    () async {
      final broken = _book('broken');
      final healthy = _book('healthy');
      final empty = _book('empty');
      final local = _book('local', engine: 'local');
      final source = _Source((book) async {
        if (book.ref == broken.sourceRef) {
          throw const ApiException('Chưa kết nối nguồn truyện');
        }
        if (book.ref == empty.sourceRef) return [];
        return _chapters(['new', 'b', 'a']);
      });
      final fixture = await _open([broken, healthy, empty, local], source);
      final result = await fixture.vm.updateBooks([
        broken.id,
        healthy.id,
        empty.id,
        local.id,
      ]);
      expect(result.requestedBooks, 4);
      expect(result.checkedBooks, 1);
      expect(result.addedChapters, 1);
      expect(result.skippedBooks, 1);
      expect(result.hasErrors, isTrue);
      expect(result.failures.map((failure) => failure.bookId), [
        broken.id,
        empty.id,
      ]);
      expect(result.failures.first.message, contains('Chưa kết nối'));
      expect(result.failures.last.message, contains('mục lục trống'));
      expect(
        (await fixture.repository.find(broken.id))!.toJson(),
        broken.toJson(),
      );
      expect(
        (await fixture.repository.find(empty.id))!.toJson(),
        empty.toJson(),
      );
      expect(
        (await fixture.repository.find(healthy.id))!.chapters,
        hasLength(3),
      );
      expect((await fixture.repository.readChapter(broken.id, 1))!.html, 'b');
      await expectLater(
        fixture.vm.updateAll(),
        throwsA(
          isA<StateError>().having(
            (error) => '$error',
            'partial result',
            contains('Đã cập nhật 1 truyện'),
          ),
        ),
      );
    },
  );

  for (final restore in [false, true]) {
    test(
      'in-flight update cannot write after ${restore ? 'restoring same IDs' : 'deleting a book'}',
      () async {
        final started = Completer<void>();
        final response = Completer<List<CatalogueChapter>>();
        final first = _book('first');
        final second = _book('second');
        final source = _Source((_) {
          started.complete();
          return response.future;
        });
        final fixture = await _open([first, second], source);
        final update = fixture.vm.updateBooks([first.id, second.id]);
        await started.future;
        if (restore) {
          await fixture.repository.clear();
          await fixture.repository.save(
            first.copyWith(notes: 'Bản khôi phục mới'),
          );
          await fixture.repository.save(
            second.copyWith(notes: 'Bản khôi phục khác'),
          );
          await fixture.repository.saveChapter(
            first.id,
            1,
            ReaderContent(kind: 'novel', html: 'restored'),
          );
        } else {
          await fixture.repository.remove(first.id);
        }
        final before = (await fixture.repository.snapshot()).toJson();
        response.complete(_chapters(['new', 'b', 'a']));
        final result = await update;
        expect(result.checkedBooks, 0);
        expect(result.failures, hasLength(2));
        expect(
          result.failures.every(
            (failure) => failure.message.contains('khôi phục'),
          ),
          isTrue,
        );
        expect(source.calls, [first.sourceRef]);
        expect((await fixture.repository.snapshot()).toJson(), before);
        if (!restore) expect(await fixture.repository.find(first.id), isNull);
      },
    );
  }

  test(
    'source identity changes during a request reject its old chapter list',
    () async {
      final started = Completer<void>();
      final response = Completer<List<CatalogueChapter>>();
      final original = _book('first');
      final source = _Source((_) {
        started.complete();
        return response.future;
      });
      final fixture = await _open([original], source);
      final update = fixture.vm.updateBooks([original.id]);
      await started.future;
      final replacement = original.copyWith(sourceRef: 'new-source-reference');
      await fixture.repository.save(replacement);
      response.complete(_chapters(['new', 'b', 'a']));
      final result = await update;
      expect(result.checkedBooks, 0);
      expect(result.failures, hasLength(1));
      expect(
        (await fixture.repository.find(original.id))!.toJson(),
        replacement.toJson(),
      );
      expect((await fixture.repository.readChapter(original.id, 0))!.html, 'a');
    },
  );

  test(
    'a stale captured revision starts no requests against the new library',
    () async {
      final source = _Source((_) async => _chapters(['new']));
      final fixture = await _open([_book('first')], source);
      final revision = fixture.repository.replacementRevision;
      await fixture.repository.clear();
      await fixture.repository.save(_book('first'));
      final result = await fixture.vm.updateBooks([
        'first',
      ], expectedRevision: revision);
      expect(result.checkedBooks, 0);
      expect(result.failures, hasLength(1));
      expect(source.calls, isEmpty);
    },
  );

  for (final invalid in [
    [''],
    ['a', 'a'],
  ]) {
    test(
      'invalid chapter identities $invalid keep existing metadata and cache',
      () async {
        final original = _book('first');
        final source = _Source((_) async => _chapters(invalid));
        final fixture = await _open([original], source);
        final before = (await fixture.repository.snapshot()).toJson();
        final result = await fixture.vm.updateBooks([original.id]);
        expect(result.checkedBooks, 0);
        expect(result.failures, hasLength(1));
        expect((await fixture.repository.snapshot()).toJson(), before);
      },
    );
  }
}

LibraryBook _book(String id, {String engine = 'vbook'}) => LibraryBook(
  id: id,
  title: 'Truyện $id',
  engine: engine,
  sourceId: 'source-$id',
  sourceRef: 'ref-$id',
  notes: 'Giữ ghi chú $id',
  collection: 'Kệ $id',
  currentChapter: 1,
  progress: .75,
  lastRead: DateTime(2026, 10, 10),
  bookmarks: const ['0:0.2500', '1:0.5000'],
  chapters: const [
    BookChapter(
      id: 'a',
      title: 'Chương a',
      index: 0,
      downloaded: true,
      read: true,
    ),
    BookChapter(
      id: 'b',
      title: 'Chương b',
      index: 1,
      downloaded: true,
      read: false,
    ),
  ],
);

List<CatalogueChapter> _chapters(List<String> ids) => [
  for (var index = 0; index < ids.length; index++)
    CatalogueChapter(
      ref: ids[index],
      title: 'Chương ${ids[index]}',
      index: index,
    ),
];

Future<
  ({
    MemoryLibraryRepository repository,
    ProviderContainer container,
    LibraryViewModel vm,
  })
>
_open(List<LibraryBook> books, _Source source) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final repository = MemoryLibraryRepository();
  for (final book in books) {
    await repository.save(book);
    for (final chapter in book.chapters) {
      await repository.saveChapter(
        book.id,
        chapter.index,
        ReaderContent(kind: 'novel', html: chapter.id),
      );
    }
  }
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(preferences),
      libraryRepositoryProvider.overrideWithValue(repository),
      sourceRepositoryProvider.overrideWithValue(source),
    ],
  );
  addTearDown(() {
    container.dispose();
    source.dispose();
  });
  await container.read(libraryProvider.future);
  return (
    repository: repository,
    container: container,
    vm: container.read(libraryProvider.notifier),
  );
}
