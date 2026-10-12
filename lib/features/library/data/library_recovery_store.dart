import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:isar_community/isar.dart';

import 'backup_validation.dart';
import 'library_repository.dart';
import 'library_snapshot.dart';

class LibraryRecoverySelection {
  const LibraryRecoverySelection(this.directoryPath, this.token);
  final String directoryPath, token;
}

class LibraryRecoveryResult {
  const LibraryRecoveryResult({
    required this.selection,
    required this.snapshot,
    required this.preservedDirectoryPath,
    required this.originalBackupPath,
    required this.copiedFiles,
    required this.copiedBytes,
  });
  final LibraryRecoverySelection selection;
  final LibrarySnapshot snapshot;
  final String preservedDirectoryPath, originalBackupPath;
  final int copiedFiles, copiedBytes;
}

/// Recovery creates a separate verified database. Immutable location records
/// select it only after the original files and input backup have been preserved.
/// A bad newest record fails closed; it must never create an empty library.
class LibraryRecoveryStore {
  LibraryRecoveryStore(
    this.root, {
    Future<LibraryRepository> Function(String)? openRepository,
    this.beforePublish,
  }) : _open =
           openRepository ??
           ((path) => LibraryRepository.open(directoryPath: path));
  final Directory root;
  final Future<LibraryRepository> Function(String) _open;
  final Future<void> Function()? beforePublish;
  static final _pending = <String, Future<void>>{};
  static const maxPreservedBytes = 2 * 1024 * 1024 * 1024;
  static const maxPreservedFiles = 100000;
  static final _recordName = RegExp(r'^active-([0-9]{20}-[0-9a-f]{16})\.json$');
  static final _relativeLibrary = RegExp(
    r'^\.library-recovery/[0-9]{20}-[0-9a-f]{16}/library$',
  );
  Directory get _records => Directory('${root.path}/.library-locations');

