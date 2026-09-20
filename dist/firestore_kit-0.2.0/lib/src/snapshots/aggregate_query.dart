import 'package:collection/collection.dart';
import 'package:googleapis/firestore/v1.dart' as v1;
import 'package:meta/meta.dart';

import '../client/firestore_client.dart';
import '../query/query.dart';

/// Represents an aggregation operation on a [Query].
@immutable
abstract class AggregateField {
  const AggregateField._();

  /// Creates a count aggregation.
  static AggregateField count() => const _CountAggregateField();

  /// Creates a sum aggregation for [field].
  static AggregateField sum(String field) => _SumAggregateField(field);

  /// Creates an average aggregation for [field].
  static AggregateField average(String field) => _AverageAggregateField(field);

  /// The result alias this aggregation is reported under
  /// (`count`, `sum_<field>`, `avg_<field>`).
  String get alias;

  v1.Aggregation toProto(String alias);
}

class _CountAggregateField extends AggregateField {
  const _CountAggregateField() : super._();

  @override
  String get alias => 'count';

  @override
  v1.Aggregation toProto(String alias) {
    return v1.Aggregation(
      count: v1.Count(),
      alias: alias,
    );
  }
}

class _SumAggregateField extends AggregateField {
  const _SumAggregateField(this.field) : super._();

  final String field;

  @override
  String get alias => 'sum_$field';

  @override
  v1.Aggregation toProto(String alias) {
    return v1.Aggregation(
      sum: v1.Sum(field: v1.FieldReference(fieldPath: field)),
      alias: alias,
    );
  }
}

class _AverageAggregateField extends AggregateField {
  const _AverageAggregateField(this.field) : super._();

  final String field;

  @override
  String get alias => 'avg_$field';

  @override
  v1.Aggregation toProto(String alias) {
    return v1.Aggregation(
      avg: v1.Avg(field: v1.FieldReference(fieldPath: field)),
      alias: alias,
    );
  }
}

/// Helper top-level functions matching FlutterFire API.
AggregateField count() => AggregateField.count();
AggregateField sum(String field) => AggregateField.sum(field);
AggregateField average(String field) => AggregateField.average(field);

/// The results of executing an [AggregateQuery].
class AggregateQuerySnapshot {
  AggregateQuerySnapshot({
    required this.query,
    required Map<String, dynamic> data,
  }) : _data = data;

  final AggregateQuery query;
  final Map<String, dynamic> _data;

  /// Returns the count if a count aggregation was performed.
  int? get count => _data['count'] as int?;

  /// Returns the average value for [field].
  double? getAverage(String field) => (_data['avg_$field'] as num?)?.toDouble();

  /// Returns the sum value for [field].
  num? getSum(String field) => _data['sum_$field'] as num?;

  @override
  String toString() => 'AggregateQuerySnapshot($_data)';
}

/// A query that calculates aggregations over documents.
class AggregateQuery {
  AggregateQuery({
    required this.query,
    required this.fields,
    required FirestoreClient client,
  }) : _client = client;

  final Query<dynamic> query;
  final Map<String, AggregateField> fields;
  final FirestoreClient _client;

  /// Executes this aggregate query and returns the results.
  Future<AggregateQuerySnapshot> get() async {
    final aggregations = <v1.Aggregation>[];
    fields.forEach((alias, field) {
      aggregations.add(field.toProto(alias));
    });

    final structuredQuery = query.buildStructuredQuery();
    final request = v1.RunAggregationQueryRequest(
      structuredAggregationQuery: v1.StructuredAggregationQuery(
        structuredQuery: structuredQuery,
        aggregations: aggregations,
      ),
    );

    final parent = _client.queryParent(query.path);
    final response = await _client.run((api) =>
        api.projects.databases.documents.runAggregationQuery(request, parent));

    final resultsMap = <String, dynamic>{};
    final aggResult = response.firstOrNull?.result?.aggregateFields;
    if (aggResult != null) {
      aggResult.forEach((String key, v1.Value val) {
        if (val.integerValue != null) {
          resultsMap[key] = int.parse(val.integerValue!);
        } else if (val.doubleValue != null) {
          resultsMap[key] = val.doubleValue;
        } else if (val.nullValue != null) {
          resultsMap[key] = null;
        }
      });
    }

    return AggregateQuerySnapshot(query: this, data: resultsMap);
  }
}
