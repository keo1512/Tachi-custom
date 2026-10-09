import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:isar_community/isar.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';

LibraryBook _book() => LibraryBook(
  id: 'same-id',
  title: 'Original',
  engine: 'vbook',
  sourceId: 'fixture',
  sourceRef: 'title',
  chapters: const [
    BookChapter(id: 'c1', title: 'One', index: 0),
    BookChapter(id: 'c2', title: 'Two', index: 1),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final operation in ['replace', 'remove']) {
    test(
      'pending network content cannot overwrite or resurrect a book after $operation',
      () async {
        final repo = MemoryLibraryRepository();
        await repo.save(_book());
        final started = Completer<void>(), release = Completer<void>();
        final container = _container(
          repo,
          MockClient((request) async {
            started.complete();
            await release.future;
            return _content();
          }),
        );
        addTearDown(container.dispose);
        await container.read(libraryProvider.future);
        final pending = container
            .read(libraryProvider.notifier)
            .getContent(_book(), 0, download: true);
        final rejected = expectLater(pending, throwsStateError);
        await started.future;
        if (operation == 'remove') {
          await repo.remove(_book().id);
        } else {
          final incoming = MemoryLibraryRepository();
          await incoming.save(
            _book().copyWith(
              title: 'Restored',
              notes: 'Keep restored notes',
              progress: .25,
            ),
          );
          await BackupService(repo).replace(
            await BackupService(incoming).export(),
            expectedFingerprint: (await repo.snapshot()).fingerprint,
          );
        }
        final stable = (await repo.snapshot()).encode();
        release.complete();
        await rejected;
        expect((await repo.snapshot()).encode(), stable);
        expect(await repo.readChapter(_book().id, 0), isNull);
      },
    );
  }

  test('two same-book chapter requests reach HTTP concurrently and preserve edits on commit', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(_book());
    final both = Completer<void>(), release = Completer<void>();
    final refs = <String>[];
    final container = _container(
      repo,
      MockClient((request) async {
        expect(request.url.path, '/v1/sources/fixture/chapter');
        refs.add(request.url.queryParameters['ref']!);
        if (refs.length == 2) both.complete();
        await release.future;
        return _content();
      }),
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    final vm = container.read(libraryProvider.notifier);
    final first = vm.getContent(_book(), 0, download: true);
    final second = vm.getContent(_book(), 1, download: true);
    await both.future.timeout(const Duration(seconds: 3));
    await vm.updateMetadata(
      _book().id,
      notes: 'Edited while fetching',
      collection: 'New shelf',
    );
    await vm.updateProgress(_book().id, 'c2', .4);
    release.complete();
    await Future.wait([first, second]);
    final saved = (await repo.find(_book().id))!;
    expect(refs.toSet(), {'c1', 'c2'});
    expect(saved.chapters.every((chapter) => chapter.downloaded), isTrue);
    expect(saved.notes, 'Edited while fetching');
    expect(saved.collection, 'New shelf');
    expect(saved.progress, .7);
    expect(await repo.readChapter(_book().id, 0), isNotNull);
    expect(await repo.readChapter(_book().id, 1), isNotNull);
  });

  test('invalid empty and wrong-kind chapter content never commits', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(_book());
    final read = (await repo.openChapter(_book().id, 'c1'))!;
    for (final content in [
      ReaderContent(kind: 'novel', html: '<script>hidden()</script>'),
      ReaderContent(kind: 'manga', images: ['data:image/png;base64,YQ==']),
    ]) {
      await expectLater(
        repo.commitChapter(read, content, downloaded: true),
        throwsStateError,
      );
      expect(await repo.readChapter(_book().id, 0), isNull);
      expect((await repo.find(_book().id))!.chapters.first.downloaded, isFalse);
    }
  });

  final library = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
  test('native handles share restore revision and stale staged bytes do not touch attachments', () async {
    await Isar.initializeIsarCore(
      libraries: {Abi.current(): library!},
      download: false,
    );
    final directory = await Directory.systemTemp.createTemp(
      'tachi-race-native-',
    );
    final repo = await LibraryRepository.open(directoryPath: directory.path);
    final other = await LibraryRepository.open(directoryPath: directory.path);
    try {
      await repo.save(_book());
      final old = (await repo.openChapter(_book().id, 'c1'))!;
      final incoming = MemoryLibraryRepository();
      await incoming.save(
        _book().copyWith(title: 'Restored', notes: 'Preserve'),
      );
      await BackupService(other).replace(
        await BackupService(incoming).export(),
        expectedFingerprint: (await other.snapshot()).fingerprint,
      );
      final before = (await repo.snapshot()).encode();
      await expectLater(
        repo.commitChapter(
          old,
          ReaderContent(
            kind: 'novel',
            html: '<p>stale</p><img src="data:image/png;base64,YQ==">',
          ),
          downloaded: true,
        ),
        throwsStateError,
      );
      expect((await repo.snapshot()).encode(), before);
      final attachments = Directory('${directory.path}/attachments');
      expect(
        await attachments
            .list(recursive: true)
            .where((entry) => entry is File)
            .toList(),
        isEmpty,
      );
      expect(await repo.readChapter(_book().id, 0), isNull);
    } finally {
      // Both repository handles share the same native Isar instance.
      await repo.close();
      await directory.delete(recursive: true);
    }
  }, skip: library == null ? 'Opt-in official Windows Isar library.' : false);
}

http.Response _content() => http.Response(
  jsonEncode({'kind': 'novel', 'html': '<p>Fetched bytes</p>'}),
  200,
  headers: {'content-type': 'application/json'},
);
ProviderContainer _container(LibraryRepository repo, http.Client client) =>
    ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        sourceRepositoryProvider.overrideWithValue(
          SourceRepository(
            tachimangaUrl: '',
            vbookUrl: 'http://localhost:4570',
            client: client,
          ),
        ),
      ],
    );
