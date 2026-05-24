import 'package:app/pairing/storage.dart';
import 'package:app/ui/app_theme.dart';
import 'package:flutter/material.dart';

/// Confirmation dialog shown before a peer is revoked. Returns true if the
/// user confirmed, false (or null) otherwise.
Future<bool> showRevokeConfirmDialog(
  BuildContext context, {
  required PeerRecord peer,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kSurface,
      title: Text(
        'Revoke "${peer.sessionName}"?',
        style: const TextStyle(color: kText),
      ),
      content: const Text(
        "You'll need to pair again from the PC or Mac to reconnect.",
        style: TextStyle(color: kMuted2),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel', style: TextStyle(color: kMuted2)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text(
            'Revoke',
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
    ),
  );
  return ok == true;
}
