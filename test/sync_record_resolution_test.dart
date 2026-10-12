import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/sync/data/backup_sync_local.dart';
import 'package:tachi_books/features/sync/data/sync_link_store.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';

import 'support/sync_fakes.dart';

class HistoryRemote extends FakeSyncRemote implements SyncHistoryRemote {
  final history = <String, Uint8List>{};
  @override
  void seed(Uint8List data, {String id = '22222222222222222222222222222222'}) {
    super.seed(data, id: id);
    history[id] = Uint8List.fromList(data);
  }

  @override
  Future<Uint8List?> baseline(String headId) async => history[headId];
}

Future<MemoryLibraryRepository> library() async {
  final repository = MemoryLibraryRepository();
  for (final id in ['a', 'b']) {
    await repository.save(
      LibraryBook(
        id: id,
        title: 'Truyện $id',
        chapters: const [
          BookChapter(id: 'c', title: 'Chương', index: 0, downloaded: true),
        ],
      ),
    );
    await repository.saveChapter(
      id,
      0,
      ReaderContent(kind: 'novel', html: '<p>Offline $id</p>'),
    );
  }
  return repository;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryLibraryRepository repository, other;
  late BackupService backup;
  late HistoryRemote remote;
  late SyncEngine engine;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository = await library();
    other = await library();
    backup = BackupService(repository);
    remote = HistoryRemote()..seed(await backup.export());
    engine = SyncEngine(
      uid: 'alice',
      local: BackupSyncLocal(
        backup: backup,
        links: SyncLinkStore(await SharedPreferences.getInstance()),
      ),
      remote: remote,
    );
    expect(await engine.run(enable: true), SyncOutcome.current);
  });
  Future<void> twoEdits({bool sameBook = false}) async {
    await repository.save(
      (await repository.find('a'))!.copyWith(notes: 'Ghi chú trên máy'),
    );
    final id = sameBook ? 'a' : 'b';
    await other.save((await other.find(id))!.copyWith(notes: 'Ghi chú cloud'));
    await other.saveChapter(
      id,
      0,
      ReaderContent(kind: 'novel', html: '<p>Cloud $id</p>'),
    );
    remote.seed(
      await BackupService(other).export(),
      id: '33333333333333333333333333333333',
    );
    expect(await engine.run(), SyncOutcome.conflict);
  }

  test('real backup merge retains both edited books, media and exact recovery snapshot', () async {
    await twoEdits();
    final before = await backup.export();
    expect(engine.conflict!.mergePlan!.conflicts, isEmpty);
    expect(await engine.resolveRecords({}), SyncOutcome.downloaded);
    expect((await repository.find('a'))!.notes, 'Ghi chú trên máy');
    expect((await repository.find('b'))!.notes, 'Ghi chú cloud');
    expect((await repository.readChapter('a', 0))!.html, '<p>Offline a</p>');
    expect((await repository.readChapter('b', 0))!.html, '<p>Cloud b</p>');
    expect(
      backup.fingerprint((await backup.exportRecovery())!),
      backup.fingerprint(before),
    );
    expect(
      backup.fingerprint(await backup.export()),
      backup.fingerprint(remote.bytes!),
    );
  });
  test('incomplete choice cannot publish and a chosen book keeps its matching cache', () async {
    await twoEdits(sameBook: true);
    await expectLater(engine.resolveRecords({}), throwsFormatException);
    expect(remote.publishes, 0);
    expect(
      await engine.resolveRecords({'book:a': true}),
      SyncOutcome.downloaded,
    );
    expect((await repository.find('a'))!.notes, 'Ghi chú trên máy');
    expect((await repository.readChapter('a', 0))!.html, '<p>Offline a</p>');
  });
  test(
    'stale local or remote preview does not publish or replace current data',
    () async {
      await twoEdits();
      await repository.save(
        (await repository.find('a'))!.copyWith(notes: 'Sửa sau preview'),
      );
      await expectLater(engine.resolveRecords({}), throwsA(isA<SyncFailure>()));
      expect(remote.publishes, 0);
      expect((await repository.find('a'))!.notes, 'Sửa sau preview');
      expect(engine.conflict, isNull);
      await engine.run();
      remote.seed(
        await BackupService(other).export(),
        id: '44444444444444444444444444444444',
      );
      await expectLater(engine.resolveRecords({}), throwsA(isA<SyncFailure>()));
      expect(remote.publishes, 0);
    },
  );
  test('an edit during cloud publish fails the final local CAS and remains on device', () async {
    await twoEdits();
    final beforeUpload = (await repository.find('a'))!;
    remote.beforePublish = () {
      repository.save(
        beforeUpload.copyWith(notes: 'Đọc trong lúc upload'),
      );
    };
    await expectLater(engine.resolveRecords({}), throwsA(isA<StateError>()));
    expect((await repository.find('a'))!.notes, 'Đọc trong lúc upload');
    expect(engine.local.link!.headId, '22222222222222222222222222222222');
  });
}
