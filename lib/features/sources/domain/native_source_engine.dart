import 'dart:typed_data';

import 'catalogue.dart';
import 'source_filters.dart';
import 'extension_backup.dart';

/// An installed source runtime in the app's own sandbox.
abstract interface class NativeSourceEngine {
  Future<Map<String, dynamic>> health();
  Future<List<CatalogueSource>> listSources();
  Future<List<CatalogueExtension>> extensions();
  Future<void> installExtension(String packageUrl);
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  });
  Future<CatalogueBook> detail(CatalogueBook book);
  Future<List<CatalogueChapter>> chapters(CatalogueBook book);
  Future<ChapterContent> chapter(CatalogueBook book, CatalogueChapter chapter);
  Future<List<Map<String, dynamic>>> sourcePreferences(CatalogueSource source);
  Future<void> setSourcePreference(
    CatalogueSource source,
    int position,
    dynamic value,
  );
  void dispose();
}

/// Some APKs decode images or modify requests inside their own HTTP client.
abstract interface class NativeImageEngine {
  Future<SourceImageData> fetchImage(
    CatalogueBook book,
    CatalogueChapter chapter,
    int page,
    String url,
  );
}

/// Covers use the source's HTTP headers/client, independently of chapter image
/// hooks. Optional so existing engines keep their ordinary image behavior.
abstract interface class NativeCoverImageEngine {
  Future<SourceImageData> fetchCover(CatalogueBook book);
}

abstract interface class NativeCoverCacheEngine {
  Future<void> invalidateCover(CatalogueBook book);
  Future<void> clearCoverCache();
}

abstract interface class NativeSourceBrowserEngine {
  Future<void> openWebsite(CatalogueBook book);
}

abstract interface class NativeSourceMaintenanceEngine {
  Future<void> clearSourceCache();
  Future<void> clearCookies();
}

/// Optional operations implemented by runtimes that expose catalogue browsing.
abstract interface class NativeCatalogueBrowserEngine {
  Future<List<CatalogueBook>> browse(
    CatalogueSource source, {
    required SourceBrowseMode mode,
    int page = 1,
  });
}

abstract interface class NativeExtensionManagementEngine {
  Future<void> uninstallExtension(String packageId);
}

/// Packages selected from Files use the same validated installation path.
abstract interface class NativeExtensionFileEngine {
  Future<CatalogueExtension> installExtensionBytes(Uint8List bytes);
}

/// Optional so companion runtimes and existing mocks retain their contracts.
abstract interface class NativeExtensionBackupEngine {
  Future<ExtensionBackup> captureExtensionBackup();
  Future<void> validateExtensionBackup(ExtensionBackup backup);
  Future<void> restoreExtensionBackup(ExtensionBackup backup);
}

/// Optional lease for runtimes whose installed packages/public preferences can
/// mutate while a full backup restore awaits validation and library commit.
abstract interface class NativeExtensionBackupTransaction {
  Future<T> exclusiveExtensionBackup<T>(Future<T> Function() action);
}

abstract interface class NativeSourceFilterEngine {
  Future<SourceFilterSet> sourceFilters(CatalogueSource source);
  Future<List<CatalogueBook>> searchFiltered(
    CatalogueSource source,
    String query,
    SourceFilterSet filters, {
    int page = 1,
  });
}