  Future<void> _regularDirectory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw const FormatException('Vị trí thư viện không an toàn hoặc bị lỗi.');
    }
  }

  Future<LibraryRecoverySelection> selection({bool forRecovery = false}) async {
    await _regularDirectory(root);
    await _regularDirectory(_records);
    if (!await _records.exists()) {
      return LibraryRecoverySelection(root.absolute.path, 'default');
    }
    final records = await _records
        .list(followLinks: false)
        .where((entry) => _recordName.hasMatch(entry.uri.pathSegments.last))
        .toList();
    if (records.isEmpty) {
      return LibraryRecoverySelection(root.absolute.path, 'default');
    }
    records.sort((a, b) => b.path.compareTo(a.path));
    final file = File(records.first.path);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > 8192) {
      throw const FormatException(
        'Hồ sơ vị trí thư viện bị lỗi. Dữ liệu cũ được giữ.',
      );
    }
    final bytes = await file.readAsBytes();
    Object? value;
    try {
      value = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      if (forRecovery) {
        return LibraryRecoverySelection(
          root.absolute.path,
          'damaged:${sha256.convert(bytes)}',
        );
      }
      rethrow;
    }
    if (value is! Map<String, dynamic> ||
        value['schema'] != 'tachi-books-library-location' ||
        value['version'] != 1 ||
        value['directory'] is! String ||
        !_relativeLibrary.hasMatch(value['directory'] as String)) {
      if (forRecovery) {
        return LibraryRecoverySelection(
          root.absolute.path,
          'damaged:${sha256.convert(bytes)}',
        );
      }
      throw const FormatException('Hồ sơ vị trí thư viện không hợp lệ.');
    }
    final relative = value['directory'] as String;
    final segments = relative.split('/');
    var directory = root.absolute;
    for (final segment in segments) {
      directory = Directory('${directory.path}/$segment');
      await _regularDirectory(directory);
      if (!await directory.exists() && !forRecovery) {
        throw const FormatException(
          'Không tìm thấy thư viện phục hồi. Dữ liệu cũ được giữ.',
        );
      }
    }
    if (!forRecovery &&
        await FileSystemEntity.type(
              '${directory.path}/tachi_books.isar',
              followLinks: false,
            ) !=
            FileSystemEntityType.file) {
      throw const FormatException(
        'Không tìm thấy cơ sở dữ liệu phục hồi. Dữ liệu cũ được giữ.',
      );
    }
    // Resolve only directory components validated above, never caller paths.
    return LibraryRecoverySelection(
      directory.absolute.path,
      sha256.convert(bytes).toString(),
    );
  }

  Future<Uint8List?> latestRecovery(LibraryRecoverySelection current) async {
    if ((await selection(forRecovery: true)).token != current.token) {
      throw StateError('Vị trí thư viện đã thay đổi. Hãy kiểm tra lại.');
    }
    final directory = Directory('${current.directoryPath}/backup-recovery');
    await _regularDirectory(directory);
    if (!await directory.exists()) return null;
    final files = await directory
        .list(followLinks: false)
        .where(
          (entry) =>
              entry is File &&
              RegExp(r'^recovery-\d+\.json$')
                  .hasMatch(entry.uri.pathSegments.last),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    for (final file in files) {
      try {
        if (await file.length() > LibrarySnapshot.maxBytes) continue;
        final bytes = await file.readAsBytes();
        BackupValidator(MemoryLibraryRepository()).validateSnapshot(bytes);
        return bytes;
      } on FormatException {
        // Keep corrupt recovery files and try an older independently valid one.
      }
    }
    return null;
  }

  Future<LibraryRecoveryResult> restore({
    required LibrarySnapshot snapshot,
    required String expectedSelectionToken,
    Uint8List? sourceBytes,
    void Function()? guard,
  }) {
    final key = root.absolute.path;
    final result = (_pending[key] ?? Future<void>.value()).then(
      (_) => _restore(
        snapshot: snapshot,
        expectedSelectionToken: expectedSelectionToken,
        sourceBytes: sourceBytes,
        guard: guard,
      ),
    );
    _pending[key] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<LibraryRecoveryResult> _restore({
    required LibrarySnapshot snapshot,
    required String expectedSelectionToken,
    Uint8List? sourceBytes,
    void Function()? guard,
  }) async {
    guard?.call();
    final validator = BackupValidator(MemoryLibraryRepository());
    validator.validateSnapshot(snapshot.encode());
    final libraryImage = LibrarySnapshot(snapshot.entries);
    final input = sourceBytes ?? snapshot.encode();
    if (input.isEmpty || input.length > LibrarySnapshot.maxBytes) {
      throw const FormatException(
        'Bản sao lưu trống hoặc vượt giới hạn 128 MB.',
      );
    }
    // A live Isar owner can still mutate files. The bootstrap owner must first
    // dispose app scopes and close that database before entering this method.
    if (Isar.getInstance('tachi_books') != null) {
      throw StateError('Đóng thư viện đang chạy trước khi phục hồi dữ liệu.');
    }
    final current = await selection(forRecovery: true);
    if (current.token != expectedSelectionToken) {
      throw StateError('Vị trí thư viện đã thay đổi sau khi xem trước.');
    }
    await root.create(recursive: true);
    final generations = Directory('${root.path}/.library-recovery');
    await _regularDirectory(generations);
    await generations.create();
    final nonce = List.generate(
      8,
      (_) => Random.secure().nextInt(256),
    ).map((n) => n.toRadixString(16).padLeft(2, '0')).join();
    var timestamp = DateTime.now().microsecondsSinceEpoch;
    if (await _records.exists()) {
      await for (final entry in _records.list(followLinks: false)) {
        final match = _recordName.firstMatch(entry.uri.pathSegments.last);
        if (match != null) {
          timestamp = max(timestamp, int.parse(match[1]!.substring(0, 20)) + 1);
        }
      }
    }
    final stamp = '${timestamp.toString().padLeft(20, '0')}-$nonce';
    final generation = Directory('${generations.path}/$stamp');
    await generation.create();
    final preserved = Directory('${generation.path}/preserved');
    await preserved.create();
    var copiedFiles = 0, copiedBytes = 0;
    final manifest = <Map<String, Object>>[];
    Future<void> copyFile(File file, String relative) async {
      guard?.call();
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('Tệp thư viện không an toàn để sao lưu.');
      }
      final length = await file.length();
      if (++copiedFiles > maxPreservedFiles ||
          (copiedBytes += length) > maxPreservedBytes) {
        throw const FormatException(
          'Dữ liệu gốc vượt giới hạn phục hồi an toàn 2 GB hoặc 100.000 tệp.',
        );
      }
      final target = File('${preserved.path}/$relative');
      await target.parent.create(recursive: true);
      final digest = await sha256.bind(file.openRead()).first;
      final sink = target.openWrite();
      try {
        await sink.addStream(file.openRead());
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await target.length() != length ||
          (await sha256.bind(target.openRead()).first) != digest ||
          (await sha256.bind(file.openRead()).first) != digest) {
        throw StateError(
          'Không xác minh được bản giữ dữ liệu gốc. Chưa chuyển thư viện.',
        );
      }
      manifest.add({'path': relative, 'bytes': length, 'sha256': '$digest'});
    }

    Future<void> copyDirectory(
      Directory source,
      String relative, [
      int depth = 0,
    ]) async {
      if (depth > 32) {
        throw const FormatException(
          'Thư mục dữ liệu lồng quá sâu để phục hồi an toàn.',
        );
      }
      await _regularDirectory(source);
      if (!await source.exists()) return;
      await Directory('${preserved.path}/$relative').create(recursive: true);
      await for (final entry in source.list(followLinks: false)) {
        final name = entry.uri.pathSegments.where((v) => v.isNotEmpty).last;
        if (entry is Directory) {
          await copyDirectory(entry, '$relative/$name', depth + 1);
        } else if (entry is File) {
          await copyFile(entry, '$relative/$name');
        } else {
          throw const FormatException(
            'Không sao lưu tự động liên kết trong thư viện.',
          );
        }
      }
    }

    final oldDirectory = Directory(current.directoryPath);
    if (await oldDirectory.exists()) {
      await for (final entry in oldDirectory.list(followLinks: false)) {
        final name = entry.uri.pathSegments.where((v) => v.isNotEmpty).last;
        if (name.startsWith('tachi_books.')) {
          await copyFile(File(entry.path), name);
        }
      }
      for (final name in ['attachments', 'backup-recovery']) {
        await copyDirectory(Directory('${oldDirectory.path}/$name'), name);
      }
    }
    // A damaged selector cannot identify one trustworthy active generation.
    // Preserve every previous managed generation before creating a new head.
    if (current.token.startsWith('damaged:')) {
      await for (final old in generations.list(followLinks: false)) {
        if (old.absolute.uri.normalizePath() ==
            generation.absolute.uri.normalizePath()) {
          continue;
        }
        if (old is! Directory) {
          throw const FormatException('Vị trí phục hồi cũ không an toàn.');
        }
        final name = old.uri.pathSegments.where((v) => v.isNotEmpty).last;
        await copyDirectory(old, 'previous-generations/$name');
      }
    }
    await copyDirectory(_records, 'location-records');
    await File('${preserved.path}/manifest.json').writeAsString(
      jsonEncode({
        'schema': 'tachi-books-preserved-library',
        'version': 1,
        'files': manifest,
      }),
      flush: true,
    );
    final originalBackup = File('${generation.path}/original-backup.bin');
    await originalBackup.writeAsBytes(input, flush: true);
    if (sha256.convert(await originalBackup.readAsBytes()) !=
        sha256.convert(input)) {
      throw StateError('Không xác minh được bản sao lưu đã chọn.');
    }
    guard?.call();
    final nextDirectory = Directory('${generation.path}/library');
    await nextDirectory.create();
    LibraryRepository? repository;
    try {
      repository = await _open(nextDirectory.path);
      await repository.replaceSnapshot(
        libraryImage,
        expectedFingerprint: (await repository.snapshot()).fingerprint,
      );
      await repository.close();
      repository = null;
      repository = await _open(nextDirectory.path);
      final after = await repository.snapshot();
      validator.validateSnapshot(after.encode());
      if (after.fingerprint != libraryImage.fingerprint) {
        throw StateError(
          'Thư viện phục hồi không khớp sau khi mở lại. Chưa chuyển thư viện.',
        );
      }
    } finally {
      await repository?.close();
    }
    await beforePublish?.call();
    guard?.call();
    if ((await selection(forRecovery: true)).token != expectedSelectionToken) {
      throw StateError('Vị trí thư viện đã thay đổi trong lúc phục hồi.');
    }
    guard?.call();
    await _regularDirectory(_records);
    await _records.create(recursive: true);
    final record = File('${_records.path}/active-$stamp.json');
    final pending = File('${record.path}.pending');
    await pending.writeAsString(
      jsonEncode({
        'schema': 'tachi-books-library-location',
        'version': 1,
        'directory': '.library-recovery/$stamp/library',
      }),
      flush: true,
    );
    guard?.call();
    if ((await selection(forRecovery: true)).token != expectedSelectionToken) {
      throw StateError('Vị trí thư viện đã thay đổi trước khi ghi.');
    }
    guard?.call();
    await pending.rename(record.path);
    final published = await selection();
    if (Directory(published.directoryPath).absolute.path !=
        nextDirectory.absolute.path) {
      throw StateError(
        'Chưa xác minh được vị trí thư viện mới. Hãy mở lại ứng dụng.',
      );
    }
    return LibraryRecoveryResult(
      selection: published,
      snapshot: libraryImage,
      preservedDirectoryPath: preserved.path,
      originalBackupPath: originalBackup.path,
      copiedFiles: copiedFiles,
      copiedBytes: copiedBytes,
    );
  }
}

Future<String> resolveActiveLibraryDirectory(String root) async =>
    (await LibraryRecoveryStore(Directory(root)).selection()).directoryPath;
