import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../../downloads/presentation/download_queue_controller.dart';
import '../presentation/library_category_controller.dart';
import '../presentation/library_view_model.dart';
import '../domain/library_book.dart';
import '../domain/library_categories.dart';
import '../data/library_mutation.dart';
import 'library_update_policy.dart';
import 'library_update_report.dart';
import 'extension_recovery_controller.dart';
import '../../privacy/application/app_lock_controller.dart';

final updateDeviceConditionsProvider =
    Provider<Future<Map<String, bool>?> Function()>(
      (ref) => () async {
        if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
        final result = await const MethodChannel('dev.tachibooks/reader')
            .invokeMapMethod<String, bool>('conditions');
        return result;
      },
    );
final libraryUpdateSchedulerProvider = Provider<LibraryUpdateScheduler>(
  LibraryUpdateScheduler.new,
);

class LibraryUpdateScheduler {
  LibraryUpdateScheduler(this.ref);
  final Ref ref;
  Future<String>? _active;
  Future<String> check(DateTime now, {bool force = false}) {
    if (_active != null) return _active!;
    final work = _run(now, force: force);
    _active = work;
    return work.whenComplete(() => _active = null);
  }

  Future<String> _run(DateTime now, {required bool force}) async {
    final gate = ref.read(libraryUpdateExecutionProvider);
    final execution = gate.begin();
    try {
      return await _runGuarded(
        now,
        force: force,
        execution: execution,
        gate: gate,
      );
    } finally {
      gate.finish(execution);
    }
  }

