import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/source_repository.dart';
import '../domain/catalogue.dart';

enum SourceSearchPhase { queued, loading, complete, failed }

class SourceSearchResult {
  const SourceSearchResult({
    required this.source,
    this.phase = SourceSearchPhase.queued,
    this.books = const [],
    this.error,
  });
  final CatalogueSource source;
  final SourceSearchPhase phase;
  final List<CatalogueBook> books;
  final String? error;
}

/// Independent results arrive as each source finishes, with a bounded network
/// fanout. A newer query/disposal rejects all callbacks from the previous run.
class GlobalSearchController extends ChangeNotifier {
  GlobalSearchController(this.repository);
  final SourceRepository repository;
  List<SourceSearchResult> results = const [];
  String query = '';
  int _generation = 0;
  bool _disposed = false;
  int _activeRequests = 0;
  final _waitingSlots = <Completer<void>>[];

  Future<void> _takeSlot() async {
    if (_activeRequests < 3) {
      _activeRequests++;
      return;
    }
    final ready = Completer<void>();
    _waitingSlots.add(ready);
    await ready.future;
  }

  void _releaseSlot() {
    if (_waitingSlots.isNotEmpty) {
      _waitingSlots.removeAt(0).complete();
    } else {
      _activeRequests--;
    }
  }

  bool get busy => results.any(
    (item) =>
        item.phase == SourceSearchPhase.loading ||
        item.phase == SourceSearchPhase.queued,
  );

  void clear() {
    if (_disposed) return;
    _generation++;
    query = '';
    results = const [];
    notifyListeners();
  }

  Future<void> search(String input, Iterable<CatalogueSource> sources) async {
    if (_disposed) return;
    final request = ++_generation;
    query = input.trim();
    final unique = {for (final source in sources) source.identity: source}
        .values
        .toList();
    results = query.isEmpty
        ? const []
        : unique.map((source) => SourceSearchResult(source: source)).toList();
    notifyListeners();
    if (query.isEmpty) return;
    var next = 0;
    Future<void> worker() async {
      while (!_disposed && request == _generation && next < unique.length) {
        final index = next++;
        await _fetch(index, request, query);
      }
    }

    await Future.wait(
      List.generate(unique.length.clamp(0, 3), (_) => worker()),
    );
  }

  Future<void> retry(String identity) async {
    final index = results.indexWhere(
      (item) => item.source.identity == identity,
    );
    if (_disposed ||
        index < 0 ||
        results[index].phase != SourceSearchPhase.failed) {
      return;
    }
    await _fetch(index, _generation, query);
  }

  Future<void> _fetch(int index, int request, String searchedQuery) async {
    final source = results[index].source;
    void publish(SourceSearchResult result) {
      if (_disposed || request != _generation) return;
      results = [...results]..[index] = result;
      notifyListeners();
    }

    await _takeSlot();
    if (_disposed || request != _generation) {
      _releaseSlot();
      return;
    }
    publish(
      SourceSearchResult(source: source, phase: SourceSearchPhase.loading),
    );
    try {
      final books = await repository.search(source, searchedQuery);
      publish(
        SourceSearchResult(
          source: source,
          phase: SourceSearchPhase.complete,
          books: {for (final book in books) book.identity: book}.values
              .take(6)
              .toList(growable: false),
        ),
      );
    } catch (error) {
      publish(
        SourceSearchResult(
          source: source,
          phase: SourceSearchPhase.failed,
          error: '$error',
        ),
      );
    } finally {
      _releaseSlot();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
