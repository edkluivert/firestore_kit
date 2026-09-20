import 'package:googleapis/firestore/v1.dart' as v1;
import '../codec/firestore_codec.dart';
import '../types/field_path.dart';

/// Base class for Firestore query filters.
abstract class QueryFilter {
  v1.Filter toProto({String? databasePath});
}

/// User-facing Filter builder matching cloud_firestore API.
abstract class Filter implements QueryFilter {
  /// Creates a filter on a specific field.
  factory Filter(
    Object field, {
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
    final fieldPath = field is FieldPath
        ? field
        : (field is String
            ? FieldPath(field.split('.'))
            : throw ArgumentError.value(field, 'field', 'Expected String or FieldPath'));

    final filters = <QueryFilter>[];

    if (isNull != null) {
      filters.add(FieldFilter(
        field: fieldPath,
        op: isNull ? 'EQUAL' : 'NOT_EQUAL',
        value: null,
      ));
    }
    if (isEqualTo != null) {
      filters.add(FieldFilter(field: fieldPath, op: 'EQUAL', value: isEqualTo));
    }
    if (isNotEqualTo != null) {
      filters.add(FieldFilter(field: fieldPath, op: 'NOT_EQUAL', value: isNotEqualTo));
    }
    if (isLessThan != null) {
      filters.add(FieldFilter(field: fieldPath, op: 'LESS_THAN', value: isLessThan));
    }
    if (isLessThanOrEqualTo != null) {
      filters.add(FieldFilter(field: fieldPath, op: 'LESS_THAN_OR_EQUAL', value: isLessThanOrEqualTo));
    }
    if (isGreaterThan != null) {
      filters.add(FieldFilter(field: fieldPath, op: 'GREATER_THAN', value: isGreaterThan));
    }
    if (isGreaterThanOrEqualTo != null) {
      filters.add(FieldFilter(field: fieldPath, op: 'GREATER_THAN_OR_EQUAL', value: isGreaterThanOrEqualTo));
    }
    if (arrayContains != null) {
      filters.add(FieldFilter(field: fieldPath, op: 'ARRAY_CONTAINS', value: arrayContains));
    }
    if (arrayContainsAny != null) {
      filters.add(FieldFilter(field: fieldPath, op: 'ARRAY_CONTAINS_ANY', value: arrayContainsAny.toList()));
    }
    if (whereIn != null) {
      filters.add(FieldFilter(field: fieldPath, op: 'IN', value: whereIn.toList()));
    }
    if (whereNotIn != null) {
      filters.add(FieldFilter(field: fieldPath, op: 'NOT_IN', value: whereNotIn.toList()));
    }

    if (filters.isEmpty) {
      throw ArgumentError('Filter must specify at least one condition.');
    }

    if (filters.length == 1) {
      return filters.first as Filter;
    }

    return CompositeFilter(op: 'AND', filters: filters);
  }

  /// Creates an AND filter combining multiple filters.
  factory Filter.and(
    Filter filter1,
    Filter filter2, [
    Filter? filter3,
    Filter? filter4,
    Filter? filter5,
  ]) {
    final list = [
      filter1,
      filter2,
      ?filter3,
      ?filter4,
      ?filter5,
    ];
    return CompositeFilter(op: 'AND', filters: list);
  }

  /// Creates an OR filter combining multiple filters.
  factory Filter.or(
    Filter filter1,
    Filter filter2, [
    Filter? filter3,
    Filter? filter4,
    Filter? filter5,
  ]) {
    final list = [
      filter1,
      filter2,
      ?filter3,
      ?filter4,
      ?filter5,
    ];
    return CompositeFilter(op: 'OR', filters: list);
  }
}

/// A filter on a specific field.
class FieldFilter extends QueryFilter implements Filter {
  FieldFilter({
    required this.field,
    required this.op,
    required this.value,
  });

  final FieldPath field;
  final String op; // 'EQUAL', 'NOT_EQUAL', 'LESS_THAN', etc.
  final Object? value;

  @override
  v1.Filter toProto({String? databasePath}) {
    if (value == null && op == 'EQUAL') {
      return v1.Filter(
        unaryFilter: v1.UnaryFilter(
          field: v1.FieldReference(fieldPath: field.toCanonicalPath()),
          op: 'IS_NULL',
        ),
      );
    }
    if (value == null && op == 'NOT_EQUAL') {
      return v1.Filter(
        unaryFilter: v1.UnaryFilter(
          field: v1.FieldReference(fieldPath: field.toCanonicalPath()),
          op: 'IS_NOT_NULL',
        ),
      );
    }

    return v1.Filter(
      fieldFilter: v1.FieldFilter(
        field: v1.FieldReference(fieldPath: field.toCanonicalPath()),
        op: op,
        value: FirestoreCodec.encodeValue(value, databasePath: databasePath),
      ),
    );
  }
}

/// A composite filter combining multiple filters with AND or OR.
class CompositeFilter extends QueryFilter implements Filter {
  CompositeFilter({
    required this.op, // 'AND' or 'OR'
    required this.filters,
  });

  final String op;
  final List<QueryFilter> filters;

  @override
  v1.Filter toProto({String? databasePath}) {
    return v1.Filter(
      compositeFilter: v1.CompositeFilter(
        op: op,
        filters: filters.map((f) => f.toProto(databasePath: databasePath)).toList(),
      ),
    );
  }
}

