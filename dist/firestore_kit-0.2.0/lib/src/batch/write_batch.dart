import 'dart:async';
import 'package:googleapis/firestore/v1.dart' as v1;

import '../client/firestore_client.dart';
import '../codec/firestore_codec.dart';
import '../firestore.dart';
import '../references/document_reference.dart';
import '../types/options.dart';

/// A [WriteBatch] is used to perform multiple writes as a single atomic unit.
class WriteBatch {
  WriteBatch({required this.firestore});

  final FirebaseFirestore firestore;
  final List<v1.Write> _writes = [];
  final List<LocalWriteOp> _localOps = [];
  bool _committed = false;

  FirestoreClient get _client => firestore.client;

  void _checkNotCommitted() {
    if (_committed) {
      throw StateError('Cannot modify a WriteBatch that has already been committed.');
    }
  }

  /// Writes to the document referred to by the provided [DocumentReference].
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {
    _checkNotCommitted();

    final Map<String, dynamic> rawMap;
    if (document.toFirestore != null) {
      rawMap = document.toFirestore!(data, options);
    } else if (data is Map<String, dynamic>) {
      rawMap = data;
    } else if (data is Map) {
      rawMap = data.cast<String, dynamic>();
    } else {
      throw ArgumentError.value(data, 'data', 'Expected Map<String, dynamic> or registered toFirestore converter.');
    }

    _writes.addAll(FirestoreCodec.buildSetWrites(
      documentName: _client.documentPath(document.path),
      data: rawMap,
      options: options,
      databasePath: _client.databasePath,
    ));
    _localOps.add(LocalWriteOp.set(document.path, rawMap, options));
  }

  /// Updates fields in the document referred to by the provided [DocumentReference].
  void update(DocumentReference<dynamic> document, Map<Object, Object?> data) {
    _checkNotCommitted();
    final strMap = FirestoreCodec.normalizeUpdateData(data);
    _writes.addAll(FirestoreCodec.buildUpdateWrites(
      documentName: _client.documentPath(document.path),
      data: strMap,
      databasePath: _client.databasePath,
    ));
    _localOps.add(LocalWriteOp.update(document.path, strMap));
  }

  /// Deletes the document referred to by the provided [DocumentReference].
  void delete(DocumentReference<dynamic> document) {
    _checkNotCommitted();
    _writes.add(FirestoreCodec.buildDeleteWrite(_client.documentPath(document.path)));
    _localOps.add(LocalWriteOp.delete(document.path));
  }

  /// Number of write operations queued in this batch.
  int get length => _writes.length;

  /// Commits all of the writes in this write batch as a single atomic unit.
  ///
  /// When the backend is unreachable and offline queuing is enabled, the whole
  /// batch is queued and replayed atomically later.
  Future<void> commit() async {
    _checkNotCommitted();
    _committed = true;

    if (_writes.isEmpty) return;
    await firestore.commitWrites(List.unmodifiable(_writes), localOps: _localOps);
  }
}
