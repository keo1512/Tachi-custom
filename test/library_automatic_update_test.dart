import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/application/library_update_policy.dart';
import 'package:tachi_books/features/library/application/library_update_scheduler.dart';
import 'package:tachi_books/features/library/application/library_update_report.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/release_prediction.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

class _Source extends SourceRepository {
  _Source(this.respond) : super(tachimangaUrl: '', vbookUrl: '');
  final Future<List<CatalogueChapter>> Function(CatalogueBook) respond;
  final calls = <String>[];
  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) {
    calls.add(book.ref);
    return respond(book);
  }
}

LibraryBook _book(
  String id, {
  String category = 'Manga',
  String engine = 'tachimanga',
  int status = 1,
}) => LibraryBook(
  id: id,
  title: id,
  engine: engine,
  sourceId: '9223372036854775810',
  sourceRef: id,
  categories: [category],
  status: status,
  chapters: const [BookChapter(id: 'a', title: 'A', index: 0, read: false)],
);
Future<
  ({
    ProviderContainer container,
    MemoryLibraryRepository repository,
    SharedPreferences prefs,
  })
>
_open(
  List<LibraryBook> books,
  _Source source, {
  Map<String, Object> settings = const {},
  Map<String, bool>? conditions,
  DownloadJobExecutor? download,
}) async {
  SharedPreferences.setMockInitialValues(settings);
  final prefs = await SharedPreferences.getInstance();
  final repository = MemoryLibraryRepository();
  for (final book in books) {
    await repository.save(book);
  }
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(prefs),
      libraryRepositoryProvider.overrideWithValue(repository),
      sourceRepositoryProvider.overrideWithValue(source),
      updateDeviceConditionsProvider.overrideWithValue(() async => conditions),
      if (download != null)
        downloadJobExecutorProvider.overrideWithValue(download),
    ],
  );
  addTearDown(container.dispose);
  await container.read(libraryProvider.future);
  return (container: container, repository: repository, prefs: prefs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('prediction uses distinct known dates and rejects irregular/completed/local books', () {
    LibraryBook dated(
      List<int> days, {
      int status = 1,
      String engine = 'tachimanga',
    }) => LibraryBook(
      id: 'b',
      title: 'B',
      status: status,
      engine: engine,
      chapters: [
        for (final (index, day) in days.indexed)
          BookChapter(
            id: '$index',
            title: '$index',
            index: index,
            uploadedAt: DateTime(2026, 10, day),
          ),
      ],
    );
    final prediction = ReleasePrediction.forBook(dated([1, 1, 8, 15]));
    expect(prediction!.next, DateTime(2026, 10, 22));
    expect(prediction.intervalDays, 7);
    expect(ReleasePrediction.forBook(dated([1, 2, 40])), isNull);
    expect(ReleasePrediction.forBook(dated([1, 8, 15], status: 2)), isNull);
    expect(
      ReleasePrediction.forBook(dated([1, 8, 15], engine: 'local')),
      isNull,
    );
    expect(ReleasePrediction.forBook(dated([1, 8])), isNull);
  });
  test('policy smart exclusions and concurrent persistence keep independent choices', () async {
    final fixture = await _open([], _Source((_) async => []));
    final notifier = fixture.container.read(
      libraryUpdatePolicyProvider.notifier,
    );
    await Future.wait([
      notifier.patch({'hours': 12}),
      notifier.patch({'wifiOnly': true}),
      notifier.patch({'downloadAhead': 3}),
    ]);
    final restored = LibraryUpdatePolicy.fromJson(
      jsonDecode(fixture.prefs.getString('libraryUpdatePolicyV1')!)
          as Map<String, dynamic>,
    );
    expect(restored.hours, 12);
    expect(restored.wifiOnly, true);
    expect(restored.downloadAhead, 3);
    expect(
      restored.skipReason(_book('local', engine: 'local'), DateTime.now()),
      isNotNull,
    );
    expect(
      restored.skipReason(_book('complete', status: 2), DateTime.now()),
      isNotNull,
    );
  });
  test('interval, Wi-Fi and category rules avoid network; new chapters use common queue', () async {
    final source = _Source(
      (_) async => const [
        CatalogueChapter(ref: 'a', title: 'A', index: 0),
        CatalogueChapter(ref: 'b', title: 'B', index: 1),
      ],
    );
    final started = <String>[];
    final fixture = await _open(
      [
        _book('included'),
        _book('excluded', category: 'No'),
        _book('done', status: 2),
        _book('local', engine: 'local'),
      ],
      source,
      conditions: {'wifi': true, 'charging': true},
      download: (book, index) async {
        started.add('${book.id}:${book.chapters[index].id}');
      },
      settings: {
        'libraryUpdatePolicyV1': jsonEncode({
          'hours': 12,
          'wifiOnly': true,
          'downloadNew': true,
        }),
        'libraryCategoriesV1': jsonEncode({
          'categories': [
            {'name': 'Manga', 'update': 'include', 'download': 'include'},
            {'name': 'No', 'update': 'exclude'},
          ],
          'defaultCategories': [],
        }),
      },
    );
    final scheduler = fixture.container.read(libraryUpdateSchedulerProvider);
    final now = DateTime(2026, 10, 10, 10);
    expect(await scheduler.check(now), contains('thêm 1 chương'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(source.calls, ['included']);
    expect(started, ['included:b']);
    expect((await fixture.repository.find('excluded'))!.chapters.length, 1);
    expect(
      await scheduler.check(now.add(const Duration(hours: 1))),
      contains('Chưa đến'),
    );
    expect(source.calls.length, 1);
  });
  test('unknown or unmet device conditions do not dispatch', () async {
    final source = _Source((_) async => []);
    final fixture = await _open(
      [_book('b')],
      source,
      conditions: {'wifi': false, 'charging': true},
      settings: {
        'libraryUpdatePolicyV1': jsonEncode({'hours': 6, 'wifiOnly': true}),
      },
    );
    expect(
      await fixture.container
          .read(libraryUpdateSchedulerProvider)
          .check(DateTime.now()),
      contains('Wi-Fi'),
    );
    expect(source.calls, isEmpty);
    expect(fixture.prefs.containsKey('libraryLastAutomaticUpdate'), false);
  });
  test('overlap shares one request and restore prevents automatic queue/timestamp writes', () async {
    final response = Completer<List<CatalogueChapter>>(),
        entered = Completer<void>();
    final source = _Source((_) {
      entered.complete();
      return response.future;
    });
    final fixture = await _open(
      [_book('b')],
      source,
      settings: {
        'libraryUpdatePolicyV1': jsonEncode({'hours': 6, 'downloadNew': true}),
      },
    );
    final scheduler = fixture.container.read(libraryUpdateSchedulerProvider);
    final first = scheduler.check(DateTime.now());
    await entered.future;
    final second = scheduler.check(DateTime.now());
    await fixture.repository.clear();
    await fixture.repository.save(_book('replacement'));
    response.complete(const [
      CatalogueChapter(ref: 'new', title: 'New', index: 0),
    ]);
    await expectLater(first, throwsStateError);
    await expectLater(second, throwsStateError);
    expect(source.calls.length, 1);
    expect(fixture.prefs.containsKey('libraryLastAutomaticUpdate'), false);
    expect(fixture.container.read(downloadQueueProvider).tasks, isEmpty);
  });
  test('download ahead selects next IDs, preserves progress, and refuses stale reader', () async {
    final starts = <String>[];
    final book = _book('b').copyWith(
      chapters: const [
        BookChapter(id: 'a', title: 'A', index: 0, read: false),
        BookChapter(id: 'b', title: 'B', index: 1, read: true),
        BookChapter(id: 'c', title: 'C', index: 2, read: false),
        BookChapter(id: 'd', title: 'D', index: 3, downloaded: true),
      ],
    );
    final fixture = await _open(
      [book],
      _Source((_) async => []),
      settings: {
        'libraryUpdatePolicyV1': jsonEncode({'downloadAhead': 3}),
      },
      download: (book, index) async {
        starts.add(book.chapters[index].id);
      },
    );
    final scheduler = fixture.container.read(libraryUpdateSchedulerProvider);
    expect(await scheduler.downloadAhead(book, 'a', expectedRevision: 0), 1);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(starts, ['c']);
    expect((await fixture.repository.find('b'))!.progress, 0);
    await fixture.repository.clear();
    await fixture.repository.save(book.copyWith(title: 'Replacement'));
    await expectLater(
      scheduler.downloadAhead(book, 'a', expectedRevision: 0),
      throwsStateError,
    );
    expect((await fixture.repository.find('b'))!.title, 'Replacement');
  });
  test('expired update never commits a late response, starts the next source or records a completed cycle', () async {
    final response = Completer<List<CatalogueChapter>>(),
        entered = Completer<void>();
    final source = _Source((_) {
      entered.complete();
      return response.future;
    });
    final fixture = await _open(
      [_book('first'), _book('second')],
      source,
      settings: {
        'libraryUpdatePolicyV1': jsonEncode({'hours': 6, 'downloadNew': true}),
      },
    );
    final execution = fixture.container.read(libraryUpdateExecutionProvider);
    final work = fixture.container
        .read(libraryUpdateSchedulerProvider)
        .check(DateTime.now());
    final outcome = expectLater(work, throwsA(isA<LibraryUpdateCancelled>()));
    await entered.future;
    execution.expire();
    execution.allow(); // A resume cannot revive the interrupted run.
    response.complete(const [
      CatalogueChapter(ref: 'a', title: 'A', index: 0),
      CatalogueChapter(ref: 'new', title: 'New', index: 1),
    ]);
    await outcome;
    expect(source.calls, ['first']);
    expect((await fixture.repository.find('first'))!.chapters.length, 1);
    expect(fixture.prefs.containsKey('libraryLastAutomaticUpdate'), false);
    expect(fixture.container.read(downloadQueueProvider).tasks, isEmpty);
  });

  test('execution waits for a grant; an expired token stays cancelled after resume', () async {
    final gate = LibraryUpdateExecutionGate();
    addTearDown(gate.dispose);
    gate.hold();
    final first = gate.begin();
    var ready = false;
    final waiting = gate.wait(first).then((_) => ready = true);
    await Future<void>.delayed(Duration.zero);
    expect(ready, false);
    gate.allow();
    await waiting;
    expect(ready, true);
    gate.expire();
    gate.allow();
    await expectLater(gate.wait(first), throwsA(isA<LibraryUpdateCancelled>()));
    gate.finish(first);
    final next = gate.begin();
    await gate.wait(next);
    expect(gate.hasWork, true);
    gate.finish(next);
    expect(gate.hasWork, false);
  });
}
