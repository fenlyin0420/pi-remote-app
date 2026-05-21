// Covers the AgentDone flush-race fix (bug 10.1).
//
// Scenario: the streaming buffer collects a chunk; the 16ms flush timer is
// armed; AgentDone arrives BEFORE the timer fires. Without the fix the
// timer would re-create a StreamingMessage after AgentDone clears it,
// leaving the typing indicator stuck on. The repo must drain the buffer
// inside the AgentDone branch and cancel the pending timer.

import 'dart:async';
import 'dart:io';

import 'package:app/data/repositories/i_session_repository.dart';
import 'package:app/data/repositories/session_history_store.dart';
import 'package:app/data/repositories/session_repository.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeChannel implements IChannel {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final List<ClientMessage> sent = [];

  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;

  @override
  Future<void> send(ClientMessage msg) async {
    sent.add(msg);
  }

  @override
  Future<void> close() => _ctrl.close();

  void push(ServerMessage m) => _ctrl.add(m);
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

/// Builds a SessionRepository with the channel adopted into the manager
/// AFTER the repo has subscribed — `statusStream` is broadcast and does not
/// replay, so `adopt` before construction would silently drop the inbound
/// subscription.
int _epkCounter = 0;

Future<({SessionRepository repo, ConnectionManager cm, _FakeChannel ch})>
    _setup({SessionHistoryStore? store, String? epkOverride}) async {
  final ch = _FakeChannel();
  final cm = ConnectionManager(
    factory: (_, _) async => ch,
    storage: _FakeStorage(),
  );
  final repo = SessionRepository(cm, store ?? SessionHistoryStore());
  final epk = epkOverride ?? 'epk_${++_epkCounter}';
  cm.adopt(ch, PeerRecord(
    remoteEpk: epk,
    sessionName: 'Pi',
    relayUrl: 'ws://localhost',
    pairedAt: '2026-01-01T00:00:00Z',
  ));
  // Let the status event + setActivePeer's Hive load complete.
  await Future<void>.delayed(const Duration(milliseconds: 5));
  return (repo: repo, cm: cm, ch: ch);
}

UserMessage _lastUserMessage(_FakeChannel ch) =>
    ch.sent.whereType<UserMessage>().last;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

late Directory _hiveDir;

