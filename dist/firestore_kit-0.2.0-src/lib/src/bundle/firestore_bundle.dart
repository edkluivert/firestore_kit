import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:googleapis/firestore/v1.dart' as v1;

import '../codec/firestore_codec.dart';
import '../exceptions.dart';
import '../firestore.dart';
import '../logging/firestore_logger.dart';
import '../query/query.dart';
import '../snapshots/query_snapshot.dart';
import '../types/options.dart';
import 'load_bundle_task.dart';

/// Manages loading and querying Firestore data bundles.
///
/// A Firestore bundle is a length-prefixed sequence of JSON elements that
/// contains metadata, named queries, and pre-fetched document snapshots
/// generated server-side (for example with the Admin SDK's `bundle()` API).
///
/// ```dart
/// final db = FirebaseFirestore.instance;
/// await db.loadBundle(bundleBytes).future;
/// final snapshot = await db.namedQueryGet('recent-users');
/// ```
class FirestoreBundle {
  FirestoreBundle({required this.firestore});

  final FirebaseFirestore firestore;

  /// Metadata from the most recently loaded bundle.
  Map<String, dynamic>? bundleMetadata;

  final Map<String, _NamedQuery> _namedQueries = {};
  final Map<String, _BundledDocument> _documents = {};

  /// Named queries currently loaded.
  Iterable<String> get namedQueryNames => _namedQueries.keys;

  /// Whether a named query has been loaded.
  bool hasNamedQuery(String queryName) => _namedQueries.containsKey(queryName);

  /// Forgets everything loaded so far (used by `clearPersistence()`).
  void reset() {
    bundleMetadata = null;
    _namedQueries.clear();
    _documents.clear();
  }

  /// Loads a bundle, reporting progress as a [LoadBundleTask].
  LoadBundleTask load(Uint8List bundleData) {
    return LoadBundleTask(_load(bundleData));
  }

  Stream<LoadBundleTaskSnapshot> _load(Uint8List bundleData) async* {
    final totalBytes = bundleData.length;
    int bytesLoaded = 0;
    int documentsLoaded = 0;
    int totalDocuments = 0;

    LoadBundleTaskSnapshot progress(LoadBundleTaskState state) =>
        LoadBundleTaskSnapshot(
          taskState: state,
          bytesLoaded: bytesLoaded,
          totalBytes: totalBytes,
          documentsLoaded: documentsLoaded,
          totalDocuments: totalDocuments,
        );

    try {
      final content = utf8.decode(bundleData);
      _BundledDocumentMeta? pendingMeta;
      final loadedDocs = <_BundledDocument>[];

      for (final parsed in _parseLengthPrefixedJson(content)) {
        bytesLoaded = parsed.byteOffset;
        final element = parsed.element;

        if (element.containsKey('metadata')) {
          bundleMetadata = Map<String, dynamic>.from(element['metadata'] as Map);
          totalDocuments = (bundleMetadata!['totalDocuments'] as num?)?.toInt() ?? 0;
          yield progress(LoadBundleTaskState.running);
        } else if (element.containsKey('namedQuery')) {
          final nq = Map<String, dynamic>.from(element['namedQuery'] as Map);
          final name = nq['name'] as String;
          _namedQueries[name] = _NamedQuery(
            name: name,
            bundledQuery: nq['bundledQuery'] != null
                ? Map<String, dynamic>.from(nq['bundledQuery'] as Map)
                : null,
            readTime: nq['readTime'] as String?,
          );
        } else if (element.containsKey('documentMetadata')) {
          final dm = Map<String, dynamic>.from(element['documentMetadata'] as Map);
          pendingMeta = _BundledDocumentMeta(
            name: dm['name'] as String? ?? '',
            readTime: dm['readTime'] as String?,
            exists: dm['exists'] as bool? ?? true,
            queryNames: (dm['queries'] as List?)?.cast<String>() ?? const [],
          );
          if (!pendingMeta.exists) {
            // A deleted document: nothing to store, but it still counts.
            _documents.remove(pendingMeta.name);
            documentsLoaded++;
            pendingMeta = null;
            yield progress(LoadBundleTaskState.running);
          }
        } else if (element.containsKey('document')) {
          final docJson = Map<String, dynamic>.from(element['document'] as Map);
          final docProto = v1.Document.fromJson(docJson);
          final name = docProto.name ?? pendingMeta?.name ?? '';
          final doc = _BundledDocument(
            name: name,
            document: docProto,
            meta: pendingMeta,
          );
          _documents[name] = doc;
          loadedDocs.add(doc);
          pendingMeta = null;
          documentsLoaded++;
          yield progress(LoadBundleTaskState.running);
        }
      }

      final cacheAdapter = firestore.guardedCache;
      if (cacheAdapter != null) {
        for (final doc in loadedDocs) {
          final relativePath = firestore.client.relativePath(doc.name);
          if (relativePath.isEmpty) continue;
          await cacheAdapter.putDocument(
            relativePath,
            FirestoreCodec.decodeDocument(doc.document),
          );
        }
      }

      bytesLoaded = totalBytes;
      if (totalDocuments < documentsLoaded) totalDocuments = documentsLoaded;
      firestore.logger?.log(LogLevel.info,
          'Loaded bundle: $documentsLoaded documents, ${_namedQueries.length} named queries');
      yield progress(LoadBundleTaskState.success);
    } catch (e, st) {
      firestore.logger?.log(LogLevel.error, 'Failed to load bundle', e, st);
      yield progress(LoadBundleTaskState.error);
      throw FirebaseFirestoreException(
        code: 'invalid-argument',
        message: 'Failed to load bundle: $e',
        stackTrace: st,
      );
    }
  }

