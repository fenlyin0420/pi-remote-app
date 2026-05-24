import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart' show PiHarness;
import 'package:app/ui/app_theme.dart';
import 'package:flutter/material.dart';

/// Per-pairing section header on the Home list (one per Pi).
///
/// Plan/27 Wave A — the second line ("via …") shows the agent
/// harness the PC is running. Default for legacy [PeerRecord]s saved
/// before the field was introduced is [PiHarness.piCodingAgentUnknown]
/// ("Pi coding agent"), so the subtitle never appears blank.
class PeerSectionHeader extends StatelessWidget {
  final PeerRecord peer;
  const PeerSectionHeader({super.key, required this.peer});

  @override
  Widget build(BuildContext context) {
    final label = (peer.nickname?.isNotEmpty ?? false)
        ? peer.nickname!
        : peer.sessionName.isNotEmpty
            ? peer.sessionName
            : peer.remoteEpk.substring(0, 8);
    final harness = peer.harness ?? PiHarness.piCodingAgentUnknown;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontFamily: kMono,
              fontSize: 11,
              color: kMuted,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'via ${harness.name}',
            style: const TextStyle(
              fontFamily: kMono,
              fontSize: 10,
              color: kMuted2,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
