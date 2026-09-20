import 'dart:async';
import 'package:googleapis/firestore/v1.dart' as v1;

import '../client/firestore_client.dart';
import '../codec/firestore_codec.dart';
import '../codec/value_comparator.dart';
import '../exceptions.dart';
import '../firestore.dart';
import '../references/document_reference.dart';
import '../snapshots/aggregate_query.dart';
import '../snapshots/document_snapshot.dart';
import '../snapshots/query_snapshot.dart';
import '../streaming/grpc_stream_manager.dart';
import '../streaming/snapshot_stream.dart';
import '../types/field_path.dart';
import '../types/options.dart';
import '../types/snapshot_metadata.dart';
import 'cursor.dart';
import 'filter.dart';
import 'order_by.dart';

/// Type definitions for document conversion matching cloud_firestore.
typedef FromFirestore<T> = T Function(
  DocumentSnapshot<Map<String, dynamic>> snapshot,
  SnapshotOptions? options,
);

typedef ToFirestore<T> = Map<String, dynamic> Function(
  T value,
  SetOptions? options,
);

/// Options for controlling document snapshot read behavior.
class SnapshotOptions {
  const SnapshotOptions({this.serverTimestamps});
  final ServerTimestampBehavior? serverTimestamps;
}

/// Controls how server timestamps that have not yet been resolved are returned.
enum ServerTimestampBehavior { none, estimate, previous }

/// A [Query] refers to a Firestore query which you can read or listen to.
class Query<T> {
  Query({
    required this.firestore,
    required this.path,
    required this.collectionId,
    this.isCollectionGroup = false,
    List<QueryFilter>? filters,
    List<QueryOrder>? orders,
    this.startCursor,
    this.endCursor,
    this.limitCount,
    this.limitToLastCount,
    this.fromFirestore,
    this.toFirestore,
  })  : filters = filters ?? const [],
        orders = orders ?? const [];

  final FirebaseFirestore firestore;
  final String path;
  final String collectionId;
  final bool isCollectionGroup;
  final List<QueryFilter> filters;
  final List<QueryOrder> orders;
  final QueryCursor? startCursor;
  final QueryCursor? endCursor;
  final int? limitCount;
  final int? limitToLastCount;

  final FromFirestore<T>? fromFirestore;
  final ToFirestore<T>? toFirestore;

  FirestoreClient get _client => firestore.client;

  FieldPath _resolveField(Object field) {
    if (field is FieldPath) return field;
    if (field is String) return FieldPath(field.split('.'));
    throw ArgumentError.value(field, 'field', 'Expected String or FieldPath');
  }

  /// Creates and returns a new [Query] with additional filter constraints.
  ///
  /// Can take either a [Filter] object (e.g. `Filter.or(...)`), or a field name/path with filter conditions.
  Query<T> where(
    Object fieldOrFilter, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) {
    final newFilters = List<QueryFilter>.from(filters);

    if (fieldOrFilter is QueryFilter) {
      newFilters.add(fieldOrFilter);
    } else {
      final filter = Filter(
        fieldOrFilter,
        isEqualTo: isEqualTo,
        isNotEqualTo: isNotEqualTo,
        isLessThan: isLessThan,
        isLessThanOrEqualTo: isLessThanOrEqualTo,
        isGreaterThan: isGreaterThan,
        isGreaterThanOrEqualTo: isGreaterThanOrEqualTo,
        arrayContains: arrayContains,
        arrayContainsAny: arrayContainsAny,
        whereIn: whereIn,
        whereNotIn: whereNotIn,
        isNull: isNull,
      );
      newFilters.add(filter);
    }

    return _clone(filters: newFilters);
  }

  /// Creates and returns a new [Query] ordered by the specified field.
  Query<T> orderBy(Object field, {bool descending = false}) {
    final fieldPath = _resolveField(field);
    final newOrders = List<QueryOrder>.from(orders)
      ..add(QueryOrder(field: fieldPath, descending: descending));
    return _clone(orders: newOrders);
  }

