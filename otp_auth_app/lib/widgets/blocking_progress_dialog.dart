import 'dart:async';

import 'package:flutter/material.dart';

/// A modal that stays up while something slow runs, and cannot be dismissed
/// while it does.
///
/// Several operations became genuinely slow on purpose: deriving a key from a
/// password now costs a couple of hundred thousand PBKDF2 rounds, which is the
/// point of it. Saving the recovery PDF waits on the server and then on the
/// disk. Without something on screen those all look like a click that did
/// nothing, so people click again.
class _BlockingProgressDialog extends StatelessWidget {
  const _BlockingProgressDialog({required this.message, required this.detail});

  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return PopScope(
      // Back or Escape must not tear the dialog off a task still running.
      canPop: false,
      child: AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        content: Row(
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.6,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: TextStyle(
                      color: onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      detail!,
                      style: TextStyle(
                        color: onSurface.withValues(alpha: 0.7),
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Run [task] with a blocking spinner over the screen, and return its result.
///
/// The dialog is always closed, including when [task] throws, so a failure
/// cannot leave the app stuck behind a spinner that never goes away.
Future<T> runWithProgress<T>(
  BuildContext context, {
  required String message,
  String? detail,
  required Future<T> Function() task,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var dialogIsUp = true;

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => _BlockingProgressDialog(message: message, detail: detail),
    ).then((_) => dialogIsUp = false),
  );

  try {
    return await task();
  } finally {
    if (dialogIsUp && navigator.canPop()) {
      navigator.pop();
    }
  }
}