  /// Retrieves the results of a previously loaded named query.
  ///
  /// With [Source.cache] the bundled documents are returned. Otherwise the
  /// bundled query is executed against the backend, falling back to the
  /// bundled documents when the backend is unreachable (for
  /// [Source.serverAndCache]).
  Future<QuerySnapshot<T>> namedQueryGet<T>(
    String queryName, {
    GetOptions options = const GetOptions(),
    FromFirestore<T>? fromFirestore,
    ToFirestore<T>? toFirestore,
  }) async {
    final namedQuery = _namedQueries[queryName];
    if (namedQuery == null) {
      throw FirebaseFirestoreException(
        code: 'not-found',
        message: 'Named query "$queryName" not found. Did you call loadBundle() first?',
      );
    }

    final query = _queryFor(namedQuery, fromFirestore, toFirestore);

    if (options.source == Source.cache) {
      return _fromBundle(queryName, namedQuery, query);
    }

    try {
      return await _fromServer(namedQuery, query);
    } on FirebaseFirestoreException catch (e) {
      if (options.source == Source.serverAndCache && e.isOffline) {
        return _fromBundle(queryName, namedQuery, query);
      }
      rethrow;
    }
  }

  Query<T> _queryFor<T>(
    _NamedQuery namedQuery,
    FromFirestore<T>? fromFirestore,
    ToFirestore<T>? toFirestore,
  ) {
    final bundled = namedQuery.bundledQuery ?? const <String, dynamic>{};
    final structured = bundled['structuredQuery'] is Map
        ? v1.StructuredQuery.fromJson(
            Map<String, dynamic>.from(bundled['structuredQuery'] as Map))
        : v1.StructuredQuery();
    final from = structured.from?.isNotEmpty == true ? structured.from!.first : null;
    final parentFull = bundled['parent'] as String? ?? '';
    final parentRelative = firestore.client.relativePath(parentFull);
    final collectionId = from?.collectionId ?? '';
    final isGroup = from?.allDescendants ?? false;
    final path = parentRelative.isEmpty
        ? collectionId
        : (isGroup ? parentRelative : '$parentRelative/$collectionId');

    return Query<T>(
      firestore: firestore,
      path: isGroup && parentRelative.isEmpty ? '' : path,
      collectionId: collectionId,
      isCollectionGroup: isGroup,
      fromFirestore: fromFirestore,
      toFirestore: toFirestore,
    );
  }

  Future<QuerySnapshot<T>> _fromBundle<T>(
    String queryName,
    _NamedQuery namedQuery,
    Query<T> query,
  ) async {
    final docs = <v1.Document>[
      for (final doc in _documents.values)
        if (doc.meta?.queryNames.contains(queryName) ?? false) doc.document,
    ];
    // Bundled documents are unordered; apply the bundled query's ordering.
    final ordered = _orderBundled(namedQuery, docs);
    return query.buildQuerySnapshot(ordered, isFromCache: true);
  }

