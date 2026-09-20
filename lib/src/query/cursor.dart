import 'package:googleapis/firestore/v1.dart' as v1;

import '../codec/firestore_codec.dart';

/// A bound on a query (startAt, startAfter, endAt, endBefore).
class QueryCursor {
  QueryCursor({
    required this.values,
    required this.before,
  });

  final List<Object?> values;
  final bool before;

  v1.Cursor toProto({String? databasePath}) {
    return v1.Cursor(
      before: before,
      values: values.map((v) => FirestoreCodec.encodeValue(v, databasePath: databasePath)).toList(),
    );
  }
}
