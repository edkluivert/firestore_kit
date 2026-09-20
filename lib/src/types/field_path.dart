import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// A [FieldPath] refers to a field in a document. The path may consist of a
/// single field name (referring to a top-level field in the document) or a list
/// of field names (referring to a nested field in the document).
@immutable
class FieldPath {
  /// Creates a [FieldPath] from the given [components].
  FieldPath(this.components) {
    if (components.isEmpty) {
      throw ArgumentError('FieldPath must not be empty.');
    }
  }

  /// The components that make up the field path.
  final List<String> components;

  /// A special sentinel [FieldPath] to refer to the document ID in queries.
  static final FieldPath documentId = FieldPath(const ['__name__']);

  /// Formats this [FieldPath] into a canonical string representation for Firestore queries.
  String toCanonicalPath() {
    return components.map((c) {
      if (RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(c)) {
        return c;
      }
      final escaped = c.replaceAll(r'\', r'\\').replaceAll('`', r'\`');
      return '`$escaped`';
    }).join('.');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FieldPath &&
          runtimeType == other.runtimeType &&
          const ListEquality<String>().equals(components, other.components);

  @override
  int get hashCode => const ListEquality<String>().hash(components);

  @override
  String toString() => 'FieldPath(${components.join('.')})';
}
