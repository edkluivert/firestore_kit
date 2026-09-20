import 'dart:async';
import 'package:googleapis/firestore/v1.dart' as v1;

import '../client/firestore_client.dart';
import '../codec/firestore_codec.dart';
import '../firestore.dart';
import '../references/document_reference.dart';
import '../snapshots/document_snapshot.dart';
import '../types/options.dart';

/// Function signature for transaction update functions.
typedef TransactionHandler<T> = Future<T> Function(Transaction transaction);

/// A reference to a transaction.
///
/// The [Transaction] object given to a [TransactionHandler] is used to read and
/// write data within the transaction.
class Transaction {
  Transaction({
    required this.firestore,
    required this.transactionToken,
  });

  final FirebaseFirestore firestore;
  final String transactionToken;
  final List<v1.Write> _writes = [];

  FirestoreClient get _client => firestore.client;

  /// Reads the document referenced by the provided [DocumentReference]
  /// within this transaction (using `batchGet`, like the native SDKs).
  Future<DocumentSnapshot<T>> get<T>(DocumentReference<T> documentReference) async {
    final docName = _client.documentPath(documentReference.path);
    final request = v1.BatchGetDocumentsRequest(
      documents: [docName],
      transaction: transactionToken,
    );
    final responses = await _client.run((api) =>
        api.projects.databases.documents.batchGet(request, _client.databasePath));

    for (final response in responses) {
      final found = response.found;
      if (found != null && found.name == docName) {
        final rawData = FirestoreCodec.decodeDocument(found);
        return documentReference.buildSnapshotSync(rawData, exists: true, isFromCache: false);
      }
    }
    return documentReference.buildSnapshotSync(null, exists: false, isFromCache: false);
  }

  /// Writes to the document referred to by the provided [DocumentReference].
  Transaction set<T>(DocumentReference<T> documentReference, T data, [SetOptions? options]) {
    final Map<String, dynamic> rawMap;
    if (documentReference.toFirestore != null) {
      rawMap = documentReference.toFirestore!(data, options);
    } else if (data is Map<String, dynamic>) {
      rawMap = data;
    } else if (data is Map) {
      rawMap = data.cast<String, dynamic>();
    } else {
      throw ArgumentError.value(data, 'data', 'Expected Map<String, dynamic> or registered toFirestore converter.');
    }

    _writes.addAll(FirestoreCodec.buildSetWrites(
      documentName: _client.documentPath(documentReference.path),
      data: rawMap,
      options: options,
      databasePath: _client.databasePath,
    ));
    return this;
  }

  /// Updates fields in the document referred to by the provided [DocumentReference].
  Transaction update(DocumentReference<dynamic> documentReference, Map<Object, Object?> data) {
    _writes.addAll(FirestoreCodec.buildUpdateWrites(
      documentName: _client.documentPath(documentReference.path),
      data: FirestoreCodec.normalizeUpdateData(data),
      databasePath: _client.databasePath,
    ));
    return this;
  }

  /// Deletes the document referred to by the provided [DocumentReference].
  Transaction delete(DocumentReference<dynamic> documentReference) {
    _writes.add(FirestoreCodec.buildDeleteWrite(_client.documentPath(documentReference.path)));
    return this;
  }

  /// Commits the transaction writes. Transactions are never queued offline.
  Future<void> commit() async {
    await _client.commit(_writes, transaction: transactionToken);
  }
}
