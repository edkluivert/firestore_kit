import 'dart:math';

import '../query/query.dart';
import 'document_reference.dart';

final Random _random = Random.secure();
const String _autoIdChars =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/// Generates a 20-character unique Firestore document ID.
String generateAutoId() {
  final buffer = StringBuffer();
  for (int i = 0; i < 20; i++) {
    buffer.write(_autoIdChars[_random.nextInt(_autoIdChars.length)]);
  }
  return buffer.toString();
}

/// A [CollectionReference] object can be used for adding documents, getting
/// [DocumentReference] instances, and querying for documents.
class CollectionReference<T> extends Query<T> {
  CollectionReference({
    required super.firestore,
    required super.path,
    required super.collectionId,
    super.fromFirestore,
    super.toFirestore,
  });

  /// The collection's identifier.
  String get id => collectionId;

  /// A reference to the containing [DocumentReference] if this is a subcollection, or null if root.
  DocumentReference<Map<String, dynamic>>? get parent {
    final segments = path.split('/');
    if (segments.length <= 1) return null;

    final parentDocPath = segments.sublist(0, segments.length - 1).join('/');
    return DocumentReference<Map<String, dynamic>>(
      firestore: firestore,
      path: parentDocPath,
    );
  }

  /// Returns a [DocumentReference] pointing to a new document with an auto-generated ID
  /// or a specific document ID.
  DocumentReference<T> doc([String? path]) {
    final effectiveDocId = path ?? generateAutoId();
    final cleanDocId = effectiveDocId.startsWith('/')
        ? effectiveDocId.substring(1)
        : effectiveDocId;

    return DocumentReference<T>(
      firestore: firestore,
      path: '${this.path}/$cleanDocId',
      fromFirestore: fromFirestore,
      toFirestore: toFirestore,
    );
  }

  /// Adds a new document to this collection with the specified data,
  /// assigning it a document ID automatically.
  Future<DocumentReference<T>> add(T data) async {
    final docRef = doc();
    await docRef.set(data);
    return docRef;
  }

  @override
  CollectionReference<R> withConverter<R>({
    required FromFirestore<R> fromFirestore,
    required ToFirestore<R> toFirestore,
  }) {
    return CollectionReference<R>(
      firestore: firestore,
      path: path,
      collectionId: collectionId,
      fromFirestore: fromFirestore,
      toFirestore: toFirestore,
    );
  }

  @override
  String toString() => 'CollectionReference($path)';
}
