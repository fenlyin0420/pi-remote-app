import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';

// Sealed state for ChatViewModel.
// Switch exhaustively in ChatPage.build().

sealed class ChatState {
  const ChatState();
}

// No peer paired yet — show QR scanner redirect.
class ChatNoPeer extends ChatState {
  const ChatNoPeer();
}

// Establishing connection after boot or reconnect.
class ChatConnecting extends ChatState {
  const ChatConnecting();
}

// Connected and ready.
class ChatReady extends ChatState {
  final List<ChatMessage> messages;
  final StreamingMessage? streaming;
  final bool isOffline; // true → input disabled, banner visible
  // True once the Mac signalled this device is no longer in peers.json
  // (relay returned an `unknown_peer` error). Stays true until the user
  // re-pairs or revokes; suppresses input and surfaces a re-pair banner.
  final bool pairingRevoked;
  // Set when the Pi sent a `bye` (graceful disconnect). Stops retry,
  // shows banner offering manual reconnect. `peerOfflineReason` is the
  // raw wire reason (peer_stop / session_replaced / shutdown / …).
  final String? peerOfflineReason;
  /// Live relay-reported presence of the active peer. When the peer is
  /// [PresenceOffline] the chat enters read-only mode (history visible,
  /// input disabled). Defaults to [PresenceUnknown] until the relay
  /// reports.
  final PresenceState peerPresence;

  const ChatReady({
    required this.messages,
    this.streaming,
    this.isOffline = false,
    this.pairingRevoked = false,
    this.peerOfflineReason,
    this.peerPresence = const PresenceUnknown(),
  });

  ChatReady copyWith({
    List<ChatMessage>? messages,
    StreamingMessage? streaming,
    bool? isOffline,
    bool? pairingRevoked,
    String? peerOfflineReason,
    PresenceState? peerPresence,
    bool clearStreaming = false,
    bool clearPeerOffline = false,
  }) =>
      ChatReady(
        messages: messages ?? this.messages,
        streaming: clearStreaming ? null : (streaming ?? this.streaming),
        isOffline: isOffline ?? this.isOffline,
        pairingRevoked: pairingRevoked ?? this.pairingRevoked,
        peerOfflineReason: clearPeerOffline
            ? null
            : (peerOfflineReason ?? this.peerOfflineReason),
        peerPresence: peerPresence ?? this.peerPresence,
      );

  @override
  bool operator ==(Object other) =>
      other is ChatReady &&
      other.messages == messages &&
      other.streaming == streaming &&
      other.isOffline == isOffline &&
      other.pairingRevoked == pairingRevoked &&
      other.peerOfflineReason == peerOfflineReason &&
      other.peerPresence.runtimeType == peerPresence.runtimeType;

  @override
  int get hashCode => Object.hash(
        messages,
        streaming,
        isOffline,
        pairingRevoked,
        peerOfflineReason,
        peerPresence.runtimeType,
      );
}

// Permanent offline — must re-pair.
class ChatFatalError extends ChatState {
  final String message;
  const ChatFatalError(this.message);

  @override
  bool operator ==(Object other) =>
      other is ChatFatalError && other.message == message;

  @override
  int get hashCode => message.hashCode;
}
