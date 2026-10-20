/// Plan/31 — per-session activity (#5: idle | working).
enum SessionActivity { idle, working }

/// Plan/31 — durable top-level index of sessions, so Home can query
/// cross-session (working/idle + last message) without opening every
/// per-session box. Keyed by `<epk>:<roomId>` in the `sessions_index` box.
class SessionIndexRecord {
  final String epk;
  final String roomId;
  final String displayName;
  final SessionActivity status;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final DateTime? sessionStartedAt;

  /// Opaque resume token the Pi minted for the newest history event this device
  /// holds (`session_history.cursor`). Sent back as `session_sync.since`, so a
  /// reconnect or a re-entry into the room transfers only what came after it
  /// instead of the whole mirror.
  final String? syncCursor;

  /// How many of the room's rows the last applied history reply produced. Rows
  /// past it were written from a LIVE frame, and a later delta re-delivers them
  /// in their replayed form — so they are provisional and get replaced, never
  /// appended to. Null for a cache written before this field existed.
  final int? syncedRows;

  const SessionIndexRecord({
    required this.epk,
    required this.roomId,
    this.displayName = '',
    this.status = SessionActivity.idle,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.sessionStartedAt,
    this.syncCursor,
    this.syncedRows,
  });

  String get key => '$epk:$roomId';

  SessionIndexRecord copyWith({
    String? displayName,
    SessionActivity? status,
    DateTime? lastMessageAt,
    String? lastMessagePreview,
    DateTime? sessionStartedAt,
    String? syncCursor,
    int? syncedRows,
  }) => SessionIndexRecord(
    epk: epk,
    roomId: roomId,
    displayName: displayName ?? this.displayName,
    status: status ?? this.status,
    lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
    sessionStartedAt: sessionStartedAt ?? this.sessionStartedAt,
    syncCursor: syncCursor ?? this.syncCursor,
    syncedRows: syncedRows ?? this.syncedRows,
  );

  Map<String, dynamic> toJson() => {
    'epk': epk,
    'room_id': roomId,
    'display_name': displayName,
    'status': status.name,
    'last_message_at': lastMessageAt?.millisecondsSinceEpoch,
    'last_message_preview': lastMessagePreview,
    'session_started_at': sessionStartedAt?.millisecondsSinceEpoch,
    'sync_cursor': syncCursor,
    'synced_rows': syncedRows,
  };

  factory SessionIndexRecord.fromJson(Map<String, dynamic> j) {
    DateTime? ms(dynamic v) => v == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((v as num).toInt());
    return SessionIndexRecord(
      epk: j['epk'] as String,
      roomId: j['room_id'] as String,
      displayName: (j['display_name'] as String?) ?? '',
      status: SessionActivity.values.firstWhere(
        (s) => s.name == j['status'],
        orElse: () => SessionActivity.idle,
      ),
      lastMessageAt: ms(j['last_message_at']),
      lastMessagePreview: j['last_message_preview'] as String?,
      sessionStartedAt: ms(j['session_started_at']),
      syncCursor: j['sync_cursor'] as String?,
      syncedRows: (j['synced_rows'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionIndexRecord &&
      other.epk == epk &&
      other.roomId == roomId &&
      other.displayName == displayName &&
      other.status == status &&
      other.lastMessageAt == lastMessageAt &&
      other.lastMessagePreview == lastMessagePreview &&
      other.sessionStartedAt == sessionStartedAt &&
      other.syncCursor == syncCursor &&
      other.syncedRows == syncedRows;

  @override
  int get hashCode => Object.hash(
    epk,
    roomId,
    displayName,
    status,
    lastMessageAt,
    lastMessagePreview,
    sessionStartedAt,
    syncCursor,
    syncedRows,
  );
}
