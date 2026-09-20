import 'dart:async';
import 'package:googleapis/firestore/v1.dart' as v1;

import '../client/firestore_client.dart';
import '../codec/firestore_codec.dart';
import '../exceptions.dart';
import '../firestore.dart';
import '../query/query.dart';
import '../snapshots/document_snapshot.dart';
import '../streaming/grpc_stream_manager.dart';
import '../types/options.dart';
import '../types/snapshot_metadata.dart';
import 'collection_reference.dart';

/// A [DocumentReference] refers to a document location in a Firestore database
/// and can be used to write, read, or listen to the location.
class DocumentReference<T> {
  DocumentReference({
    required this.firestore,
    required this.path,
    this.fromFirestore,
    this.toFirestore,
  });

  /// The [FirebaseFirestore] instance associated with this document reference.
  final FirebaseFirestore firestore;

  /// The slash-separated path to the document.
  final String path;

  final FromFirestore<T>? fromFirestore;
  final ToFirestore<T>? toFirestore;

  FirestoreClient get _client => firestore.client;

  /// The last path element of the referenced document.
  String get id => path.split('/').last;

  /// A reference to the Collection to which this [DocumentReference] belongs.
  CollectionReference<T> get parent {
    final segments = path.split('/');
    if (segments.length <= 1) {
      throw StateError('Cannot get parent of root path: $path');
    }
    final parentPath = segments.sublist(0, segments.length - 1).join('/');
    final colId = segments[segments.length - 2];

    return CollectionReference<T>(
      firestore: firestore,
      path: parentPath,
      collectionId: colId,
      fromFirestore: fromFirestore,
      toFirestore: toFirestore,
    );
  }

  /// Gets a [CollectionReference] instance for a subcollection with the given path.
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    final cleanSubPath = collectionPath.startsWith('/')
        ? collectionPath.substring(1)
        : collectionPath;
    final fullPath = '$path/$cleanSubPath';
    final colId = cleanSubPath.split('/').last;

