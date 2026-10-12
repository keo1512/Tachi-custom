import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../library/presentation/library_view_model.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../../settings/settings_controller.dart';
import '../../sources/presentation/extension_catalogue_controller.dart';
import '../../sources/presentation/browse_widgets.dart';
import '../application/deep_link_queue.dart';
import '../data/deep_link_platform.dart';
import '../domain/app_deep_link.dart';

/// Sits under PrivacyGate; external links never bypass authentication or restore.
class DeepLinkGate extends ConsumerStatefulWidget {
  const DeepLinkGate({super.key, required this.router, required this.child});
  final GoRouter router;
  final Widget child;
  @override
  ConsumerState<DeepLinkGate> createState() => _DeepLinkGateState();
}

class _DeepLinkGateState extends ConsumerState<DeepLinkGate>
    with WidgetsBindingObserver {
  final queue = DeepLinkQueue();
  StreamSubscription<String>? subscription;
  bool active = true, draining = false, scheduled = false;
  int privacyGeneration = 0;
  final errors = <String>{};
  bool get allowed {
    final privacy = ref.read(appLockProvider);
    return active &&
        privacy.initialized &&
        privacy.configurationValid &&
        !privacy.locked &&
        !privacy.obscured &&
        !privacy.authenticating;
  }

  @override
  void initState() {
    super.initState();
    active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    final platform = ref.read(deepLinkPlatformProvider);
    subscription = platform.links.listen(receive);
    unawaited(
      platform
          .ready()
          .then((values) {
            if (mounted) {
              for (final value in values) {
                receive(value);
              }
            }
          })
          .catchError((Object _) {}),
    );
  }

  void receive(String raw) {
    if (!mounted) return;
    try {
      final link = AppDeepLink.parse(raw);
      if (link == null) return;
      if (link is LibraryDeepLink &&
          link.notification &&
          ref.read(settingsProvider).incognitoMode) {
        return;
      }
      queue.add(
        PendingDeepLink(
          link,
          ref.read(libraryRepositoryProvider),
          ref.read(preferencesProvider),
        ),
      );
      schedule();
    } on FormatException catch (error) {
      // A repeated malformed callback cannot open an endless stack of dialogs.
      if (errors.length < 16) errors.add(error.message.toString());
      schedule();
    }
  }

  void schedule() {
    if (scheduled || draining || !mounted || !allowed) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (mounted && allowed) unawaited(drain());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void report(String text) {
    final context = widget.router.routerDelegate.navigatorKey.currentContext;
    if (context != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> drain() async {
    if (draining || !allowed) return;
    draining = true;
    try {
      if (errors.isNotEmpty) {
        report(errors.first);
        errors.clear();
      }
      while (mounted && allowed) {
        final request = queue.take();
        if (request == null) break;
        final privacy = privacyGeneration;
        bool current() =>
            mounted &&
            allowed &&
            privacy == privacyGeneration &&
            request.current &&
            !(request.link is LibraryDeepLink &&
                (request.link as LibraryDeepLink).notification &&
                ref.read(settingsProvider).incognitoMode);
        try {
          if (!current()) continue;
          if (request.link case RepositoryDeepLink(:final engine, :final url)) {
            final context =
                widget.router.routerDelegate.navigatorKey.currentContext;
            if (context == null || !context.mounted) break;
            final agreed = await showCupertinoDialog<bool>(
              context: context,
              builder: (context) => CupertinoAlertDialog(
                title: Text(
                  'Thêm kho ${sourceEngineName(engine)} từ liên kết?',
                ),
                content: Text(
                  '$url\n\nApp sẽ đọc danh sách tiện ích của kho. Bạn chọn và cài từng tiện ích sau.',
                ),
                actions: [
                  CupertinoDialogAction(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Hủy'),
                  ),
                  CupertinoDialogAction(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Thêm kho'),
                  ),
                ],
              ),
            );
            if (agreed != true || !current()) continue;
            await ref
                .read(extensionCatalogueProvider.notifier)
                .add(engine, url, isCurrent: current);
            if (current()) widget.router.push('/repositories');
          } else if (request.link case TaskDeepLink(:final route)) {
            if (current() && widget.router.state.uri.path != route) {
              widget.router.go(route);
            }
          } else {
            final route = await request.libraryRoute();
            final displayed = widget.router.state.extra;
            if (current() &&
                (widget.router.routeInformationProvider.value.uri.toString() !=
                        route ||
                    (displayed is LibraryLinkHandoff &&
                        displayed.expectedRevision != request.revision))) {
              widget.router.push(
                route,
                extra: LibraryLinkHandoff(request.revision),
              );
            }
          }
        } on FormatException catch (error) {
          if (mounted && allowed) report(error.message.toString());
        } catch (_) {
          if (mounted && allowed) {
            report(
              'Không mở được liên kết. Hãy kiểm tra lại thư viện hoặc kho tiện ích.',
            );
          }
        } finally {
          queue.finish(request);
        }
      }
    } finally {
      draining = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (!active) privacyGeneration++;
    schedule();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appLockProvider, (_, next) {
      if (next.locked ||
          next.obscured ||
          next.authenticating ||
          !next.configurationValid) {
        privacyGeneration++;
      }
      schedule();
    });
    schedule();
    return widget.child;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(subscription?.cancel());
    queue.clear();
    super.dispose();
  }
}
