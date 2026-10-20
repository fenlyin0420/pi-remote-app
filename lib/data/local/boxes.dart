// Plan/31 — local SSOT box layer (Hive v2).
//
// Three families of box in a NEW namespace (`rp_v2`); v1 (`session_history`,
// the blob snapshot) is abandoned without migration (#6 — re-sync from the Pi
// on first boot). The `runtime` box is VOLATILE: wiped on every boot (#3) so
// connection/presence never report stale online across restarts.
//
//   DURABLE  msgs_<epk>__<roomId>   key = seq (int)        → MessageRecord
//   DURABLE  sessions_index         key = <epk>:<roomId>   → SessionIndexRecord
//   DURABLE  drafts                 key = <epk>:<roomId>   → String (composer draft)
//   DURABLE  attachments            key = <epk>:<roomId>   → String (JSON: Plan/62
//                                                     binary attachment record)
//   VOLATILE runtime  (wiped@boot)  key = <epk>:<roomId>   → RuntimeRecord

import 'package:app/data/transport/epk_encoding.dart';
import 'package:hive_flutter/hive_flutter.dart';

const String _kNamespace = 'rp_v2';
const String _kSessionsIndex = 'sessions_index';
const String _kDrafts = 'drafts';
const String _kAttachments = 'attachments';
const String _kRuntime = 'runtime';

/// Facade over the v2 Hive boxes. A single instance is shared by the
/// [SyncService] (writer) and the read repositories (readers) so they observe
/// the same open box objects (`Hive.openBox` is idempotent).
class LocalBoxes {
  static bool _initialized = false;

  /// Per-box quiet gates, keyed by box name. STATIC on purpose: the boxes are
  /// process-wide Hive singletons, so a writer holding the gate must be seen by
  /// every reader — even one holding a different [LocalBoxes] instance.
  static final Map<String, BoxQuiet> _quiet = {};

  /// The hold/release gate for [boxName] — see [BoxQuiet].
  static BoxQuiet quietGate(String boxName) =>
      _quiet.putIfAbsent(boxName, BoxQuiet.new);

  /// Open the v2 namespace and the always-on boxes; **wipe `runtime`** before
  /// anything subscribes (#3 / Risk 2). Call once during bootstrap, before
  /// `runApp` and before any read-repo is constructed.
  static Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter(_kNamespace);
    await _openCommon();
    _initialized = true;
  }

  /// For tests: open against a custom directory. Unlike [init] this always
  /// re-opens + wipes the volatile box, so a second call simulates a restart
  /// (and lets tests assert the wipe).
  static Future<void> initForTest(String path) async {
    if (!_initialized) Hive.init(path);
    await _openCommon();
    _initialized = true;
  }

  static Future<void> _openCommon() async {
    await Hive.openBox<dynamic>(_kSessionsIndex);
    await Hive.openBox<dynamic>(_kDrafts);
    await Hive.openBox<dynamic>(_kAttachments);
    final runtime = await Hive.openBox<dynamic>(_kRuntime);
    await runtime.clear(); // VOLATILE — zero on boot (#3)
  }

  Box<dynamic> sessionsIndexBox() => Hive.box<dynamic>(_kSessionsIndex);

  /// Per-room composer drafts (unsent text, keyed by [sessionKey]).
  Box<dynamic> draftsBox() => Hive.box<dynamic>(_kDrafts);

  /// Per-room Plan/62 binary attachment records (keyed by [sessionKey]).
  Box<dynamic> attachmentsBox() => Hive.box<dynamic>(_kAttachments);

  Box<dynamic> runtimeBox() => Hive.box<dynamic>(_kRuntime);

  /// Per-session message box. Lazily opened; idempotent (returns the already
  /// open box on subsequent calls).
  Future<Box<dynamic>> msgsBox(String epk, String roomId) =>
      Hive.openBox<dynamic>(msgsBoxName(epk, roomId));

  /// Synchronous accessor for a msgs box known to be open already.
  Box<dynamic> openMsgsBox(String epk, String roomId) =>
      Hive.box<dynamic>(msgsBoxName(epk, roomId));

  bool isMsgsBoxOpen(String epk, String roomId) =>
      Hive.isBoxOpen(msgsBoxName(epk, roomId));

  /// `:` and the epk's `/`+`=` would break the on-disk filename — sanitise to
  /// the url-safe, unpadded epk form (same approach as the v1 store).
  static String msgsBoxName(String epk, String roomId) =>
      'msgs_${toAppEpk(epk)}__$roomId';

  static String sessionKey(String epk, String roomId) => '$epk:$roomId';
}

/// A hold/release counter around a box whose rows are being rewritten in bulk.
///
/// Hive emits one watch event per written key, and the read repository emits a
/// fresh list per event, so a 487-row history replay used to rebuild the chat
/// transcript 487 times — every rebuild re-running the follow-bottom logic and
/// each row's markdown/image build. That is what made a room's history twitch
/// for seconds after entering it. Readers inside a hold keep their in-memory
/// mirror current and publish ONE snapshot when the last hold is released.
class BoxQuiet {
  int _holds = 0;
  final Set<void Function()> _onRelease = {};

  bool get isQuiet => _holds > 0;

  void hold() => _holds++;

  void release() {
    if (_holds == 0) return;
    _holds--;
    if (_holds > 0) return;
    for (final cb in _onRelease.toList()) {
      cb();
    }
  }

  void onRelease(void Function() cb) => _onRelease.add(cb);

  void offRelease(void Function() cb) => _onRelease.remove(cb);
}
