import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/diagnostics/diagnostic_log.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/library_view_model.dart';
import '../data/source_repository.dart';
import '../domain/catalogue.dart';

/// Select the source's own image loader without downloading in a widget build.
/// Local/custom covers never initialize an extension runtime.
ImageProvider<Object>? sourceCoverImage(WidgetRef ref, CatalogueBook book) {
  final cover = book.coverUrl;
  if (cover.isEmpty) return null;
  if (cover.startsWith('data:')) return _localCover(cover);
  final uri = Uri.tryParse(cover);
  if (uri == null ||
      (uri.hasScheme && !{'http', 'https'}.contains(uri.scheme)) ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return null;
  }
  final repository = ref.watch(sourceRepositoryProvider);
  if (repository.usesNativeCoverLoader(book)) {
    return SourceCoverImage(repository: repository, book: book);
  }
  return uri.hasAuthority && uri.hasScheme ? NetworkImage(cover) : null;
}

ImageProvider<Object>? libraryCoverImage(WidgetRef ref, LibraryBook book) {
  if (book.cover.isEmpty) return null;
  if (book.cover.startsWith('data:')) return _localCover(book.cover);
  if (book.engine == 'local') return null;
  return sourceCoverImage(
    ref,
    CatalogueBook(
      ref: book.sourceRef,
      title: book.title,
      sourceId: book.sourceId,
      coverUrl: book.cover,
      kind: book.kind == 'manga' ? ContentKind.manga : ContentKind.novel,
      engine: book.engine == 'vbook'
          ? SourceEngine.vbook
          : SourceEngine.tachimanga,
    ),
  );
}

ImageProvider<Object>? _localCover(String cover) {
  return cover.startsWith('data:image/') ? _LocalCoverImage(cover) : null;
}

/// A data URI is the stable content key. Rebuilding a tile must not allocate
/// new bytes and force another decode of an unchanged custom/local cover.
@immutable
class _LocalCoverImage extends ImageProvider<_LocalCoverImage> {
  const _LocalCoverImage(this.cover);
  final String cover;

  @override
  Future<_LocalCoverImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _LocalCoverImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: 'Ảnh bìa trong thiết bị',
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    try {
      final bytes = UriData.parse(cover).contentAsBytes();
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
        throw const FormatException('Ảnh bìa rỗng hoặc vượt giới hạn 8 MB.');
      }
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _LocalCoverImage && cover == other.cover;

  @override
  int get hashCode => cover.hashCode;

  @override
  String toString() => 'LocalCoverImage()';
}

/// Flutter's image cache deduplicates foreground/backdrop/list requests with
/// the same source and repository. Headers and cookies stay inside the runtime.
@immutable
class SourceCoverImage extends ImageProvider<SourceCoverImage> {
  const SourceCoverImage({required this.repository, required this.book});

  final SourceRepository repository;
  final CatalogueBook book;

  @override
  Future<SourceCoverImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    SourceCoverImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: 'Ảnh bìa nguồn',
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    try {
      final image = await repository.fetchCover(book);
      if (image.bytes.isEmpty || image.bytes.length > 8 * 1024 * 1024) {
        throw const ApiException(
          'Ảnh bìa rỗng hoặc vượt giới hạn 8 MB.',
          code: 'INVALID_SOURCE_DATA',
        );
      }
      return await decode(await ui.ImmutableBuffer.fromUint8List(image.bytes));
    } catch (error) {
      // A failed first load must not poison the cache after a source is
      // installed, a browser challenge is completed, or the network recovers.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      DiagnosticLogs.error('source', error);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SourceCoverImage &&
      identical(repository, other.repository) &&
      book.engine == other.book.engine &&
      book.sourceId == other.book.sourceId &&
      book.ref == other.book.ref &&
      book.coverUrl == other.book.coverUrl;

  @override
  int get hashCode => Object.hash(
    identityHashCode(repository),
    book.engine,
    book.sourceId,
    book.ref,
    book.coverUrl,
  );

  @override
  String toString() => 'SourceCoverImage(${book.engine.name})';
}
