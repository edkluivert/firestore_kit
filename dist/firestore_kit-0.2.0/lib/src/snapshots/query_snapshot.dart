import 'package:meta/meta.dart';

import '../types/snapshot_metadata.dart';
import 'document_snapshot.dart';

/// The type of a [DocumentChange].
enum DocumentChangeType {
  /// Indicates a new document was added to the set of documents matching the query.
  added,

  /// Indicates a document within the query was modified.
  modified,

  /// Indicates a document within the query was removed (no longer matches the query).
  removed,
}

/// A [DocumentChange] represents a change to the documents matching a query.
@immutable
class DocumentChange<T> {
  const DocumentChange({
    required this.type,
    required this.doc,
    required this.oldIndex,
    required this.newIndex,
  });

  /// The type of change that occurred (added, modified, or removed).
  final DocumentChangeType type;

  /// The document affected by this change.
  final QueryDocumentSnapshot<T> doc;

  /// The index of the changed document in the result set immediately prior to this
  /// DocumentChange (i.e. supposing that all prior DocumentChange objects and the
  /// current DocumentChange object have been applied). Is -1 for [DocumentChangeType.added] events.
  final int oldIndex;

  /// The index of the changed document in the result set immediately after this
  /// DocumentChange (i.e. supposing that all prior DocumentChange objects and the
  /// current DocumentChange object have been applied). Is -1 for [DocumentChangeType.removed] events.
  final int newIndex;

  @override
  String toString() =>
      'DocumentChange(type: $type, id: ${doc.id}, oldIndex: $oldIndex, newIndex: $newIndex)';
}

/// A [QuerySnapshot] contains zero or more [QueryDocumentSnapshot] objects representing
/// the results of a query.
class QuerySnapshot<T> {
  QuerySnapshot({
    required this.docs,
    required this.docChanges,
    required this.metadata,
  });

  /// The list of all documents in this [QuerySnapshot].
  final List<QueryDocumentSnapshot<T>> docs;

  /// The list of all changes that occurred since the last snapshot.
  final List<DocumentChange<T>> docChanges;

  /// Metadata about this snapshot.
  final SnapshotMetadata metadata;

  /// The number of documents in the [QuerySnapshot].
  int get size => docs.length;

  /// Whether the snapshot contains no documents.
  bool get isEmpty => docs.isEmpty;

  /// Whether the snapshot contains any documents.
  bool get isNotEmpty => docs.isNotEmpty;

  @override
  String toString() => 'QuerySnapshot(size: $size, changes: ${docChanges.length})';
}