  Future<QuerySnapshot<T>> _fromServer<T>(
    _NamedQuery namedQuery,
    Query<T> query,
  ) async {
    final bundled = namedQuery.bundledQuery ?? const <String, dynamic>{};
    final structured = bundled['structuredQuery'] is Map
        ? v1.StructuredQuery.fromJson(
            Map<String, dynamic>.from(bundled['structuredQuery'] as Map))
        : v1.StructuredQuery();
    final parent = bundled['parent'] as String? ?? firestore.client.queryParent('');
    final client = firestore.client;

    final response = await client.run((api) => api.projects.databases.documents
        .runQuery(v1.RunQueryRequest(structuredQuery: structured), parent));

    var documents = <v1.Document>[
      for (final item in response)
        if (item.document != null && item.document!.name != null) item.document!,
    ];
    if (bundled['limitType'] == 'LAST') {
      documents = documents.reversed.toList();
    }
    return query.buildQuerySnapshot(documents);
  }

  List<v1.Document> _orderBundled(_NamedQuery namedQuery, List<v1.Document> docs) {
    final bundled = namedQuery.bundledQuery ?? const <String, dynamic>{};
    if (bundled['structuredQuery'] is! Map) return docs;
    final structured = v1.StructuredQuery.fromJson(
        Map<String, dynamic>.from(bundled['structuredQuery'] as Map));
    final orders = structured.orderBy ?? const [];
    if (orders.isEmpty) return docs;

    final probe = Query<Map<String, dynamic>>(
      firestore: firestore,
      path: '',
      collectionId: structured.from?.firstOrNull?.collectionId ?? '',
    );
    var ordered = probe;
    for (final o in orders) {
      final fp = o.field?.fieldPath;
      if (fp == null) continue;
      ordered = ordered.orderBy(fp, descending: o.direction == 'DESCENDING');
    }
    final sorted = ordered.orderDocuments(docs);
    return bundled['limitType'] == 'LAST' ? sorted.reversed.toList() : sorted;
  }

  /// Parses a bundle content string into length-prefixed JSON elements.
  Iterable<_ParsedElement> _parseLengthPrefixedJson(String content) sync* {
    int pos = 0;
    int byteOffset = 0;

    while (pos < content.length) {
      final lengthStart = pos;
      while (pos < content.length &&
          content.codeUnitAt(pos) >= 0x30 &&
          content.codeUnitAt(pos) <= 0x39) {
        pos++;
      }
      if (pos == lengthStart) break;

      final length = int.tryParse(content.substring(lengthStart, pos));
      if (length == null) {
        throw FormatException('Invalid bundle element length at byte $byteOffset');
      }

      // Lengths are in UTF-8 bytes; walk code units until that many bytes are consumed.
      final jsonStart = pos;
      int bytes = 0;
      while (pos < content.length && bytes < length) {
        final unit = content.codeUnitAt(pos);
        if (unit < 0x80) {
          bytes += 1;
        } else if (unit < 0x800) {
          bytes += 2;
        } else if (unit >= 0xD800 && unit <= 0xDBFF) {
          bytes += 4;
          pos++; // low surrogate
        } else {
          bytes += 3;
        }
        pos++;
      }
      if (bytes < length) {
        throw FormatException(
            'Truncated bundle: element at byte $byteOffset declares $length bytes but only $bytes remain');
      }

      final jsonStr = content.substring(jsonStart, pos);
      byteOffset += (pos - lengthStart) + (length - jsonStr.length);

      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) {
        throw FormatException('Bundle element at byte $byteOffset is not a JSON object');
      }
      yield _ParsedElement(decoded, byteOffset);
    }
  }
}

extension<E> on List<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

class _ParsedElement {
  _ParsedElement(this.element, this.byteOffset);
  final Map<String, dynamic> element;
  final int byteOffset;
}

class _NamedQuery {
  _NamedQuery({
    required this.name,
    this.bundledQuery,
    this.readTime,
  });

  final String name;
  final Map<String, dynamic>? bundledQuery;
  final String? readTime;
}

class _BundledDocumentMeta {
  _BundledDocumentMeta({
    required this.name,
    this.readTime,
    required this.exists,
    required this.queryNames,
  });

  final String name;
  final String? readTime;
  final bool exists;
  final List<String> queryNames;
}

class _BundledDocument {
  _BundledDocument({
    required this.name,
    required this.document,
    this.meta,
  });

  final String name;
  final v1.Document document;
  final _BundledDocumentMeta? meta;
}
