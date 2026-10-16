import 'dart:typed_data';

import '../domain/catalogue.dart';
import '../domain/native_source_engine.dart';
import '../domain/source_filters.dart';
import '../domain/extension_backup.dart';
import 'source_repository.dart';

/// Keeps the existing companion contracts available alongside on-device engines.
class OnDeviceSourceRepository extends SourceRepository
    implements NativeExtensionBackupEngine, NativeExtensionBackupTransaction {
  OnDeviceSourceRepository({
    required super.tachimangaUrl,
    required super.vbookUrl,
    required this.runtimes,
    this.ownsRuntimes = true,
  });

  final Map<SourceEngine, NativeSourceEngine> runtimes;
  final bool ownsRuntimes;
  bool _disposed = false;

  @override
  Future<T> exclusiveExtensionBackup<T>(Future<T> Function() action) {
    final ordered = runtimes.entries.toList()
      ..sort((a, b) => a.key.name.compareTo(b.key.name));
    Future<T> acquire(int index) {
      if (index == ordered.length) return action();
      final runtime = ordered[index].value;
      return runtime is NativeExtensionBackupTransaction
          ? (runtime as NativeExtensionBackupTransaction)
                .exclusiveExtensionBackup(() => acquire(index + 1))
          : acquire(index + 1);
    }

    return acquire(0);
  }

  @override
  Future<ExtensionBackup> captureExtensionBackup() async => ExtensionBackup([
    for (final runtime in runtimes.values)
      if (runtime is NativeExtensionBackupEngine)
        ...(await (runtime as NativeExtensionBackupEngine)
                .captureExtensionBackup())
            .packages,
  ]);

  @override
  Future<void> validateExtensionBackup(ExtensionBackup backup) async {
    // Check capabilities for the entire plan before any engine receives writes.
    for (final package in backup.packages) {
      if (runtimes[package.engine] is! NativeExtensionBackupEngine) {
        throw StateError(
          'Engine ${package.engine.name} chưa hỗ trợ phục hồi gói trên thiết bị này.',
        );
      }
    }
    for (final entry in runtimes.entries) {
      final packages = backup.packages
          .where((package) => package.engine == entry.key)
          .toList();
      if (packages.isNotEmpty) {
        await (entry.value as NativeExtensionBackupEngine)
            .validateExtensionBackup(ExtensionBackup(packages));
      }
    }
  }

  @override
  Future<void> restoreExtensionBackup(ExtensionBackup backup) async {
    await validateExtensionBackup(backup);
    for (final entry in runtimes.entries) {
      final packages = backup.packages
          .where((package) => package.engine == entry.key)
          .toList();
      if (packages.isNotEmpty) {
        await (entry.value as NativeExtensionBackupEngine)
            .restoreExtensionBackup(ExtensionBackup(packages));
      }
    }
  }

  @override
  bool requiresExternalConnection(SourceEngine engine) =>
      !runtimes.containsKey(engine);

  @override
  bool usesNativeImageLoader(CatalogueBook book) =>
      runtimes[book.engine] is NativeImageEngine;

  @override
  bool usesNativeCoverLoader(CatalogueBook book) =>
      runtimes[book.engine] is NativeCoverImageEngine;

  @override
  Future<SourceImageData> fetchCover(CatalogueBook book) {
    final runtime = runtimes[book.engine];
    return runtime is NativeCoverImageEngine
        ? (runtime as NativeCoverImageEngine).fetchCover(book)
        : super.fetchCover(book);
  }

  @override
  bool canOpenNativeWebsite(CatalogueBook book) =>
      runtimes[book.engine] is NativeSourceBrowserEngine;

  @override
  bool supportsCatalogueBrowsing(SourceEngine engine) =>
      runtimes[engine] is NativeCatalogueBrowserEngine;

  @override
  bool supportsSourceFilters(SourceEngine engine) =>
      runtimes[engine] is NativeSourceFilterEngine;

  @override
  Future<SourceFilterSet> sourceFilters(CatalogueSource source) {
    final runtime = runtimes[source.engine];
    return runtime is NativeSourceFilterEngine
        ? (runtime as NativeSourceFilterEngine).sourceFilters(source)
        : super.sourceFilters(source);
  }

  @override
  Future<List<CatalogueBook>> searchFiltered(
    CatalogueSource source,
    String query,
    SourceFilterSet filters, {
    int page = 1,
  }) {
    final runtime = runtimes[source.engine];
    return runtime is NativeSourceFilterEngine
        ? (runtime as NativeSourceFilterEngine).searchFiltered(
            source,
            query,
            filters,
            page: page,
          )
        : super.searchFiltered(source, query, filters, page: page);
  }

  @override
  Future<List<CatalogueBook>> browse(
    CatalogueSource source, {
    required SourceBrowseMode mode,
    int page = 1,
  }) {
    final runtime = runtimes[source.engine];
    if (runtime is NativeCatalogueBrowserEngine) {
      return (runtime as NativeCatalogueBrowserEngine).browse(
        source,
        mode: mode,
        page: page,
      );
    }
    return super.browse(source, mode: mode, page: page);
  }

  @override
  bool supportsExtensionRemoval(SourceEngine engine) =>
      runtimes[engine] is NativeExtensionManagementEngine;

  @override
  bool supportsExtensionFileImport(SourceEngine engine) =>
      runtimes[engine] is NativeExtensionFileEngine;

  @override
  Future<CatalogueExtension> installExtensionBytes(
    SourceEngine engine,
    Uint8List bytes,
  ) {
    final runtime = runtimes[engine];
    if (runtime is NativeExtensionFileEngine) {
      return (runtime as NativeExtensionFileEngine).installExtensionBytes(
        bytes,
      );
    }
    return super.installExtensionBytes(engine, bytes);
  }

  @override
  Future<void> uninstallExtension(SourceEngine engine, String packageId) {
    final runtime = runtimes[engine];
    if (runtime is NativeExtensionManagementEngine) {
      return (runtime as NativeExtensionManagementEngine).uninstallExtension(
        packageId,
      );
    }
    return super.uninstallExtension(engine, packageId);
  }

  @override
  Future<void> openWebsite(CatalogueBook book) {
    final runtime = runtimes[book.engine];
    if (runtime is NativeSourceBrowserEngine) {
      return (runtime as NativeSourceBrowserEngine).openWebsite(book);
    }
    return super.openWebsite(book);
  }

  @override
  Future<SourceImageData> fetchImage(
    CatalogueBook book,
    CatalogueChapter chapter,
    int page,
    String url,
  ) {
    final runtime = runtimes[book.engine];
    if (runtime is NativeImageEngine) {
      return (runtime as NativeImageEngine).fetchImage(
        book,
        chapter,
        page,
        url,
      );
    }
    return super.fetchImage(book, chapter, page, url);
  }

  @override
  Future<Map<String, dynamic>> health(SourceEngine engine) =>
      runtimes[engine]?.health() ?? super.health(engine);

  @override
  Future<List<CatalogueSource>> listSources(SourceEngine engine) =>
      runtimes[engine]?.listSources() ?? super.listSources(engine);

  @override
  Future<List<CatalogueExtension>> extensions(SourceEngine engine) =>
      runtimes[engine]?.extensions() ?? super.extensions(engine);

  @override
  Future<void> installExtension(SourceEngine engine, String packageUrl) =>
      runtimes[engine]?.installExtension(packageUrl) ??
      super.installExtension(engine, packageUrl);

  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) =>
      runtimes[source.engine]?.search(source, query, page: page) ??
      super.search(source, query, page: page);

  @override
  Future<CatalogueBook> detail(CatalogueBook book) =>
      runtimes[book.engine]?.detail(book) ?? super.detail(book);

  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) =>
      runtimes[book.engine]?.chapters(book) ?? super.chapters(book);

  @override
  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) =>
      runtimes[book.engine]?.chapter(book, chapter) ??
      super.chapter(book, chapter);

  @override
  Future<List<Map<String, dynamic>>> sourcePreferences(
    CatalogueSource source,
  ) =>
      runtimes[source.engine]?.sourcePreferences(source) ??
      super.sourcePreferences(source);

  @override
  Future<void> setSourcePreference(
    CatalogueSource source,
    int position,
    dynamic value,
  ) =>
      runtimes[source.engine]?.setSourcePreference(source, position, value) ??
      super.setSourcePreference(source, position, value);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (ownsRuntimes) {
      for (final runtime in runtimes.values.toSet()) {
        runtime.dispose();
      }
    }
    super.dispose();
  }
}