    return CollectionReference<Map<String, dynamic>>(
      firestore: firestore,
      path: fullPath,
      collectionId: colId,
    );
  }

  /// Builds a [DocumentSnapshot] for this reference from decoded data.
  ///
  /// `hasPendingWrites` is derived from the offline write queue.
  Future<DocumentSnapshot<T>> buildSnapshot(
    Map<String, dynamic>? rawData, {
    required bool exists,
    required bool isFromCache,
  }) async {
    final hasPendingWrites = await firestore.hasPendingWritesFor(path);
    return buildSnapshotSync(
      rawData,
      exists: exists,
      isFromCache: isFromCache,
      hasPendingWrites: hasPendingWrites,
    );
  }

  /// Synchronous variant of [buildSnapshot] with explicit metadata.
  DocumentSnapshot<T> buildSnapshotSync(
    Map<String, dynamic>? rawData, {
    required bool exists,
    required bool isFromCache,
    bool hasPendingWrites = false,
  }) {
    final metadata = SnapshotMetadata(
      hasPendingWrites: hasPendingWrites,
      isFromCache: isFromCache,
    );
    final converted = (exists && rawData != null)
        ? (fromFirestore != null
            ? fromFirestore!(
                DocumentSnapshot<Map<String, dynamic>>(
                  id: id,
                  reference: DocumentReference<Map<String, dynamic>>(
                    firestore: firestore,
                    path: path,
                  ),
                  metadata: metadata,
                  exists: true,
                  rawData: rawData,
                  convertedData: rawData,
                ),
                null,
              )
            : (rawData as T))
        : null;

    return DocumentSnapshot<T>(
      id: id,
      reference: this,
      metadata: metadata,
      exists: exists,
      rawData: rawData,
      convertedData: converted,
    );
  }

  /// Builds a snapshot from a backend document (or `null` when it does not
  /// exist) and updates the cache adapter accordingly.
  Future<DocumentSnapshot<T>> snapshotFromServerDocument(v1.Document? docProto) async {
    final cacheAdapter = firestore.guardedCache;
    if (docProto == null) {
      await cacheAdapter?.deleteDocument(path);
      return buildSnapshot(null, exists: false, isFromCache: false);
    }
    final rawData = FirestoreCodec.decodeDocument(docProto);
    await cacheAdapter?.putDocument(path, rawData);
    return buildSnapshot(rawData, exists: true, isFromCache: false);
  }

  /// Reads the document referenced by this [DocumentReference].
  Future<DocumentSnapshot<T>> get([GetOptions? options]) async {
    final source = options?.source ?? Source.serverAndCache;
    final cacheAdapter = firestore.guardedCache;

    if (source == Source.cache) {
      if (cacheAdapter == null) {
        throw const FirebaseFirestoreException(
          code: 'unavailable',
          message: 'No cache adapter configured for this Firestore instance.',
        );
      }
      final cachedData = await cacheAdapter.getDocument(path);
      if (cachedData == null) {
        return buildSnapshot(null, exists: false, isFromCache: true);
      }
      return buildSnapshot(cachedData, exists: true, isFromCache: true);
    }

    final docName = _client.documentPath(path);

    try {
      final docProto = await _client.run((api) =>
          api.projects.databases.documents.get(docName));
      return snapshotFromServerDocument(docProto);
    } on FirebaseFirestoreException catch (e) {
      if (e.code == 'not-found') {
        return snapshotFromServerDocument(null);
      }

      // Fallback to cache if serverAndCache and network fails
      if (source == Source.serverAndCache && cacheAdapter != null) {
        final cachedData = await cacheAdapter.getDocument(path);
        if (cachedData != null) {
          return buildSnapshot(cachedData, exists: true, isFromCache: true);
        }
      }

      rethrow;
    }
  }

  Map<String, dynamic> _coerce(T data, SetOptions? options) {
    if (toFirestore != null) return toFirestore!(data, options);
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    throw ArgumentError.value(data, 'data',
        'Expected Map<String, dynamic> or registered toFirestore converter.');
  }

  /// Writes to the document referred to by this [DocumentReference].
  ///
  /// If the backend is unreachable and offline queuing is enabled, the write
  /// is queued, applied to the local cache, and replayed by
  /// `flushPendingWrites()` / `waitForPendingWrites()` / `enableNetwork()`.
  Future<void> set(T data, [SetOptions? options]) async {
    final rawMap = _coerce(data, options);
    final writes = FirestoreCodec.buildSetWrites(
      documentName: _client.documentPath(path),
      data: rawMap,
      options: options,
      databasePath: _client.databasePath,
    );
    await firestore.commitWrites(
      writes,
      localOps: [LocalWriteOp.set(path, rawMap, options)],
    );
  }

  /// Updates fields in the document referred to by this [DocumentReference].
  Future<void> update(Map<Object, Object?> data) async {
    final strMap = FirestoreCodec.normalizeUpdateData(data);
    final writes = FirestoreCodec.buildUpdateWrites(
      documentName: _client.documentPath(path),
      data: strMap,
      databasePath: _client.databasePath,
    );
    await firestore.commitWrites(
      writes,
      localOps: [LocalWriteOp.update(path, strMap)],
    );
  }

  /// Deletes the document referred to by this [DocumentReference].
  Future<void> delete() async {
    await firestore.commitWrites(
      [FirestoreCodec.buildDeleteWrite(_client.documentPath(path))],
      localOps: [LocalWriteOp.delete(path)],
    );
  }

  /// Returns a [Stream] of [DocumentSnapshot] instances for realtime updates.
  Stream<DocumentSnapshot<T>> snapshots({
    bool includeMetadataChanges = false,
    Duration? pollInterval,
  }) {
    return GrpcStreamManager.createDocumentStream<T>(
      this,
      pollInterval: pollInterval,
    );
  }

  /// Applies a custom data converter to this [DocumentReference].
  DocumentReference<R> withConverter<R>({
    required FromFirestore<R> fromFirestore,
    required ToFirestore<R> toFirestore,
  }) {
    return DocumentReference<R>(
      firestore: firestore,
      path: path,
      fromFirestore: fromFirestore,
      toFirestore: toFirestore,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocumentReference &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'DocumentReference($path)';
}
