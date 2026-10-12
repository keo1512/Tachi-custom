import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The bootstrap owner disposes app scopes and closes storage before recovery.
final applicationRecoveryProvider = Provider<Future<void> Function()?>(
  (_) => null,
);
