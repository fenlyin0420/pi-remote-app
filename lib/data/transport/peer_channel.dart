// PlainPeerChannel — protocol message channel without E2E cipher.
//
// Wraps a connected PeerTransport. After pairing, use this to exchange
// ClientMessage / ServerMessage with the Pi extension.
//
//   send(ClientMessage)   → JSON          → transport.send()
//   serverMessages stream ← transport.receive() → JSON → ServerMessage

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/transport/channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/protocol/codec.dart';
// ControlInbound + IControlLink come from these.
import 'package:app/protocol/protocol.dart';
import 'package:flutter/foundation.dart' show debugPrint;

class PeerChannelError implements Exception {
  final String message;
  const PeerChannelError(this.message);

  @override
  String toString() => 'PeerChannelError: $message';
}

class PlainPeerChannel implements IChannel, IControlLink {
  final PeerTransport _transport;

  final _controller = StreamController<ServerMessage>.broadcast();
  bool _started = false;
  bool _closed = false;

  PlainPeerChannel({required PeerTransport transport}) : _transport = transport;

  // ---- IControlLink — forwards to the underlying transport when it
  //      supports raw control frames (production: WsTransport). For
  //      non-WS transports (tests / in-memory), returns an empty stream
  //      and silently drops outbound control frames.
  @override
  Stream<ControlInbound> get controlFrames {
    final t = _transport;
    if (t is IControlLink) return (t as IControlLink).controlFrames;
    return const Stream.empty();
  }

  @override
  void sendControl(Map<String, dynamic> json) {
    final t = _transport;
    if (t is IControlLink) (t as IControlLink).sendControl(json);
  }

  @override
  Stream<ServerMessage> get serverMessages {
    if (!_started) {
      _started = true;
      _receiveLoop();
    }
    return _controller.stream;
  }

  @override
  Future<void> send(ClientMessage msg) async {
    final bytes = Uint8List.fromList(utf8.encode(encodeClient(msg).trimRight()));
    await _transport.send(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport.close();
    if (!_controller.isClosed) await _controller.close();
  }

  Future<void> _receiveLoop() async {
    try {
      while (!_closed) {
        final bytes = await _transport.receive();
        _handleFrame(bytes);
      }
    } catch (_) {
      if (!_controller.isClosed) await _controller.close();
    }
  }

  void _handleFrame(Uint8List bytes) {
    String? line;
    try {
      line = utf8.decode(bytes);
      final msg = decodeServer(line);
      debugPrint('[ws-rx] frame ok type=${msg.runtimeType} bytes=${bytes.length}');
      if (!_controller.isClosed) _controller.add(msg);
    } on UnsupportedTypeException catch (e) {
      // Forward-compat: surface unknown server types as ErrorMessage.
      debugPrint('[ws-rx] unsupported_type: $e (preview=${_preview(line)})');
      if (!_controller.isClosed) {
        _controller.add(
          ErrorMessage(code: 'unsupported_type', message: 'unknown server type'),
        );
      }
    } catch (e, st) {
      // Was: silently dropped. Surfacing because we suspect session_history
      // (and similar protocol frames with nested objects) is being lost
      // here when a cast fails — bug hunt. Remove once green.
      debugPrint(
        '[ws-rx] decode ERROR: $e\n'
        '       preview=${_preview(line)}\n'
        '       stack=${st.toString().split("\n").take(3).join(" | ")}',
      );
    }
  }

  static String _preview(String? line) {
    if (line == null) return '<utf8-decode-failed>';
    const cap = 240;
    return line.length <= cap ? line : '${line.substring(0, cap)}…';
  }
}
