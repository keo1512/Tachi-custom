import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/data/on_device_source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

import 'support/backup_fixtures.dart';

const _imageUrl = 'https://images.example/restored-page.png';
const _image =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6bWQAAAAASUVORK5CYII=';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'restored-native-reader-',
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<(MemoryLibraryRepository, LibraryBook)> restored() async {
    final repository = MemoryLibraryRepository();
    await BackupService(repository).merge(tmbFixture());
    return (repository, (await repository.list()).single);
  }

  ProviderContainer containerFor(
    MemoryLibraryRepository repository,
    FutureOr<Object?> Function(String, Map<String, dynamic>) handler,
  ) {
    final native = NativeTachiRepository(
      storageDirectory: directory,
      executor: (raw) async {
        final request = jsonDecode(raw) as Map<String, dynamic>;
        final method = request['method'] as String;
        final args = request['args'] as Map<String, dynamic>;
        return jsonEncode({
          'ok': true,
          'result': method == 'initialize' ? {} : await handler(method, args),
        });
      },
    );
    final source = OnDeviceSourceRepository(
      tachimangaUrl: '',
      vbookUrl: '',
      runtimes: {SourceEngine.tachimanga: native},
    );
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        sourceRepositoryProvider.overrideWithValue(source),
      ],
    );
    addTearDown(() {
      container.dispose();
      source.dispose();
    });
    return container;
  }

  test('restored TMB reads and downloads its saved source URLs without catalogue warm-up or migration', () async {
    final (repository, book) = await restored();
    final calls = <String>[];
    final container = containerFor(repository, (method, args) {
      calls.add(method);
      expect(args['sourceId'], fixtureSource);
      expect(args['sourceId'], isA<String>());
      expect(args['ref'], method == 'chapter' ? '/c2' : '/title');
      if (method == 'chapter') {
        expect(args['bookRef'], '/title');
        expect(args['title'], book.chapters[1].title);
        return {
          'images': [_imageUrl],
          'imageHeaders': {},
        };
      }
      expect(method, 'image');
      expect(args['chapterRef'], '/c2');
      expect(args['index'], 0);
      expect(args['url'], _imageUrl);
      return {'base64': _image, 'mimeType': 'image/png'};
    });
    await container.read(libraryProvider.future);
    final viewModel = container.read(libraryProvider.notifier);
    final before = await repository.snapshot();
    expect((await viewModel.getContent(book, 1)).images, [_imageUrl]);
    expect(calls, ['chapter']);
    expect((await repository.snapshot()).fingerprint, before.fingerprint);

    final downloaded = await viewModel.getContent(book, 1, download: true);
    expect(downloaded.images, ['data:image/png;base64,$_image']);
    expect(calls, ['chapter', 'chapter', 'image']);
    final latest = (await repository.find(book.id))!;
    expect(latest.sourceId, book.sourceId);
    expect(latest.sourceRef, book.sourceRef);
    expect(latest.chapters.map((chapter) => chapter.id), ['/c1', '/c2', '/c3']);
    expect(latest.chapters.map((chapter) => chapter.read), [true, false, true]);
    expect(latest.chapters.map((chapter) => chapter.downloaded), [
      false,
      true,
      false,
    ]);
    expect(latest.currentChapter, book.currentChapter);
    expect(latest.progress, book.progress);
    expect(latest.bookmarks, book.bookmarks);
    expect(
      latest.externalBackupMetadata?.toJson(),
      book.externalBackupMetadata?.toJson(),
    );
    expect((await viewModel.getContent(latest, 1)).images, downloaded.images);
    expect(calls, ['chapter', 'chapter', 'image']);
  });

  test('a restored-library replacement rejects late native content before download or cache writes', () async {
    final (repository, book) = await restored();
    final started = Completer<void>();
    final response = Completer<Object?>();
    final container = containerFor(repository, (method, args) {
      expect(method, 'chapter');
      expect(args['sourceId'], fixtureSource);
      expect(args['bookRef'], '/title');
      expect(args['ref'], '/c2');
      started.complete();
      return response.future;
    });
    await container.read(libraryProvider.future);
    final oldRevision = repository.replacementRevision;
    final pending = container
        .read(libraryProvider.notifier)
        .getContent(book, 1, download: true, expectedRevision: oldRevision);
    final rejected = expectLater(pending, throwsStateError);
    await started.future;
    final image = await repository.snapshot();
    await repository.replaceSnapshot(
      image,
      expectedFingerprint: image.fingerprint,
    );
    final afterRestore = await repository.snapshot();
    response.complete({
      'images': [_imageUrl],
      'imageHeaders': {},
    });
    await rejected;
    expect(repository.replacementRevision, isNot(oldRevision));
    expect((await repository.snapshot()).fingerprint, afterRestore.fingerprint);
    expect(await repository.readChapter(book.id, 1), isNull);
  });
}