  Future<String> _runGuarded(
    DateTime now, {
    required bool force,
    required LibraryUpdateExecution execution,
    required LibraryUpdateExecutionGate gate,
  }) async {
    final privateSession = ref.read(settingsProvider).incognitoMode;
    final policy = ref.read(libraryUpdatePolicyProvider);
    if (!force && policy.hours == 0) return 'Cập nhật tự động đang tắt.';
    final prefs = ref.read(preferencesProvider);
    final last = prefs.getInt('libraryLastAutomaticUpdate');
    if (!force &&
        last != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(last)).inHours <
            policy.hours) {
      return 'Chưa đến chu kỳ cập nhật.';
    }
    if (!force && privateSession) {
      return 'Cập nhật tự động tạm dừng trong chế độ ẩn danh.';
    }
    await ref.read(appLockProvider.notifier).initialize();
    execution.check();
    if (!ref.mounted) return 'Đã dừng cập nhật.';
    final lock = ref.read(appLockProvider);
    if (!lock.initialized || !lock.configurationValid || lock.locked) {
      return 'Mở khóa ứng dụng để kiểm tra cập nhật.';
    }
    await ref.read(extensionRecoveryProvider.future);
    await gate.wait(execution);
    if (policy.wifiOnly || policy.chargingOnly) {
      final conditions = await ref.read(updateDeviceConditionsProvider)();
      execution.check();
      if (!ref.mounted) return 'Đã dừng cập nhật.';
      if (conditions == null) return 'Chưa xác định được điều kiện thiết bị.';
      if (policy.wifiOnly && conditions['wifi'] != true) {
        return 'Chờ kết nối Wi-Fi.';
      }
      if (policy.chargingOnly && conditions['charging'] != true) {
        return 'Chờ thiết bị đang sạc.';
      }
    }
    final repo = ref.read(libraryRepositoryProvider);
    final revision = repo.replacementRevision;
    final registry = ref.read(libraryCategoriesProvider);
    final before = await repo.list();
    await gate.wait(execution);
    if (!ref.mounted) return 'Đã dừng cập nhật.';
    execution.check();
    checkLibraryRevision(repo.replacementRevision, revision);
    final selected = before
        .where(
          (b) => registry.allowsUpdate(b) && policy.skipReason(b, now) == null,
        )
        .toList();
    final oldIds = {
      for (final b in selected) b.id: b.chapters.map((c) => c.id).toSet(),
    };
    final result = await ref
        .read(libraryProvider.notifier)
        .updateBooks(
          before.map((b) => b.id),
          expectedRevision: revision,
          skipReasons: {
            for (final book in before)
              if (!registry.allowsUpdate(book))
                book.id: 'Kệ được loại khỏi cập nhật'
              else if (policy.skipReason(book, now) != null)
                book.id: policy.skipReason(book, now)!,
          },
        );
    if (!ref.mounted) return 'Đã dừng cập nhật.';
    if (repo.replacementRevision != revision) {
      throw StateError('Thư viện đã khôi phục; kết quả tự động được bỏ qua.');
    }
    if (policy.downloadNew) {
      final latest = await repo.list();
      await gate.wait(execution);
      if (!ref.mounted) return 'Đã dừng cập nhật.';
      final queue = ref.read(downloadQueueProvider.notifier);
      var enqueued = false;
      for (final book in latest.where(
        (b) => oldIds.containsKey(b.id) && registry.allowsAutoDownload(b),
      )) {
        await gate.wait(execution);
        final ids = book.chapters
            .where(
              (c) =>
                  !oldIds[book.id]!.contains(c.id) &&
                  c.read != true &&
                  !c.downloaded,
            )
            .map((c) => c.id)
            .toList();
        if (ids.isEmpty) continue;
        await queue.enqueue(book.id, ids, expectedRevision: revision);
        execution.check();
        enqueued = true;
      }
      if (enqueued && ref.mounted) {
        await gate.wait(execution);
        await queue.start();
        execution.check();
      }
    }
    final summary =
        'Đã kiểm tra ${result.checkedBooks} truyện, thêm ${result.addedChapters} chương; '
        '${result.skippedBooks} truyện bỏ qua, ${result.failures.length} lỗi.';
    checkLibraryRevision(repo.replacementRevision, revision);
    await gate.wait(execution);
    if (!await prefs.setInt(
      'libraryLastAutomaticUpdate',
      now.millisecondsSinceEpoch,
    )) {
      throw StateError('Không lưu được thời điểm cập nhật.');
    }
    await prefs.setString('libraryAutomaticUpdateResult', summary);
    // updateBooks owns completion/error and per-book notices for manual and
    // scheduled updates alike. Do not announce the same run a second time.
    return summary;
  }

  /// Uses stable chapter IDs from the reader; it never changes reading progress.
  Future<int> downloadAhead(
    LibraryBook selection,
    String chapterId, {
    required int expectedRevision,
  }) async {
    final policy = ref.read(libraryUpdatePolicyProvider);
    if (policy.downloadAhead == 0 || selection.engine == 'local') return 0;
    final repo = ref.read(libraryRepositoryProvider);
    checkLibraryRevision(repo.replacementRevision, expectedRevision);
    if (policy.wifiOnly || policy.chargingOnly) {
      final conditions = await ref.read(updateDeviceConditionsProvider)();
      if (!ref.mounted ||
          conditions == null ||
          (policy.wifiOnly && conditions['wifi'] != true) ||
          (policy.chargingOnly && conditions['charging'] != true)) {
        return 0;
      }
    }
    final latest = await repo.find(selection.id);
    if (!ref.mounted) return 0;
    checkLibraryRevision(repo.replacementRevision, expectedRevision);
    if (latest == null ||
        bookSourceIdentity(latest) != bookSourceIdentity(selection)) {
      throw StateError('Truyện hoặc nguồn đã thay đổi. Hãy mở lại chương.');
    }
    final registry = ref.read(libraryCategoriesProvider);
    if (latest.categories.any(
      (name) => registry.policyFor(name).download == CategoryPolicy.exclude,
    )) {
      return 0;
    }
    final index = latest.chapters.indexWhere((c) => c.id == chapterId);
    if (index < 0) throw StateError('Chương không còn trong truyện.');
    final ids = latest.chapters
        .skip(index + 1)
        .take(policy.downloadAhead)
        .where((c) => !c.downloaded && c.read != true)
        .map((c) => c.id)
        .toList();
    if (ids.isEmpty) return 0;
    final queue = ref.read(downloadQueueProvider.notifier);
    await queue.enqueue(latest.id, ids, expectedRevision: expectedRevision);
    if (ref.mounted) await queue.start();
    return ids.length;
  }
}

/// Foreground scheduling is explicit: iOS decides whether suspended apps run.
/// No timer or network polling is kept alive when the app leaves the foreground.
class LibraryUpdateLifecycle extends ConsumerStatefulWidget {
  const LibraryUpdateLifecycle({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<LibraryUpdateLifecycle> createState() =>
      _UpdateLifecycleState();
}

class _UpdateLifecycleState extends ConsumerState<LibraryUpdateLifecycle>
    with WidgetsBindingObserver {
  Timer? timer;
  bool resumed = true;
  @override
  void initState() {
    super.initState();
    resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) configure();
    });
  }

  void configure() {
    timer?.cancel();
    timer = null;
    if (resumed && ref.read(libraryUpdatePolicyProvider).hours > 0) {
      check();
      timer = Timer.periodic(const Duration(minutes: 1), (_) => check());
    }
  }

  void check() => unawaited(
    ref.read(libraryUpdateSchedulerProvider).check(DateTime.now()).catchError((
      Object e,
    ) {
      debugPrint('Library update: $e');
      return '$e';
    }),
  );
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    resumed = state == AppLifecycleState.resumed;
    configure();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(libraryUpdatePolicyProvider, (_, _) => configure());
    return widget.child;
  }
}
