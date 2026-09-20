import 'package:googleapis/firestore/v1.dart' as v1;
import '../types/field_path.dart';

/// Specifies the ordering for a Firestore query.
class QueryOrder {
  QueryOrder({
    required this.field,
    this.descending = false,
  });

  final FieldPath field;
  final bool descending;

  v1.Order toProto() {
    return v1.Order(
      field: v1.FieldReference(fieldPath: field.toCanonicalPath()),
      direction: descending ? 'DESCENDING' : 'ASCENDING',
    );
  }
}
