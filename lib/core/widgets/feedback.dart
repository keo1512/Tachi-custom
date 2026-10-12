import 'package:flutter/material.dart';

import '../format/error_messages.dart';
import '../diagnostics/diagnostic_log.dart';

export '../format/error_messages.dart' show userFacingError;

void message(BuildContext context, Object text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$text'), behavior: SnackBarBehavior.floating),
  );
}

Future<T?> perform<T>(
  BuildContext context,
  Future<T> Function() action, {
  String? success,
}) async {
  try {
    final result = await action();
    if (success != null && context.mounted) message(context, success);
    return result;
  } catch (e) {
    DiagnosticLogs.error('app', e);
    if (context.mounted) message(context, userFacingError(e));
    return null;
  }
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
    this.secondary,
  });
  final IconData icon;
  final String title, description;
  final Widget? action, secondary;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 64,
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: .6),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                description,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, height: 1.5),
              ),
              if (action != null) ...[const SizedBox(height: 24), action!],
              if (secondary != null) ...[const SizedBox(height: 8), secondary!],
            ],
          ),
        ),
      ),
    ),
  );
}
