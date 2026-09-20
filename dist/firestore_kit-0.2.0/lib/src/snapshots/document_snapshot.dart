import '../references/document_reference.dart';
import '../types/field_path.dart';
import '../types/snapshot_metadata.dart';

/// A [DocumentSnapshot] contains data read from a document in your Firestore database.
class DocumentSnapshot<T> {
  DocumentSnapshot({
    required this.id,
    required this.reference,
    required this.metadata,
    required this.exists,
    Map<String, dynamic>? rawData,
    T? convertedData,
  })  : _rawData = rawData,
        _convertedData = convertedData;

  /// The document ID of this snapshot.
  final String id;

  /// The [DocumentReference] for the document.
  final DocumentReference<T> reference;

  /// Metadata about this snapshot.
  final SnapshotMetadata metadata;

  /// Whether or not the document exists.
  final bool exists;

  final Map<String, dynamic>? _rawData;
  final T? _convertedData;

  /// Returns the fields of the document as a [T] or null if the document does not exist.
  T? data() => _convertedData;

  /// Retrieves a field value from the document snapshot.
  ///
  /// The [field] can be a [String] (e.g. 'title' or 'author.name') or a [FieldPath].
  dynamic get(Object field) {
    if (!exists || _rawData == null) {
      throw StateError('Cannot get field on a non-existing document snapshot.');
    }

    final List<String> segments;
    if (field is FieldPath) {
      segments = field.components;
    } else if (field is String) {
      segments = field.split('.');
    } else {
      throw ArgumentError.value(field, 'field', 'Expected String or FieldPath');
    }

    dynamic current = _rawData;
    for (final segment in segments) {
      if (current is Map<String, dynamic> && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }

  /// Alias for [get].
  dynamic operator [](Object field) => get(field);

  /// Whether the document contains [field] (a `String` dot-path or [FieldPath]),
  /// even if its value is `null`.
  bool containsField(Object field) {
    if (!exists || _rawData == null) return false;
    final List<String> segments;
    if (field is FieldPath) {
      segments = field.components;
    } else if (field is String) {
      segments = field.split('.');
    } else {
      throw ArgumentError.value(field, 'field', 'Expected String or FieldPath');
    }
    dynamic current = _rawData;
    for (final segment in segments) {
      if (current is Map<String, dynamic> && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return false;
      }
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocumentSnapshot &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          reference == other.reference &&
          exists == other.exists;

  @override
  int get hashCode => Object.hash(id, reference, exists);

  @override
  String toString() => 'DocumentSnapshot(id: $id, exists: $exists)';
}

/// A [QueryDocumentSnapshot] contains data read from a document in your Firestore database
/// as part of a query. The document is guaranteed to exist.
class QueryDocumentSnapshot<T> extends DocumentSnapshot<T> {
  QueryDocumentSnapshot({
    required super.id,
    required super.reference,
    required super.metadata,
    super.rawData,
    super.convertedData,
  }) : super(exists: true);

  @override
  T data() {
    return super.data() as T;
  }
}
