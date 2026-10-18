import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:tachi_books/features/library/application/reading_statistics_controller.dart';
import 'package:tachi_books/features/library/application/reading_time_recorder.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/book_daily_reading_times.dart';
import 'package:tachi_books/features/library/domain/book_reading_times.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/reading_statistics.dart';
import 'package:tachi_books/features/settings/presentation/book_reading_time_screen.dart';
import 'package:tachi_books/features/settings/presentation/reading_statistics_book_list.dart';
import 'package:tachi_books/features/settings/presentation/reading_statistics_charts.dart';

Map<String, Object> get _old => {
  BookReadingTimes.preferenceKey: BookReadingTimes({'old': 500}).encode(),
  'readSeconds:2026-10-17': 1000,
  'localSecret': 'Retain locally',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('daily codec rejects malformed dates/counts/types/size without inventing legacy attribution', () {
    expect(BookDailyReadingTimes.decode(null).days, isEmpty);
    for (final raw in [
      '[]',
      '{"2026-02-30":{"b":1}}',
      '{"2026-1-1":{"b":1}}',
      '{"2026-01-01":{"":1}}',
      '{"2026-01-01":{"b":-1}}',
      '{"2026-01-01":{"b":1.5}}',
      '{"2026-01-01":{"b":"1"}}',
      '{"2026-01-01":{"b":9007199254740992}}',
      '{"2026-01-01":[]}',
    ]) {
      expect(
        () => BookDailyReadingTimes.decode(raw),
        throwsFormatException,
        reason: raw,
      );
    }
    expect(
      () => BookDailyReadingTimes.decode(' ' * (2 * 1024 * 1024 + 1)),
      throwsFormatException,
    );
    final stats = ReadingStatistics([
      LibraryBook(id: 'old', title: 'Old'),
    ], readingTimes: BookReadingTimes({'old': 500}));
    expect(stats.readingSecondsOf(stats.books.single), 500);
    expect(stats.timeByDay('old', now: DateTime(2026, 10, 18)).totalSeconds, 0);
  });

  test('midnight fractional and sessions over a day keep all duration indexes consistent', () async {
    SharedPreferences.setMockInitialValues(_old);
    final prefs = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      MemoryLibraryRepository(),
    );
    final start = DateTime(2026, 10, 17, 23, 59, 59, 500),
        end = DateTime(2026, 10, 19, 0, 0, 2, 500);
    final parts = BookDailyReadingTimes.sessionDays(start, end);
    expect(
      parts.values.fold(0, (sum, x) => sum + x),
      end.difference(start).inSeconds,
    );
    expect(parts, {'2026-10-18': 86400, '2026-10-19': 3});
    await recordReadingTime(
      prefs,
      bookId: 'new',
      start: start,
      end: end,
      isCurrent: () => true,
    );
    final daily = BookDailyReadingTimes.decode(
      prefs.getString(BookDailyReadingTimes.preferenceKey),
    );
    expect(daily.totalOf('new'), 86403);
    expect(
      BookReadingTimes.decode(prefs.getString(BookReadingTimes.preferenceKey))
          .seconds,
      {'old': 500, 'new': 86403},
    );
    expect(daily.onDay('old', start), 0);
    expect(prefs.getInt('readSeconds:2026-10-17'), 1000);
    expect(prefs.getInt('readSeconds:2026-10-18'), 86400);
    expect(prefs.getInt('readSeconds:2026-10-19'), 3);
    expect(prefs.getString('localSecret'), 'Retain locally');
  });

  test(
    'new daily configuration roundtrips backup; old maps remain absent',
    () async {
      SharedPreferences.setMockInitialValues(_old);
      final repo = MemoryLibraryRepository();
      final prefs = await CoordinatedPreferences.open(
        await SharedPreferences.getInstance(),
        repo,
      );
      final backup = BackupService(
        repo,
        configuration: AppConfigurationStore(prefs),
      );
      final old = await backup.export();
      await recordReadingTime(
        prefs,
        bookId: 'new',
        start: DateTime(2026, 10, 18, 10),
        end: DateTime(2026, 10, 18, 10, 2),
        isCurrent: () => true,
      );
      final withDaily = await backup.export();
      expect(
        utf8.decode(withDaily),
        contains(BookDailyReadingTimes.preferenceKey),
      );
      await backup.replace(
        old,
        expectedFingerprint: backup.fingerprint(withDaily),
      );
      expect(prefs.containsKey(BookDailyReadingTimes.preferenceKey), false);
      await backup.replace(
        withDaily,
        expectedFingerprint: backup.fingerprint(await backup.export()),
      );
      expect(
        BookDailyReadingTimes.decode(
          prefs.getString(BookDailyReadingTimes.preferenceKey),
        ).onDay('new', DateTime(2026, 10, 18)),
        120,
      );
    },
  );

  for (final failed in [
    BookReadingTimes.preferenceKey,
    BookDailyReadingTimes.preferenceKey,
    'readSeconds:2026-10-18',
  ]) {
    for (final coordinated in [false, true]) {
      test(
        '${coordinated ? 'coordinated' : 'legacy'} failure at $failed rolls back all indexes',
        () async {
          final store = _Failing(_old)..failKey = 'flutter.$failed';
          SharedPreferencesStorePlatform.instance = store;
          SharedPreferences.resetStatic();
          final raw = await SharedPreferences.getInstance();
          final prefs = coordinated
              ? await CoordinatedPreferences.open(
                  raw,
                  MemoryLibraryRepository(),
                )
              : raw;
          await expectLater(
            recordReadingTime(
              prefs,
              bookId: 'new',
              start: DateTime(2026, 10, 18, 10),
              end: DateTime(2026, 10, 18, 10, 1),
              isCurrent: () => true,
            ),
            throwsStateError,
          );
          expect(
            prefs.getString(BookReadingTimes.preferenceKey),
            _old[BookReadingTimes.preferenceKey],
          );
          expect(prefs.getString(BookDailyReadingTimes.preferenceKey), isNull);
          expect(prefs.getInt('readSeconds:2026-10-18'), isNull);
          expect(prefs.getString('localSecret'), 'Retain locally');
          SharedPreferences.resetStatic();
          final reopened = await SharedPreferences.getInstance();
          expect(
            reopened.getString(BookDailyReadingTimes.preferenceKey),
            isNull,
          );
          expect(
            reopened.getString(BookReadingTimes.preferenceKey),
            _old[BookReadingTimes.preferenceKey],
          );
        },
      );
    }
  }

  test('portable batch reads latest queued values and refuses secrets or stale guard', () async {
    SharedPreferences.setMockInitialValues(_old);
    final prefs = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      MemoryLibraryRepository(),
    );
    await expectLater(
      prefs.updatePortableValuesIfCurrent(
        (current) => {'localSecret': 'Changed'},
        () => true,
      ),
      throwsFormatException,
    );
    expect(prefs.getString('localSecret'), 'Retain locally');
    final entered = Completer<void>(), release = Completer<void>();
    final held = prefs.exclusive(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final edit = prefs.setInt('readSeconds:2026-10-18', 5);
    final writing = recordReadingTime(
      prefs,
      bookId: 'new',
      start: DateTime(2026, 10, 18),
      end: DateTime(2026, 10, 18, 0, 0, 10),
      isCurrent: () => true,
    );
    release.complete();
    await held;
    await edit;
    await writing;
    expect(prefs.getInt('readSeconds:2026-10-18'), 15);
    final before = BackupConfiguration.capture(prefs).fingerprint;
    await recordReadingTime(
      prefs,
      bookId: 'new',
      start: DateTime(2026, 10, 18),
      end: DateTime(2026, 10, 18, 0, 0, 10),
      isCurrent: () => false,
    );
    expect(BackupConfiguration.capture(prefs).fingerprint, before);
  });

  test(
    'guard becoming stale inside a setter rolls the portable batch back',
    () async {
      final store = _Failing(_old);
      var current = true;
      store.onSet = () => current = false;
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final prefs = await CoordinatedPreferences.open(
        await SharedPreferences.getInstance(),
        MemoryLibraryRepository(),
      );
      await expectLater(
        recordReadingTime(
          prefs,
          bookId: 'new',
          start: DateTime(2026, 10, 18),
          end: DateTime(2026, 10, 18, 0, 1),
          isCurrent: () => current,
        ),
        throwsStateError,
      );
      expect(
        prefs.getString(BookReadingTimes.preferenceKey),
        _old[BookReadingTimes.preferenceKey],
      );
      expect(prefs.getString(BookDailyReadingTimes.preferenceKey), isNull);
      expect(prefs.getInt('readSeconds:2026-10-18'), isNull);
    },
  );

  test('checkpoint failure rolls raw values back and cold-open keeps previous indexes', () async {
    SharedPreferences.setMockInitialValues(_old);
    final folder = await Directory.systemTemp.createTemp(
      'tachi-daily-checkpoint-',
    );
    addTearDown(() => folder.delete(recursive: true));
    final repo = MemoryLibraryRepository();
    final prefs = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      repo,
      journalDirectoryPath: folder.path,
    );
    await Directory('${folder.path}/configuration.json.pending').create();
    await expectLater(
      recordReadingTime(
        prefs,
        bookId: 'new',
        start: DateTime(2026, 10, 18),
        end: DateTime(2026, 10, 18, 0, 0, 10),
        isCurrent: () => true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(prefs.getString(BookDailyReadingTimes.preferenceKey), isNull);
    expect(
      prefs.getString(BookReadingTimes.preferenceKey),
      _old[BookReadingTimes.preferenceKey],
    );
    await Directory('${folder.path}/configuration.json.pending').delete();
    SharedPreferences.resetStatic();
    final reopened = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      repo,
      journalDirectoryPath: folder.path,
    );
    expect(reopened.getString(BookDailyReadingTimes.preferenceKey), isNull);
  });

  for (final width in [320.0, 430.0]) {
    testWidgets(
      'per-book daily chart is reachable and range changes actual data at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 932);
        addTearDown(tester.view.reset);
        final now = DateTime(2026, 10, 18);
        final daily = BookDailyReadingTimes({
          '2026-10-18': {'a': 60, 'b': 999},
          '2026-10-01': {'a': 120},
          '2026-10-19': {'a': 999},
        });
        final stats = ReadingStatistics(
          [LibraryBook(id: 'a', title: 'Book A')],
          readingTimes: BookReadingTimes({'a': 500}),
          dailyReadingTimes: daily,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              readingStatisticsProvider.overrideWith((ref) async => stats),
              readingStatisticsClockProvider.overrideWithValue(() => now),
            ],
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: const ReadingStatisticsBookList(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final open = find.byKey(const ValueKey('statistics-daily-a'));
        await tester.ensureVisible(open);
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(find.byType(BookReadingTimeScreen), findsOneWidget);
        expect(
          tester.widget<ReadingTimeChart>(find.byType(ReadingTimeChart)).days,
          7,
        );
        expect(find.text('7 ngày qua'), findsOneWidget);
        expect(find.text('1 phút'), findsWidgets);
        await tester.tap(find.text('30 ngày'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<ReadingTimeChart>(find.byType(ReadingTimeChart)).days,
          30,
        );
        expect(find.text('30 ngày qua'), findsOneWidget);
        expect(find.text('3 phút'), findsWidgets);
        expect(stats.timeByDay('a', now: now).totalSeconds, 180);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

class _Failing extends InMemorySharedPreferencesStore {
  _Failing(Map<String, Object> values)
    : super.withData({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });
  String? failKey;
  void Function()? onSet;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == failKey) {
      failKey = null;
      return false;
    }
    final result = await super.setValue(type, key, value);
    final callback = onSet;
    onSet = null;
    callback?.call();
    return result;
  }
}
