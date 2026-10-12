import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_directory_platform.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/external_automatic_backup_store.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

class _Folders implements BackupDirectoryPlatform {
  _Folders(this.id);
  String id;
  final files = <String, Uint8List>{};
  final removed = <String>[];
  bool failWrite = false;
  void check(String destination) {
    if (destination != id) throw StateError('Thư mục sao lưu đã thay đổi.');
  }

  @override
  Future<BackupDirectoryLocation?> current() async =>
      BackupDirectoryLocation(id, 'iCloud');
  @override
  Future<BackupDirectoryLocation?> choose() => current();
  @override
  Future<void> forget() async {}
  @override
  Future<List<Map<String, dynamic>>> list(String destination) async {
    check(destination);
    return files.entries
        .map((item) => {'name': item.key, 'size': item.value.length})
        .toList();
  }

  @override
  Future<Uint8List> read(String destination, String name) async {
    check(destination);
    return Uint8List.fromList(files[name]!);
  }

  @override
  Future<Map<String, dynamic>> write(
    String destination,
    String name,
    Uint8List bytes,
  ) async {
    check(destination);
    if (failWrite) throw StateError('Nhà cung cấp Tệp chưa kết nối.');
    expect(files.containsKey(name), false);
    files[name] = Uint8List.fromList(bytes);
    return {'name': name, 'size': bytes.length};
  }

  @override
  Future<void> delete(String destination, String name) async {
    check(destination);
    removed.add(name);
    files.remove(name);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final id = 'a' * 64;
  late _Folders folders;
  late BackupService backup;
  late ExternalAutomaticBackupStore store;
  setUp(() async {
    final library = MemoryLibraryRepository();
    await library.save(
      LibraryBook(
        id: 'offline',
        title: 'Đọc trên máy khác',
        chapters: [
          const BookChapter(
            id: 'chapter',
            title: 'Chương 1',
            index: 0,
            downloaded: true,
          ),
        ],
      ),
    );
    await library.saveChapter(
      'offline',
      0,
      ReaderContent(kind: 'novel', html: '<p>Đủ nội dung</p>'),
    );
    backup = BackupService(library);
    folders = _Folders(id);
    store = ExternalAutomaticBackupStore(
      backup,
      folders,
      BackupDirectoryLocation(id, 'iCloud'),
    );
  });
  test('external backup restores actual offline bytes and prunes only after publish', () async {
    for (var i = 0; i < 4; i++) {
      await store.create(DateTime(2026, 10, 12, i), keep: 2);
    }
    final saved = await store.list();
    expect(saved.length, 2);
    expect(folders.removed.length, 2);
    final second = MemoryLibraryRepository();
    await BackupService(second).merge(await store.read(saved.first.name));
    expect(
      (await second.readChapter('offline', 0))!.html,
      '<p>Đủ nội dung</p>',
    );
    folders.failWrite = true;
    final originalNames = folders.files.keys.toSet();
    await expectLater(
      store.create(DateTime(2026, 10, 12, 5), keep: 1),
      throwsStateError,
    );
    expect(folders.files.keys.toSet(), originalNames);
    expect(folders.removed.length, 2);
  });
  test(
    'old destination, bad names and damaged retention inputs never delete',
    () async {
      final item = await store.create(DateTime(2026, 10, 12));
      await expectLater(store.delete('../outside.json'), throwsFormatException);
      folders.files[item.name] = Uint8List.fromList([123]);
      await expectLater(store.delete(item.name), throwsFormatException);
      expect(folders.removed, isEmpty);
      folders.id = 'b' * 64;
      await expectLater(
        store.create(DateTime(2026, 10, 12, 1)),
        throwsStateError,
      );
      expect(folders.removed, isEmpty);
    },
  );
  test(
    'native bookmark identity stays opaque and malformed results are refused',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          NativeBackupDirectoryPlatform.channel,
          null,
        ),
      );
      messenger.setMockMethodCallHandler(
        NativeBackupDirectoryPlatform.channel,
        (call) async {
          if (call.method == 'current') {
            return {'id': id, 'label': 'iCloud Drive'};
          }
          return null;
        },
      );
      final platform = NativeBackupDirectoryPlatform();
      expect((await platform.current())!.id, id);
      expect(
        () => platform.delete(id, '../outside.json'),
        throwsFormatException,
      );
      messenger.setMockMethodCallHandler(
        NativeBackupDirectoryPlatform.channel,
        (_) async => {'id': '/private/path', 'label': 'Folder'},
      );
      await expectLater(platform.current(), throwsFormatException);
    },
  );
}
