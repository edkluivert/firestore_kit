import 'dart:convert';

import 'package:googleapis/firestore/v1.dart' as v1;

import 'generated/google/firestore/v1/document.pb.dart' as pb;
import 'generated/google/firestore/v1/query.pb.dart' as pbq;

/// Bridges the JSON (`googleapis`) representation used by the REST client and
/// the binary protobuf classes used on the gRPC stream.
///
/// Both sides speak proto3 JSON, so the conversion is lossless.
class GrpcCodec {
  const GrpcCodec._();

  /// Converts a REST [v1.StructuredQuery] into its protobuf twin.
  static pbq.StructuredQuery structuredQueryToProto(v1.StructuredQuery query) {
    return pbq.StructuredQuery()
      ..mergeFromProto3Json(_plainJson(query), ignoreUnknownFields: true);
  }

  /// Converts a protobuf [pb.Document] into the REST [v1.Document] the rest of
  /// the library decodes.
  static v1.Document documentFromProto(pb.Document document) {
    return v1.Document.fromJson(_plainJson(document.toProto3Json()!) as Map);
  }

  /// Converts a REST [v1.Document] into its protobuf twin.
  static pb.Document documentToProto(v1.Document document) {
    return pb.Document()
      ..mergeFromProto3Json(_plainJson(document), ignoreUnknownFields: true);
  }

  /// `googleapis` `toJson()` leaves nested messages as objects (relying on
  /// `jsonEncode` to recurse); round-trip through text to get plain JSON.
  static Object? _plainJson(Object value) => jsonDecode(jsonEncode(value));
}