  /// Creates and returns a new [Query] that only returns the first matching documents.
  Query<T> limit(int limit) {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'Limit must be positive');
    }
    return _clone(limitCount: limit, clearLimitToLast: true);
  }

  /// Creates and returns a new [Query] that only returns the last matching documents.
  ///
  /// Requires at least one `orderBy()` clause.
  Query<T> limitToLast(int limit) {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'Limit must be positive');
    }
    return _clone(limitToLastCount: limit, clearLimit: true);
  }

  /// Creates and returns a new [Query] that starts at the provided document field values.
  Query<T> startAt(Iterable<Object?> values) {
    return _clone(startCursor: QueryCursor(values: values.toList(), before: true));
  }

  /// Creates and returns a new [Query] that starts after the provided document field values.
  Query<T> startAfter(Iterable<Object?> values) {
    return _clone(startCursor: QueryCursor(values: values.toList(), before: false));
  }

  /// Creates and returns a new [Query] that ends at the provided document field values.
  Query<T> endAt(Iterable<Object?> values) {
    return _clone(endCursor: QueryCursor(values: values.toList(), before: false));
  }

  /// Creates and returns a new [Query] that ends before the provided document field values.
  Query<T> endBefore(Iterable<Object?> values) {
    return _clone(endCursor: QueryCursor(values: values.toList(), before: true));
  }

  /// Creates and returns a new [Query] that starts at the provided document (inclusive).
  ///
  /// The document must contain every field used in the query's `orderBy()`
  /// clauses. An implicit `orderBy(FieldPath.documentId)` is appended so the
  /// cursor position is unambiguous.
  Query<T> startAtDocument(DocumentSnapshot<Object?> documentSnapshot) =>
      _documentCursor(documentSnapshot, start: true, before: true);

  /// Creates and returns a new [Query] that starts after the provided document (exclusive).
  Query<T> startAfterDocument(DocumentSnapshot<Object?> documentSnapshot) =>
      _documentCursor(documentSnapshot, start: true, before: false);

  /// Creates and returns a new [Query] that ends at the provided document (inclusive).
  Query<T> endAtDocument(DocumentSnapshot<Object?> documentSnapshot) =>
      _documentCursor(documentSnapshot, start: false, before: false);

  /// Creates and returns a new [Query] that ends before the provided document (exclusive).
  Query<T> endBeforeDocument(DocumentSnapshot<Object?> documentSnapshot) =>
      _documentCursor(documentSnapshot, start: false, before: true);

  Query<T> _documentCursor(
    DocumentSnapshot<Object?> snapshot, {
    required bool start,
    required bool before,
  }) {
    if (!snapshot.exists) {
      throw ArgumentError(
          'Cannot build a query cursor from a document that does not exist (${snapshot.reference.path}).');
    }

    final newOrders = List<QueryOrder>.from(orders);
    final hasNameOrder = newOrders.any((o) => o.field == FieldPath.documentId);
    if (!hasNameOrder) {
      newOrders.add(QueryOrder(
        field: FieldPath.documentId,
        descending: newOrders.isNotEmpty && newOrders.last.descending,
      ));
    }

    final values = <Object?>[];
    for (final order in newOrders) {
      if (order.field == FieldPath.documentId) {
        values.add(snapshot.reference);
      } else {
        if (!snapshot.containsField(order.field)) {
          throw ArgumentError(
              'Document ${snapshot.reference.path} is missing the field "${order.field.toCanonicalPath()}" used in orderBy().');
        }
        values.add(snapshot.get(order.field));
      }
    }

    final cursor = QueryCursor(values: values, before: before);
    return start
        ? _clone(orders: newOrders, startCursor: cursor)
        : _clone(orders: newOrders, endCursor: cursor);
  }

  /// Changes the converter for this [Query].
  Query<R> withConverter<R>({
    required FromFirestore<R> fromFirestore,
    required ToFirestore<R> toFirestore,
  }) {
    return Query<R>(
      firestore: firestore,
      path: path,
      collectionId: collectionId,
      isCollectionGroup: isCollectionGroup,
      filters: filters,
      orders: orders,
      startCursor: startCursor,
      endCursor: endCursor,
      limitCount: limitCount,
      limitToLastCount: limitToLastCount,
      fromFirestore: fromFirestore,
      toFirestore: toFirestore,
    );
  }

  /// Returns an [AggregateQuery] that counts matching documents.
  AggregateQuery count() => aggregate(AggregateField.count());

  /// Returns an [AggregateQuery] that computes the specified aggregations.
  AggregateQuery aggregate(AggregateField field1, [AggregateField? field2, AggregateField? field3]) {
    final fieldsMap = <String, AggregateField>{};
    for (final field in [field1, field2, field3]) {
      if (field != null) fieldsMap[field.alias] = field;
    }

    return AggregateQuery(query: this, fields: fieldsMap, client: _client);
  }

  /// The `orderBy` clauses actually sent to the backend: reversed for
  /// `limitToLast()` queries, which the backend does not support natively.
  List<QueryOrder> get effectiveOrders {
    if (limitToLastCount == null) return orders;
    if (orders.isEmpty) {
      throw const FirebaseFirestoreException(
        code: 'invalid-argument',
        message: 'limitToLast() queries require specifying at least one orderBy() clause.',
      );
    }
    return orders
        .map((o) => QueryOrder(field: o.field, descending: !o.descending))
        .toList();
  }

  /// Builds the Google Cloud Firestore [v1.StructuredQuery] representation.
  v1.StructuredQuery buildStructuredQuery() {
    final structuredQuery = v1.StructuredQuery();

    // From
    structuredQuery.from = [
      v1.CollectionSelector(
        collectionId: collectionId,
        allDescendants: isCollectionGroup,
      )
    ];

    // Where
    if (filters.isNotEmpty) {
      if (filters.length == 1) {
        structuredQuery.where = filters.first.toProto(databasePath: _client.databasePath);
      } else {
        structuredQuery.where = CompositeFilter(op: 'AND', filters: filters)
            .toProto(databasePath: _client.databasePath);
      }
    }

    // OrderBy
    final sentOrders = effectiveOrders;
    if (sentOrders.isNotEmpty) {
      structuredQuery.orderBy = sentOrders.map((o) => o.toProto()).toList();
    }

    // Cursors (swapped for limitToLast, since the order is reversed)
    final start = limitToLastCount == null ? startCursor : endCursor;
    final end = limitToLastCount == null ? endCursor : startCursor;
    if (start != null) {
      structuredQuery.startAt = start.toProto(databasePath: _client.databasePath);
    }
    if (end != null) {
      structuredQuery.endAt = end.toProto(databasePath: _client.databasePath);
    }

    // Limit
    if (limitCount != null) {
      structuredQuery.limit = limitCount;
    } else if (limitToLastCount != null) {
      structuredQuery.limit = limitToLastCount;
    }

    return structuredQuery;
  }

  /// Sorts [documents] (as delivered unordered by the Listen stream) according
  /// to this query's ordering and applies its limit.
  List<v1.Document> orderDocuments(List<v1.Document> documents) {
    final sentOrders = effectiveOrders;
    final lastDescending = sentOrders.isNotEmpty && sentOrders.last.descending;

    int compare(v1.Document a, v1.Document b) {
      for (final order in sentOrders) {
        var c = FirestoreValueComparator.compare(
          FirestoreValueComparator.valueAt(a, order.field),
          FirestoreValueComparator.valueAt(b, order.field),
        );
        if (order.descending) c = -c;
        if (c != 0) return c;
      }
      var c = FirestoreValueComparator.compareReferences(a.name ?? '', b.name ?? '');
      if (lastDescending) c = -c;
      return c;
    }

    var sorted = List<v1.Document>.from(documents)..sort(compare);
    final limit = limitCount ?? limitToLastCount;
    if (limit != null && sorted.length > limit) {
      sorted = sorted.sublist(0, limit);
    }
    if (limitToLastCount != null) {
      sorted = sorted.reversed.toList();
    }
    return sorted;
  }

  /// Builds a [QueryDocumentSnapshot] for a backend [v1.Document].
  QueryDocumentSnapshot<T> documentSnapshotFromProto(
    v1.Document docProto, {
    bool isFromCache = false,
    bool hasPendingWrites = false,
  }) {
    final docName = docProto.name!;
    final docId = docName.split('/').last;
    final docRelativePath = _client.relativePath(docName);
    final docRef = DocumentReference<T>(
      firestore: firestore,
      path: docRelativePath,
      fromFirestore: fromFirestore,
      toFirestore: toFirestore,
    );
    final metadata = SnapshotMetadata(
      hasPendingWrites: hasPendingWrites,
      isFromCache: isFromCache,
    );

    final rawData = FirestoreCodec.decodeDocument(docProto);
    final converted = fromFirestore != null
        ? fromFirestore!(
            DocumentSnapshot<Map<String, dynamic>>(
              id: docId,
              reference: DocumentReference<Map<String, dynamic>>(
                firestore: firestore,
                path: docRelativePath,
              ),
              metadata: metadata,
              exists: true,
              rawData: rawData,
              convertedData: rawData,
            ),
            null,
          )
        : (rawData as T);

    return QueryDocumentSnapshot<T>(
      id: docId,
      reference: docRef,
      metadata: metadata,
      rawData: rawData,
      convertedData: converted,
    );
  }

  /// Builds a [QuerySnapshot] from ordered backend documents, computing
  /// [DocumentChange]s against [previous] when provided. Results are also
  /// written to the cache adapter.
  Future<QuerySnapshot<T>> buildQuerySnapshot(
    List<v1.Document> documents, {
    List<QueryDocumentSnapshot<T>>? previous,
    bool isFromCache = false,
  }) async {
    final cacheAdapter = firestore.guardedCache;
    final docs = <QueryDocumentSnapshot<T>>[];
    for (final docProto in documents) {
      if (docProto.name == null) continue;
      final snapshot = documentSnapshotFromProto(docProto, isFromCache: isFromCache);
      docs.add(snapshot);
      if (cacheAdapter != null && !isFromCache) {
        await cacheAdapter.putDocument(
          snapshot.reference.path,
          FirestoreCodec.decodeDocument(docProto),
        );
      }
    }

    final docChanges = previous == null
        ? docs.asMap().entries.map((e) {
            return DocumentChange<T>(
              type: DocumentChangeType.added,
              doc: e.value,
              oldIndex: -1,
              newIndex: e.key,
            );
          }).toList()
        : computeDocumentChanges(previous, docs);

    return QuerySnapshot<T>(
      docs: docs,
      docChanges: docChanges,
      metadata: SnapshotMetadata(hasPendingWrites: false, isFromCache: isFromCache),
    );
  }

  /// Executes the query and returns the results as a [QuerySnapshot].
  Future<QuerySnapshot<T>> get([GetOptions? options]) async {
    if (options?.source == Source.cache) {
      throw const FirebaseFirestoreException(
        code: 'unavailable',
        message: 'Query results cannot be served from the cache adapter; '
            'only single documents are cached. Use Source.serverAndCache or load a bundle.',
      );
    }

    final structuredQuery = buildStructuredQuery();
    final request = v1.RunQueryRequest(structuredQuery: structuredQuery);

    final parent = _client.queryParent(path);
    final response = await _client.run((api) =>
        api.projects.databases.documents.runQuery(request, parent));

    var documents = <v1.Document>[
      for (final item in response)
        if (item.document != null && item.document!.name != null) item.document!,
    ];
    if (limitToLastCount != null) {
      documents = documents.reversed.toList();
    }

    return buildQuerySnapshot(documents);
  }

  /// Returns a [Stream] of [QuerySnapshot] instances for realtime updates.
  Stream<QuerySnapshot<T>> snapshots({
    bool includeMetadataChanges = false,
    Duration? pollInterval,
  }) {
    return GrpcStreamManager.createQueryStream<T>(
      this,
      pollInterval: pollInterval,
    );
  }

  Query<T> _clone({
    List<QueryFilter>? filters,
    List<QueryOrder>? orders,
    QueryCursor? startCursor,
    QueryCursor? endCursor,
    int? limitCount,
    int? limitToLastCount,
    bool clearLimit = false,
    bool clearLimitToLast = false,
  }) {
    return Query<T>(
      firestore: firestore,
      path: path,
      collectionId: collectionId,
      isCollectionGroup: isCollectionGroup,
      filters: filters ?? this.filters,
      orders: orders ?? this.orders,
      startCursor: startCursor ?? this.startCursor,
      endCursor: endCursor ?? this.endCursor,
      limitCount: clearLimit ? null : (limitCount ?? this.limitCount),
      limitToLastCount:
          clearLimitToLast ? null : (limitToLastCount ?? this.limitToLastCount),
      fromFirestore: fromFirestore,
      toFirestore: toFirestore,
    );
  }
}
