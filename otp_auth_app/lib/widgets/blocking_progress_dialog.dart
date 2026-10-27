import 'dart:async';

import 'package:flutter/material.dart';









class _BlockingProgressDialog extends StatelessWidget {
  const _BlockingProgressDialog({required this.message, required this.detail});

  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return PopScope(

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
