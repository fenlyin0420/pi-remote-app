import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/app_theme.dart';
import 'package:flutter/material.dart';

/// A row in the Home list.
///
/// Renders an inline presence dot (plano 12) driven by
/// [ConnectionManager.presenceStream]: green = online, grey = offline,
/// no dot = relay hasn't reported yet.
class SessionTile extends StatelessWidget {
  final PeerRecord peer;
  final PresenceState presence;
  final VoidCallback onOpen;

  const SessionTile({
    super.key,
    required this.peer,
    required this.presence,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kBg,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _Avatar(name: peer.nickname?.isNotEmpty == true
                  ? peer.nickname!
                  : peer.sessionName),
              const SizedBox(width: 14),
              Expanded(
                child: _TitleBlock(peer: peer),
              ),
              _PresenceDot(presence: presence),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresenceDot extends StatelessWidget {
  final PresenceState presence;
  const _PresenceDot({required this.presence});

  @override
  Widget build(BuildContext context) {
    final color = switch (presence) {
      PresenceOnline() => kSuccess,
      PresenceOffline() => kMuted,
      PresenceUnknown() => null,
    };
    if (color == null) {
      // Keep horizontal alignment stable even without a dot.
      return const SizedBox(width: 10, height: 10);
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  final PeerRecord peer;
  const _TitleBlock({required this.peer});

  @override
  Widget build(BuildContext context) {
    final nickname = peer.nickname;
    final hasNickname = nickname != null && nickname.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          hasNickname ? nickname : peer.sessionName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kText,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (hasNickname) ...[
          const SizedBox(height: 2),
          Text(
            peer.sessionName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kMuted2, fontSize: 12),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          'Last paired: ${_relativeTime(peer.pairedAt)}',
          style: const TextStyle(
            color: kMuted,
            fontSize: 12,
            fontFamily: kMono,
          ),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  const _Avatar({required this.name});

  @override
  Widget build(BuildContext context) {
    final initial = _initial(name);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: kSurface,
        border: Border.all(color: kBorder),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: kAccent,
          fontFamily: kMono,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _initial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.characters.first.toUpperCase();
}

String _relativeTime(String isoUtc) {
  final parsed = DateTime.tryParse(isoUtc);
  if (parsed == null) return isoUtc;
  final now = DateTime.now().toUtc();
  final diff = now.difference(parsed);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return isoUtc.substring(0, 10);
}