void main() {
  setUpAll(() async {
    _hiveDir = Directory.systemTemp.createTempSync('hive_session_test_');
    Hive.init(_hiveDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await _hiveDir.delete(recursive: true);
  });

  group('SessionRepository — AgentDone flush race (bug 10.1)', () {
    test(
      'pending chunk in buffer is drained when AgentDone races the timer',
      () async {
        final s = await _setup();

        await s.repo.sendMessage('q?');
        final id = _lastUserMessage(s.ch).id;

        // Chunks land — the second one ('?') re-arms the 16ms timer.
        s.ch.push(AgentChunk(inReplyTo: id, delta: 'Olá'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // The first chunk flushed via the 16ms timer; now streaming.buffer = 'Olá'.
        expect(s.repo.current.streaming?.buffer, 'Olá');

        // Second chunk arrives → buffer holds '?', timer armed but not yet
        // fired. AgentDone races and wins.
        s.ch.push(AgentChunk(inReplyTo: id, delta: '?'));
        s.ch.push(AgentDone(inReplyTo: id));
        await Future<void>.delayed(Duration.zero);

        // Wait LONGER than the 16ms flush window to prove the cancelled
        // timer can't reincarnate streaming.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          s.repo.current.streaming,
          isNull,
          reason: 'streaming must stay null — no ghost StreamingMessage',
        );
        final assistantMsgs =
            s.repo.current.messages.whereType<AssistantMsg>().toList();
        expect(assistantMsgs, hasLength(1));
        expect(
          assistantMsgs.single.text,
          'Olá?',
          reason: 'pending delta must be appended to streamed buffer',
        );

        s.repo.dispose();
      },
    );

    test(
      'AgentDone after a normal flush still finalizes (regression)',
      () async {
        final s = await _setup();

        await s.repo.sendMessage('hi');
        final id = _lastUserMessage(s.ch).id;

        s.ch.push(AgentChunk(inReplyTo: id, delta: 'foo'));
        // Let the timer flush.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(s.repo.current.streaming?.buffer, 'foo');

        s.ch.push(AgentDone(inReplyTo: id));
        await Future<void>.delayed(Duration.zero);

        expect(s.repo.current.streaming, isNull);
        final assistantMsgs =
            s.repo.current.messages.whereType<AssistantMsg>().toList();
        expect(assistantMsgs.single.text, 'foo');

        s.repo.dispose();
      },
    );

    test(
      'AgentDone with no chunks (empty stream) still clears',
      () async {
        final s = await _setup();

        await s.repo.sendMessage('hi');
        final id = _lastUserMessage(s.ch).id;
        expect(s.repo.current.streaming, isNotNull);

        s.ch.push(AgentDone(inReplyTo: id));
        await Future<void>.delayed(Duration.zero);

        expect(s.repo.current.streaming, isNull);
        expect(
          s.repo.current.messages.whereType<AssistantMsg>(),
          isEmpty,
          reason: 'no AssistantMsg when nothing was streamed',
        );

        s.repo.dispose();
      },
    );
  });

  group('SessionRepository — tool_result fallback (bug 10.6)', () {
    test(
      'orphan tool_result materializes ToolEvent at the final status',
      () async {
        final s = await _setup();

        s.ch.push(ToolResult(toolCallId: 'orphan_1', result: 'output here'));
        await Future<void>.delayed(Duration.zero);

        final tools =
            s.repo.current.messages.whereType<ToolEvent>().toList();
        expect(tools, hasLength(1));
        expect(tools.single.toolCallId, 'orphan_1');
        expect(tools.single.status, ToolEventStatus.completed);
        expect(tools.single.result, 'output here');
        expect(tools.single.tool, 'unknown');

        s.repo.dispose();
      },
    );

    test(
      'tool_result after tool_request still updates the existing event '
      '(regression)',
      () async {
        final s = await _setup();

        s.ch.push(ToolRequest(
          toolCallId: 'pair_1',
          tool: 'bash',
          args: const {'cmd': 'ls'},
        ));
        await Future<void>.delayed(Duration.zero);

        final pending =
            s.repo.current.messages.whereType<ToolEvent>().toList();
        expect(pending, hasLength(1));
        expect(pending.single.tool, 'bash');
        expect(pending.single.status, ToolEventStatus.pending);

        s.ch.push(ToolResult(toolCallId: 'pair_1', result: 'output'));
        await Future<void>.delayed(Duration.zero);

        final finalTools =
            s.repo.current.messages.whereType<ToolEvent>().toList();
        expect(
          finalTools,
          hasLength(1),
          reason: 'must update in place, not create a duplicate',
        );
        expect(finalTools.single.tool, 'bash',
            reason: 'original tool name must survive the update');
        expect(finalTools.single.status, ToolEventStatus.completed);
        expect(finalTools.single.result, 'output');

        s.repo.dispose();
      },
    );
  });

  group('SessionRepository — UserInput (terminal input mirror)', () {
    test('UserInput → UserMsg appended + streaming armed', () async {
      final s = await _setup();

      s.ch.push(UserInput(id: 'local_x', text: 'hello from terminal'));
      await Future<void>.delayed(Duration.zero);

      final userMsgs =
          s.repo.current.messages.whereType<UserMsg>().toList();
      expect(userMsgs, hasLength(1));
      expect(userMsgs.single.id, 'local_x');
      expect(userMsgs.single.text, 'hello from terminal');

      expect(s.repo.current.streaming, isNotNull);
      expect(s.repo.current.streaming!.inReplyTo, 'local_x');

      s.repo.dispose();
    });

    test(
      'AgentChunk with in_reply_to matching UserInput appends to buffer',
      () async {
        final s = await _setup();

        s.ch.push(UserInput(id: 'local_x', text: 'hi'));
        s.ch.push(AgentChunk(inReplyTo: 'local_x', delta: 'oi!'));
        // Let the 16ms flush timer fire.
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(s.repo.current.streaming, isNotNull);
        expect(s.repo.current.streaming!.inReplyTo, 'local_x');
        expect(s.repo.current.streaming!.buffer, 'oi!');

        s.repo.dispose();
      },
    );
  });

  group('SessionRepository — Bye / graceful disconnect', () {
    test(
      'Bye → emits PeerWentOffline AND re-establishes (switchTo) so '
      'presence updates keep flowing; channel does NOT stay torn down',
      () async {
        final s = await _setup();
        final events = <SessionEvent>[];
        final sub = s.repo.eventStream.listen(events.add);

        // Sanity: we are online before the bye.
        expect(s.repo.current.connection, isA<StatusOnline>());

        s.ch.push(Bye(reason: ByeReason.peerStop, rawReason: 'peer_stop'));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final offline = events.whereType<PeerWentOffline>();
        expect(offline, hasLength(1));
        expect(offline.first.rawReason, 'peer_stop');

        // Regression for "tem que sair do chat e voltar pra atualizar":
        // after Bye we used to disconnect → StatusNoPeer + WS dead → no
        // presence updates → user stuck on banner. Now we never let
        // the state collapse to NoPeer (switchTo runs in
        // SessionRepository's Bye handler), so presence-driven
        // recovery in ChatViewModel can still fire when Pi comes back.
        expect(s.repo.current.connection, isNot(isA<StatusNoPeer>()),
            reason: 'must never collapse to NoPeer — that kills '
                'presence and forces manual reconnect');

        await sub.cancel();
        s.repo.dispose();
      },
    );
  });

  group('SessionRepository — session_sync (plan 11)', () {
    test(
      'setActivePeer loads cached history and emits it on the stream',
      () async {
        final store = SessionHistoryStore();
        final epk = 'epk_sync_${++_epkCounter}';
        await store.replaceFor(
          epk,
          const [
            UserMsg(id: 'u_old', text: 'cached question'),
            AssistantMsg(id: 'u_old', text: 'cached reply'),
          ],
          sessionStartedAt: 100,
          lastTs: 200,
        );

        final s = await _setup(store: store, epkOverride: epk);

        expect(s.repo.current.messages, hasLength(2));
        expect((s.repo.current.messages[0] as UserMsg).text, 'cached question');
        expect((s.repo.current.messages[1] as AssistantMsg).text, 'cached reply');

        s.repo.dispose();
      },
    );

    test(
      'after channel goes online a session_sync is dispatched within ~200ms',
      () async {
        final s = await _setup();
        // The 200ms debounce + a small margin.
        await Future<void>.delayed(const Duration(milliseconds: 250));

        final syncs = s.ch.sent.whereType<SessionSync>().toList();
        expect(syncs, isNotEmpty,
            reason: 'requestSync must fire after the channel becomes online');

        s.repo.dispose();
      },
    );

    test(
      'SessionHistory with a different sessionStartedAt DROPS '
      'Pi-confirmed messages from the dead session and ADOPTS Pi\'s '
      'new view (only cli_* tentatives — pending user sends — survive)',
      () async {
        // Two reports drove this design:
        //  - "stop + escrevi prompts + zerou" → wiping everything
        //    destroyed cli_* sends the user made while Pi was offline.
        //  - "reiniciei a sessão mas as mensagens continuam aqui" →
        //    keeping the dead session's confirmed history is wrong:
        //    Pi just announced a brand new session via its
        //    session_started_at, that IS the new ground truth.
        // Split: drop confirmed (non-cli_) AND keep tentatives (cli_*).
        final store = SessionHistoryStore();
        final epk = 'epk_sync_${++_epkCounter}';
        await store.replaceFor(
          epk,
          const [UserMsg(id: 'old', text: 'stale')],
          sessionStartedAt: 100,
          lastTs: 200,
        );

        final s = await _setup(store: store, epkOverride: epk);
        expect(s.repo.current.messages, hasLength(1));

        // Pi restarted: different session_started_at + brand new events.
        s.ch.push(SessionHistory(
          inReplyTo: 'sync_1',
          sessionStartedAt: 999,
          events: const [
            UserInputEvt(ts: 1000, id: 'u_new', text: 'fresh'),
            AgentMessageEvt(ts: 1100, inReplyTo: 'u_new', text: 'fresh reply'),
          ],
          eos: true,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // The "old/stale" was confirmed-history from the dead session
        // → dropped. New events from the new session → adopted.
        expect(s.repo.current.messages, hasLength(2));
        expect((s.repo.current.messages[0] as UserMsg).id, 'u_new');
        expect((s.repo.current.messages[1] as AssistantMsg).id, 'u_new');

        // Cache: session_started_at and lastTs adopt the new session.
        final reloaded = await store.loadFor(epk);
        expect(reloaded.sessionStartedAt, 999);
        expect(reloaded.lastTs, 1100);
        // Cache reflects the dropped state (no stale).
        expect(reloaded.messages, hasLength(2));
        expect(
          reloaded.messages.whereType<UserMsg>().any((m) => m.id == 'old'),
          isFalse,
        );

        s.repo.dispose();
      },
    );

    test(
      'restart with EMPTY history fully wipes confirmed cache (cleanly '
      'reflects "/remote-pi start" — fresh session, no prior turns)',
      () async {
        final store = SessionHistoryStore();
        final epk = 'epk_sync_${++_epkCounter}';
        await store.replaceFor(
          epk,
          const [
            UserMsg(id: 'a', text: 'old1'),
            AssistantMsg(id: 'a', text: 'old1 reply'),
            UserMsg(id: 'b', text: 'old2'),
            AssistantMsg(id: 'b', text: 'old2 reply'),
          ],
          sessionStartedAt: 100,
          lastTs: 200,
        );
        final s = await _setup(store: store, epkOverride: epk);
        expect(s.repo.current.messages, hasLength(4));

        // Pi restarts with empty buffer.
        s.ch.push(SessionHistory(
          inReplyTo: 'sync',
          sessionStartedAt: 999,
          events: const [],
          eos: true,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // All 4 dropped → fresh slate.
        expect(s.repo.current.messages, isEmpty);
        final reloaded = await store.loadFor(epk);
        expect(reloaded.messages, isEmpty);
        expect(reloaded.sessionStartedAt, 999);

        s.repo.dispose();
      },
    );

    test(
      'sendMessage while channel is null adds the bubble locally as '
      'cli_* (no transmit, no streaming) — regression for offline '
      'prompts being silently dropped',
      () async {
        final s = await _setup();
        // Tear down the channel to simulate Pi going offline (Bye →
        // disconnect → _conn.channel becomes null).
        await s.repo.disconnect();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(s.repo.current.connection, isA<StatusNoPeer>());

        await s.repo.sendMessage('typed while Pi is stop-ed');
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final users = s.repo.current.messages.whereType<UserMsg>().toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'typed while Pi is stop-ed');
        expect(users.single.id.startsWith('cli_'), isTrue);
        // No streaming indicator armed — UI input must stay enabled so
        // the user can queue more prompts while waiting for Pi.
        expect(s.repo.current.streaming, isNull);

        s.repo.dispose();
      },
    );

    // (Deleted: "cli_* tentatives survive Pi restart". The current
    // contract is mirror-Pi-exactly on every session_history. Offline
    // pending-send semantics — including how to preserve cli_*
    // messages across a Pi restart — will be addressed in a follow-up
    // task once we agree on the UX, likely as an explicit outbox.)

    test(
      'SessionHistory with the same sessionStartedAt REPLACES state '
      'with Pi\'s view exactly (mirror semantics)',
      () async {
        final store = SessionHistoryStore();
        final epk = 'epk_sync_${++_epkCounter}';
        // Cache has the AssistantMsg for u_old too — but Pi\'s response
        // below only has the UserInputEvt for u_old (no agent reply
        // event). After REPLACE we mirror Pi exactly → AssistantMsg
        // for u_old is dropped because it isn\'t in Pi\'s view.
        await store.replaceFor(
          epk,
          const [
            UserMsg(id: 'u_old', text: 'old'),
            AssistantMsg(id: 'u_old', text: 'old reply'),
          ],
          sessionStartedAt: 100,
          lastTs: 200,
        );

        final s = await _setup(store: store, epkOverride: epk);

        s.ch.push(SessionHistory(
          inReplyTo: 'sync_2',
          sessionStartedAt: 100,
          events: const [
            UserInputEvt(ts: 200, id: 'u_old', text: 'old'),
            UserInputEvt(ts: 300, id: 'u_new', text: 'fresh'),
            AgentMessageEvt(ts: 350, inReplyTo: 'u_new', text: 'fresh reply'),
          ],
          eos: true,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(
          s.repo.current.messages.map((m) => (m as dynamic).id).toList(),
          ['u_old', 'u_new', 'u_new'],
          reason: 'state mirrors Pi\'s events exactly — no merge with cache',
        );

        s.repo.dispose();
      },
    );

    test(
      'SessionHistory merges tool_request + tool_result into one ToolEvent',
      () async {
        final s = await _setup();
        s.ch.push(SessionHistory(
          inReplyTo: 'sync_3',
          sessionStartedAt: 500,
          events: const [
            ToolRequestEvt(
              ts: 100,
              toolCallId: 'tc_h',
              tool: 'bash',
              args: {'command': 'ls'},
            ),
            ToolResultEvt(ts: 200, toolCallId: 'tc_h', result: {'ok': true}),
          ],
          eos: true,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final tools =
            s.repo.current.messages.whereType<ToolEvent>().toList();
        expect(tools, hasLength(1));
        expect(tools.single.tool, 'bash');
        expect(tools.single.status, ToolEventStatus.completed);

        s.repo.dispose();
      },
    );

    test(
      'AgentDone persists the AssistantMsg so a reload sees it',
      () async {
        final store = SessionHistoryStore();
        final epk = 'epk_sync_${++_epkCounter}';
        final s1 = await _setup(store: store, epkOverride: epk);

        await s1.repo.sendMessage('hi');
        final id = s1.ch.sent.whereType<UserMessage>().last.id;
        s1.ch.push(AgentChunk(inReplyTo: id, delta: 'oi!'));
        s1.ch.push(AgentDone(inReplyTo: id));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        s1.repo.dispose();

        // Reload from disk via a fresh repo instance.
        final s2 = await _setup(store: store, epkOverride: epk);
        final reloaded = s2.repo.current.messages;
        expect(reloaded.whereType<UserMsg>().single.text, 'hi');
        expect(reloaded.whereType<AssistantMsg>().single.text, 'oi!');

        s2.repo.dispose();
      },
    );
  });

  group('SessionRepository — late construction seed', () {
    test(
      'when ConnectionManager is already Online BEFORE the repo is '
      'constructed, the repo seeds current.connection from _conn.status '
      '(does not stay at the initial StatusNoPeer)',
      () async {
        // Mirror the production race: boot opens the WS and adopts the
        // channel BEFORE anything `injector.get<SessionRepository>()`s.
        final ch = _FakeChannel();
        final cm = ConnectionManager(
          factory: (_, _) async => ch,
          storage: _FakeStorage(),
        );
        cm.adopt(ch, const PeerRecord(
          remoteEpk: 'epk_pre',
          sessionName: 'Pi',
          relayUrl: 'ws://localhost',
          pairedAt: '2026-01-01T00:00:00Z',
        ));
        await Future<void>.delayed(Duration.zero);
        expect(cm.status, isA<StatusOnline>(),
            reason: 'precondition: manager is already Online');

        // NOW construct the repo. Without the seed, _state.connection
        // would stay at StatusNoPeer because the listener missed the
        // adopt's StatusOnline emit.
        final repo = SessionRepository(cm, SessionHistoryStore());
        await Future<void>.delayed(Duration.zero);

        expect(
          repo.current.connection,
          isA<StatusOnline>(),
          reason: 'late-construction seed must replay the missed status',
        );

        repo.dispose();
      },
    );
  });

  group('SessionRepository — task 14 — tentative-id reconciliation', () {
    test(
      'session_history with same sessionStartedAt UPGRADES tentative '
      '(cli_*) messages in place — no duplicate bubbles when Pi uses '
      'different ids for the same logical events',
      () async {
        // Sequence:
        //  1. Hand-prime the cache with one Pi-confirmed turn (local_a).
        //  2. setActivePeer loads it; _lastSessionStartedAt=Y.
        //  3. App sends "ok" → adds UserMsg(cli_N) locally → AgentDone
        //     adds AssistantMsg(cli_N). Cache now mixes confirmed +
        //     tentative messages.
        //  4. session_history arrives in APPEND branch (same Y) with
        //     full history including the second turn under Pi's id.
        //  5. Tentative messages must be REPLACED (id upgraded), not
        //     appended as duplicates.
        final store = SessionHistoryStore();
        final epk = 'epk_dup_${++_epkCounter}';
        await store.replaceFor(
          epk,
          const [
            UserMsg(id: 'local_a', text: 'hi'),
            AssistantMsg(id: 'local_a', text: 'hello'),
          ],
          sessionStartedAt: 100,
          lastTs: 200,
        );

        final s = await _setup(store: store, epkOverride: epk);
        // Confirm cache loaded.
        expect(s.repo.current.messages, hasLength(2));

        await s.repo.sendMessage('ok');
        final cliId = s.ch.sent.whereType<UserMessage>().last.id;
        expect(cliId.startsWith('cli_'), isTrue,
            reason: 'precondition: locally added msgs use cli_ prefix');
        s.ch.push(AgentChunk(inReplyTo: cliId, delta: 'beleza'));
        s.ch.push(AgentDone(inReplyTo: cliId));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(s.repo.current.messages, hasLength(4));

        // Pi pushes the canonical view of the FULL session — same
        // sessionStartedAt → append branch. Pi assigned its own ids.
        s.ch.push(SessionHistory(
          inReplyTo: 'sync',
          sessionStartedAt: 100,
          events: const [
            UserInputEvt(ts: 150, id: 'local_a', text: 'hi'),
            AgentMessageEvt(ts: 180, inReplyTo: 'local_a', text: 'hello'),
            UserInputEvt(ts: 300, id: 'local_b', text: 'ok'),
            AgentMessageEvt(ts: 350, inReplyTo: 'local_b', text: 'beleza'),
          ],
          eos: true,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final ids = s.repo.current.messages
            .map((m) => (m as dynamic).id as String)
            .toList();
        expect(ids, ['local_a', 'local_a', 'local_b', 'local_b'],
            reason: 'cli_* tentatives must be upgraded in place; no dups');
        expect(s.repo.current.messages, hasLength(4));

        s.repo.dispose();
      },
    );

    test(
      'multiple tentative messages with the same text are upgraded in '
      'order (each matches the next tentative)',
      () async {
        final store = SessionHistoryStore();
        final epk = 'epk_dup_${++_epkCounter}';
        // Prime with the sessionStartedAt pointer so we land in append.
        await store.replaceFor(
          epk,
          const <ChatMessage>[],
          sessionStartedAt: 100,
          lastTs: null,
        );

        final s = await _setup(store: store, epkOverride: epk);

        // Two tentative turns with the same user text "ok".
        await s.repo.sendMessage('ok');
        final cli1 = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(AgentChunk(inReplyTo: cli1, delta: 'r1'));
        s.ch.push(AgentDone(inReplyTo: cli1));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        await s.repo.sendMessage('ok');
        final cli2 = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(AgentChunk(inReplyTo: cli2, delta: 'r2'));
        s.ch.push(AgentDone(inReplyTo: cli2));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // 4 tentative messages now in state — all with cli_* ids
        // (this is the marker the reconciliation logic keys on).
        expect(s.repo.current.messages, hasLength(4));
        expect(
          s.repo.current.messages
              .map((m) => (m as dynamic).id as String)
              .every((id) => id.startsWith('cli_')),
          isTrue,
        );

        // Pi sends canonical history in append branch.
        s.ch.push(SessionHistory(
          inReplyTo: 'sync',
          sessionStartedAt: 100,
          events: const [
            UserInputEvt(ts: 200, id: 'X1', text: 'ok'),
            AgentMessageEvt(ts: 250, inReplyTo: 'X1', text: 'r1'),
            UserInputEvt(ts: 300, id: 'X2', text: 'ok'),
            AgentMessageEvt(ts: 350, inReplyTo: 'X2', text: 'r2'),
          ],
          eos: true,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final ids = s.repo.current.messages
            .map((m) => (m as dynamic).id as String)
            .toList();
        // First "ok" tentative → X1; second "ok" tentative → X2.
        expect(ids, ['X1', 'X1', 'X2', 'X2']);
        expect(s.repo.current.messages, hasLength(4));

        s.repo.dispose();
      },
    );
  });

  group('SessionRepository — task 14 — terminal-sent reconciliation', () {
    test(
      'real-time events stored with pi-extension turnId are reconciled '
      'when session_history brings the same logical events under a '
      'different (SDK-assigned) id — covers terminal-input duplication',
      () async {
        // Cache primes the sessionStartedAt pointer so we land in append.
        final store = SessionHistoryStore();
        final epk = 'epk_term_${++_epkCounter}';
        await store.replaceFor(
          epk,
          const <ChatMessage>[],
          sessionStartedAt: 500,
          lastTs: null,
        );

        final s = await _setup(store: store, epkOverride: epk);

        // Simulate a terminal-originated turn arriving in real-time
        // (pi-extension generates turnId="local_T" and emits the
        // user_input + AgentChunk + AgentDone all keyed off it).
        s.ch.push(UserInput(id: 'local_T', text: 'ls -la'));
        s.ch.push(AgentChunk(inReplyTo: 'local_T', delta: '3 files'));
        s.ch.push(AgentDone(inReplyTo: 'local_T'));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(s.repo.current.messages, hasLength(2));
        final preIds = s.repo.current.messages
            .map((m) => (m as dynamic).id as String)
            .toList();
        expect(preIds, ['local_T', 'local_T'],
            reason: 'precondition: real-time used the turnId verbatim');

        // session_history arrives with the SAME events but Pi gives
        // them a different id (SDK-managed). Append branch must
        // reconcile by content even though existing ids are NOT cli_*.
        s.ch.push(SessionHistory(
          inReplyTo: 'sync',
          sessionStartedAt: 500,
          events: const [
            UserInputEvt(ts: 800, id: 'sdk_42', text: 'ls -la'),
            AgentMessageEvt(ts: 900, inReplyTo: 'sdk_42', text: '3 files'),
          ],
          eos: true,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final ids = s.repo.current.messages
            .map((m) => (m as dynamic).id as String)
            .toList();
        expect(ids, ['sdk_42', 'sdk_42'],
            reason: 'real-time-turnId msgs must be upgraded in-place, '
                'not duplicated');
        expect(s.repo.current.messages, hasLength(2));

        s.repo.dispose();
      },
    );
  });

  group('SessionRepository — task 14 — real-time dedup against history', () {
    test(
      'real-time UserInput is dropped when a UserMsg with the same id is '
      'already in messages (was added by a prior session_history batch)',
      () async {
        final s = await _setup();

        // Pretend session_history loaded one user_input event.
        s.ch.push(SessionHistory(
          inReplyTo: 'sync_1',
          sessionStartedAt: 1000,
          events: const [
            UserInputEvt(ts: 1500, id: 'u_X', text: 'olá Pi'),
          ],
          eos: true,
        ));
        await Future<void>.delayed(Duration.zero);
        expect(s.repo.current.messages.whereType<UserMsg>(), hasLength(1));

        // Now Pi echoes the same user_input in real-time (e.g. multi-client
        // broadcast OR Pi forwards what it received). Without dedup we'd
        // get a duplicate bubble.
        s.ch.push(UserInput(id: 'u_X', text: 'olá Pi'));
        await Future<void>.delayed(Duration.zero);

        final users = s.repo.current.messages.whereType<UserMsg>().toList();
        expect(users, hasLength(1),
            reason: 'duplicate UserInput must be dedup-ed by id');
        expect(users.single.text, 'olá Pi');

        s.repo.dispose();
      },
    );

    test(
      'real-time ToolRequest is dropped when a ToolEvent with the same '
      'tool_call_id is already in messages (was added by session_history)',
      () async {
        final s = await _setup();

        s.ch.push(SessionHistory(
          inReplyTo: 'sync_1',
          sessionStartedAt: 1000,
          events: const [
            ToolRequestEvt(
              ts: 1500,
              toolCallId: 'tc_X',
              tool: 'bash',
              args: {'command': 'ls'},
            ),
          ],
          eos: true,
        ));
        await Future<void>.delayed(Duration.zero);
        expect(s.repo.current.messages.whereType<ToolEvent>(), hasLength(1));

        s.ch.push(ToolRequest(
          toolCallId: 'tc_X',
          tool: 'bash',
          args: const {'command': 'ls'},
        ));
        await Future<void>.delayed(Duration.zero);

        final tools = s.repo.current.messages.whereType<ToolEvent>().toList();
        expect(tools, hasLength(1),
            reason: 'duplicate ToolRequest must be dedup-ed by toolCallId');

        s.repo.dispose();
      },
    );
  });

  group('SessionRepository — plan 16 — mirror-cache wire format', () {
    test(
      'requestSync omits limit + since_ts + session_started_at — Pi '
      'decides how many events to return based on its own config, '
      'the app does NOT cap',
      () async {
        final s = await _setup();
        s.repo.requestSync();
        final sync = s.ch.sent.whereType<SessionSync>().last;
        expect(sync.limit, isNull,
            reason: 'app does not specify limit — Pi-side config rules');
        final wire = sync.toJson();
        expect(wire.containsKey('since_ts'), isFalse);
        expect(wire.containsKey('session_started_at'), isFalse);
        expect(wire.containsKey('limit'), isFalse,
            reason: 'omitted when null per toJson convention');
        expect(wire['type'], 'session_sync');
        expect(wire['id'], isA<String>());

        s.repo.dispose();
      },
    );

    test(
      'SessionHistory always REPLACES state.messages with Pi\'s view '
      '(mirror — no merge, no append)',
      () async {
        final s = await _setup();
        // Seed some local state via a sendMessage round-trip so there
        // IS something to potentially conflict.
        await s.repo.sendMessage('local question');
        final localId = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(AgentChunk(inReplyTo: localId, delta: 'local answer'));
        s.ch.push(AgentDone(inReplyTo: localId));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(s.repo.current.messages, hasLength(2),
            reason: 'precondition: local round-trip seeded 2 messages');

        // Pi sends back a totally different view.
        s.ch.push(SessionHistory(
          inReplyTo: 'sync',
          sessionStartedAt: 999,
          events: const [
            UserInputEvt(ts: 100, id: 'pi_u1', text: 'pi view'),
            AgentMessageEvt(ts: 110, inReplyTo: 'pi_u1', text: 'pi reply'),
          ],
          eos: true,
          truncated: false,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Mirror: state must EQUAL Pi\'s view exactly. Local round-trip
        // is overwritten.
        final ids = s.repo.current.messages
            .map((m) => (m as dynamic).id as String)
            .toList();
        expect(ids, ['pi_u1', 'pi_u1']);
        expect(s.repo.current.messages, hasLength(2));

        s.repo.dispose();
      },
    );

    test(
      'SessionHistory substitutes Hive cache via replaceFor (cold-'
      'reload yields the same mirrored view)',
      () async {
        final store = SessionHistoryStore();
        final epk = 'epk_mirror_${++_epkCounter}';
        // Pre-existing cache that should be wiped by the mirror.
        await store.replaceFor(
          epk,
          const [UserMsg(id: 'stale', text: 'stale')],
          sessionStartedAt: 100,
          lastTs: 200,
        );

        final s = await _setup(store: store, epkOverride: epk);
        expect(s.repo.current.messages, hasLength(1));

        s.ch.push(SessionHistory(
          inReplyTo: 'sync',
          sessionStartedAt: 500,
          events: const [
            UserInputEvt(ts: 600, id: 'fresh', text: 'fresh'),
          ],
          eos: true,
          truncated: false,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Reload from disk via a fresh repo on the same epk.
        s.repo.dispose();
        final s2 = await _setup(store: store, epkOverride: epk);
        expect(s2.repo.current.messages, hasLength(1));
        expect((s2.repo.current.messages.single as UserMsg).id, 'fresh');

        s2.repo.dispose();
      },
    );

    test(
      'truncated flag is captured but does not block UI (log-only per '
      'D1=B) — events still render as ChatReady messages',
      () async {
        final s = await _setup();
        s.ch.push(SessionHistory(
          inReplyTo: 'sync',
          sessionStartedAt: 1,
          events: const [
            UserInputEvt(ts: 10, id: 'u', text: 'q'),
            AgentMessageEvt(ts: 20, inReplyTo: 'u', text: 'a'),
          ],
          eos: true,
          truncated: true, // Pi capped at limit
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // truncated does NOT prevent the events from rendering — UI
        // contract is unchanged.
        expect(s.repo.current.messages, hasLength(2));
        expect((s.repo.current.messages[0] as UserMsg).text, 'q');
        expect((s.repo.current.messages[1] as AssistantMsg).text, 'a');

        s.repo.dispose();
      },
    );
  });
}
