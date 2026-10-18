import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:tachi_books/core/source_memo.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/backup_validation.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

void main() {
  test('source context survives storage and JSON backup without changing legacy defaults', () async {
    final repository = MemoryLibraryRepository();
    final book = LibraryBook(
      id: 'b',
      title: 'Fixture',
      engine: 'tachimanga',
      sourceId: '8222087175453285202',
      sourceName: 'CuuTruyen',
      sourceRef: '123',
      sourceMemo: {
        'manga': {'id': '123'},
      },
      nativeSourceContext: true,
      chapters: [
        BookChapter(
          id: '456',
          title: 'Fixture one',
          index: 0,
          sourceMemo: sourceMemo({
            'mangaId': '123',
            'values': [1, null, true],
          }),
          sourceUrl: 'https://source.example/manga/123/456',
          nativeSourceContext: true,
        ),
      ],
    );
    await repository.save(book);
    final restored = LibraryBook.fromJson(
      jsonDecode(jsonEncode((await repository.find('b'))!.toJson()))
          as Map<String, dynamic>,
    );
    expect(restored.toJson(), book.toJson());
    expect(restored.copyWith(title: 'Changed').sourceMemo, book.sourceMemo);
    expect(
      restored.chapters.first.copyWith(read: true).sourceMemo,
      book.chapters.first.sourceMemo,
    );
    final legacy = LibraryBook.fromJson({
      'id': 'old',
      'title': 'Old',
      'chapters': [
        {'id': '/c', 'title': 'One', 'index': 0},
      ],
    });
    expect(legacy.nativeSourceContext, isFalse);
    expect(legacy.sourceMemo, isEmpty);
    expect(legacy.chapters.first.nativeSourceContext, isFalse);
    expect(legacy.chapters.first.sourceMemo, isEmpty);
    expect(legacy.toJson().containsKey('nativeSourceContext'), isFalse);
  });

  test('opaque memo values are deeply copied and bounded', () {
    final input = {
      'nested': [
        <String, dynamic>{'id': '123'},
      ],
    };
    final result = sourceMemo(input);
    (input['nested']!.first)['id'] = 'changed';
    expect((result['nested'] as List).first['id'], '123');
    expect(
      () => (result['nested'] as List).add('mutation'),
      throwsUnsupportedError,
    );
    expect(
      () => ((result['nested'] as List).first as Map)['id'] = 'mutation',
      throwsUnsupportedError,
    );
    Object nested = 'leaf';
    for (var i = 0; i < 14; i++) {
      nested = [nested];
    }
    for (final invalid in <Object>[
      {'bad': double.nan},
      {'bad': Object()},
      {1: 'bad key'},
      {'bad': 'x' * 32769},
      {'bad': List.filled(4097, true)},
      {'bad': nested},
      {'a': 'x' * 32768, 'b': 'x' * 32768},
    ]) {
      expect(() => sourceMemo(invalid), throwsFormatException);
    }
  });

  test('native Isar restart and validated snapshot restore preserve source context', () async {
    await Isar.initializeIsarCore(
      libraries: {
        Abi.current(): Platform.environment['TACHI_ISAR_TEST_LIBRARY']!,
      },
      download: false,
    );
    final directory = await Directory.systemTemp.createTemp('tachi-memo-isar-');
    LibraryRepository? repository;
    try {
      repository = await LibraryRepository.open(directoryPath: directory.path);
      final book = LibraryBook(
        id: 'fixture',
        title: 'Fixture',
        kind: 'manga',
        engine: 'tachimanga',
        sourceId: '8222087175453285202',
        sourceRef: '123',
        sourceMemo: {
          'manga': {'id': '123'},
        },
        nativeSourceContext: true,
        chapters: [
          BookChapter(
            id: '456',
            title: 'One',
            index: 0,
            sourceMemo: sourceMemo({'mangaId': '123'}),
            nativeSourceContext: true,
            sourceUrl: 'https://source.example/manga/123/456',
          ),
        ],
      );
      await repository.save(book);
      final snapshot = await repository.snapshot();
      final validated = BackupValidator(repository)
          .validateSnapshot(snapshot.encode());
      await repository.close();
      repository = null;
      repository = await LibraryRepository.open(directoryPath: directory.path);
      expect((await repository.find(book.id))!.toJson(), book.toJson());
      await repository.clear();
      await repository.replaceSnapshot(
        validated,
        expectedFingerprint: (await repository.snapshot()).fingerprint,
      );
      expect((await repository.find(book.id))!.toJson(), book.toJson());
    } finally {
      await repository?.close();
      await directory.delete(recursive: true);
    }
  }, skip: Platform.environment['TACHI_ISAR_TEST_LIBRARY'] == null);
}
