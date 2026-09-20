import 'dart:async';

import 'package:googleapis/firestore/v1.dart' as v1;

import '../cache/cache_adapter.dart';

/// Represents a queued offline mutation.
///
/// New writes are stored as the exact Firestore `Write` protos (in JSON form)
/// that failed to commit, so transforms, merge masks and preconditions are
/// replayed faithfully. The legacy `type`/`path`/`data` shape is still accepted
/// for hand-built entries.
class PendingWrite {
  PendingWrite({
    required this.id,
    required this.type, // 'set', 'update', 'delete', 'batch'
    required this.path,
    this.data,
    this.options,
    this.writes,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final String id;
  final String type;
  final String path;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? options;

  /// Serialized `Write` protos (`v1.Write.toJson()`), when available.
  final List<Map<String, dynamic>>? writes;

  final DateTime createdAt;

  /// Whether this entry carries replayable `Write` protos.
  bool get hasProtoWrites => writes != null && writes!.isNotEmpty;

  /// Decodes [writes] back into [v1.Write] objects.
  List<v1.Write> toProtoWrites() =>
      (writes ?? const []).map(v1.Write.fromJson).toList();

  /// Document paths (relative to `/documents/`) touched by this entry.
  List<String> get touchedPaths {
    if (!hasProtoWrites) return [path];
    final paths = <String>{};
    for (final w in toProtoWrites()) {
      final name = w.update?.name ?? w.delete ?? w.transform?.document;
      if (name == null) continue;
      const marker = '/documents/';
      final idx = name.indexOf(marker);
      paths.add(idx == -1 ? name : name.substring(idx + marker.length));
    }
    return paths.toList();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'path': path,
        'createdAt': createdAt.toIso8601String(),
        if (data != null) 'data': data,
        if (options != null) 'options': options,
        if (writes != null) 'writes': writes,
      };

  factory PendingWrite.fromJson(Map<String, dynamic> json) => PendingWrite(
        id: json['id'] as String,
        type: json['type'] as String,
        path: json['path'] as String,
        data: json['data'] != null
            ? Map<String, dynamic>.from(json['data'] as Map)
            : null,
        options: json['options'] != null
            ? Map<String, dynamic>.from(json['options'] as Map)
            : null,
        writes: json['writes'] != null
            ? (json['writes'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList()
            : null,
        createdAt: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt'] as String)
            : null,
      );
}

/// Manages offline mutation queue persistence and flushing.
///
/// When a [cacheAdapter] is provided the queue survives restarts; otherwise
/// it lives in memory for the lifetime of the Firestore instance.
class OfflineWriteQueueManager {
  OfflineWriteQueueManager({this.cacheAdapter});

  final FirestoreCacheAdapter? cacheAdapter;
  static const String _queueStorageKey = '__firestore_pending_writes__';

  final List<PendingWrite> _memoryQueue = [];
  int _sequence = 0;

  /// Generates a unique, monotonically increasing write id.
  String nextId() =>
      'w${DateTime.now().microsecondsSinceEpoch}_${(_sequence++).toString().padLeft(4, '0')}';

  /// Retrieves all pending writes in insertion order.
  Future<List<PendingWrite>> getPendingWrites() async {
    final adapter = cacheAdapter;
    if (adapter == null) return List.unmodifiable(_memoryQueue);

    final raw = await adapter.getDocument(_queueStorageKey);
    if (raw == null || raw['writes'] is! List) return [];
    final list = raw['writes'] as List;
    return list
        .map((e) => PendingWrite.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Number of pending writes.
  Future<int> get length async => (await getPendingWrites()).length;

  /// Whether any pending write touches [documentPath].
  Future<bool> hasPendingWritesFor(String documentPath) async {
    final pending = await getPendingWrites();
    return pending.any((w) => w.touchedPaths.contains(documentPath));
  }

  /// Adds a write operation to the pending queue.
  Future<void> enqueueWrite(PendingWrite write) async {
    if (cacheAdapter == null) {
      _memoryQueue.add(write);
      return;
    }
    final pending = await getPendingWrites();
    pending.add(write);
    await _saveQueue(pending);
  }

  /// Removes a write operation from the queue by [writeId].
  Future<void> removeWrite(String writeId) async {
    if (cacheAdapter == null) {
      _memoryQueue.removeWhere((w) => w.id == writeId);
      return;
    }
    final pending = await getPendingWrites();
    pending.removeWhere((w) => w.id == writeId);
    await _saveQueue(pending);
  }

  /// Clears all queued pending writes.
  Future<void> clearQueue() async {
    _memoryQueue.clear();
    await cacheAdapter?.deleteDocument(_queueStorageKey);
  }

  /// Moves every pending write into [other] (used when persistence is enabled
  /// after writes were already queued in memory).
  Future<void> migrateTo(OfflineWriteQueueManager other) async {
    final pending = await getPendingWrites();
    for (final w in pending) {
      await other.enqueueWrite(w);
    }
    await clearQueue();
  }

  Future<void> _saveQueue(List<PendingWrite> pending) async {
    await cacheAdapter!.putDocument(_queueStorageKey, {
      'writes': pending.map((w) => w.toJson()).toList(),
    });
  }
}
