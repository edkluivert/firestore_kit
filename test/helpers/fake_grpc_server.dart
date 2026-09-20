import 'dart:async';

import 'package:firestore_kit/src/grpc/generated/google/firestore/v1/document.pb.dart' as pb;
import 'package:firestore_kit/src/grpc/generated/google/firestore/v1/firestore.pb.dart' as pb;
import 'package:firestore_kit/src/grpc/generated/google/firestore/v1/firestore.pbgrpc.dart' as pbgrpc;
import 'package:firestore_kit/src/grpc/generated/google/firestore/v1/write.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart' as wkt;

/// A single Listen connection accepted by [FakeFirestoreService].
class FakeListenConnection {
  FakeListenConnection(this.index, this.metadata);

  final int index;
  final Map<String, String>? metadata;
  final StreamController<pb.ListenResponse> out = StreamController<pb.ListenResponse>();
  final List<pb.ListenRequest> requests = [];
  final StreamController<pb.ListenRequest> _requestEvents =
      StreamController<pb.ListenRequest>.broadcast();
  final Completer<void> clientClosed = Completer<void>();
  int _consumed = 0;

  /// Returns the next request from the client on this connection, replaying
  /// requests that arrived before this was called.
  Future<pb.ListenRequest> nextRequest() async {
    if (requests.length > _consumed) return requests[_consumed++];
    final request = await _requestEvents.stream.first;
    _consumed++;
    return request;
  }

  /// Pushes a response to the client.
  void send(pb.ListenResponse response) => out.add(response);

  /// Fails the connection with [error].
  void fail(GrpcError error) {
    out.addError(error);
    out.close();
  }

  /// Ends the connection normally.
  void close() => out.close();
}

/// An in-process fake of the Firestore gRPC service that only implements
/// `Listen`; tests script the responses per connection.
class FakeFirestoreService extends pbgrpc.FirestoreServiceBase {
  final List<FakeListenConnection> connections = [];
  final StreamController<FakeListenConnection> _connectionEvents =
      StreamController<FakeListenConnection>.broadcast();
  int _consumedConnections = 0;

  /// Returns the next Listen connection, replaying connections opened before
  /// this was called.
  Future<FakeListenConnection> nextConnection() async {
    if (connections.length > _consumedConnections) {
      return connections[_consumedConnections++];
    }
    final conn = await _connectionEvents.stream.first;
    _consumedConnections++;
    return conn;
  }

  @override
  Stream<pb.ListenResponse> listen(
      ServiceCall call, Stream<pb.ListenRequest> request) {
    final conn = FakeListenConnection(connections.length, call.clientMetadata);
    connections.add(conn);
    request.listen(
      (r) {
        conn.requests.add(r);
        conn._requestEvents.add(r);
      },
      onDone: () {
        if (!conn.clientClosed.isCompleted) conn.clientClosed.complete();
      },
      onError: (Object _) {
        if (!conn.clientClosed.isCompleted) conn.clientClosed.complete();
      },
    );
    // Let the request subscription attach before announcing the connection.
    scheduleMicrotask(() => _connectionEvents.add(conn));
    return conn.out.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// Starts [service] on an ephemeral localhost port.
Future<Server> startFakeGrpcServer(FakeFirestoreService service) async {
  final server = Server.create(services: [service]);
  await server.serve(address: 'localhost', port: 0);
  return server;
}

// ---------------------------------------------------------------------------
// Response builders
// ---------------------------------------------------------------------------

pb.ListenResponse targetChange(
  pb.TargetChange_TargetChangeType type, {
  List<int> targetIds = const [],
  List<int>? resumeToken,
  bool withReadTime = true,
}) {
  final change = pb.TargetChange(targetChangeType: type, targetIds: targetIds);
  if (resumeToken != null) change.resumeToken = resumeToken;
  if (withReadTime) change.readTime = wkt.Timestamp.fromDateTime(DateTime.now());
  return pb.ListenResponse(targetChange: change);
}

pb.ListenResponse added({List<int> targetIds = const [1]}) =>
    targetChange(pb.TargetChange_TargetChangeType.ADD,
        targetIds: targetIds, withReadTime: false);

pb.ListenResponse current({List<int> targetIds = const [1], List<int>? resumeToken}) =>
    targetChange(pb.TargetChange_TargetChangeType.CURRENT,
        targetIds: targetIds, resumeToken: resumeToken);

pb.ListenResponse noChange({List<int>? resumeToken}) =>
    targetChange(pb.TargetChange_TargetChangeType.NO_CHANGE, resumeToken: resumeToken);

pb.ListenResponse reset({List<int> targetIds = const [1]}) =>
    targetChange(pb.TargetChange_TargetChangeType.RESET,
        targetIds: targetIds, withReadTime: false);

pb.Document document(String name, Map<String, pb.Value> fields, {int version = 1}) {
  return pb.Document(
    name: name,
    fields: fields.entries,
    updateTime: wkt.Timestamp(seconds: Int64(1700000000 + version), nanos: 0),
    createTime: wkt.Timestamp(seconds: Int64(1700000000), nanos: 0),
  );
}

pb.ListenResponse documentChange(pb.Document doc, {List<int> targetIds = const [1], List<int> removedTargetIds = const []}) {
  return pb.ListenResponse(
    documentChange: pb.DocumentChange(
      document: doc,
      targetIds: targetIds,
      removedTargetIds: removedTargetIds,
    ),
  );
}

pb.ListenResponse documentDelete(String name, {List<int> removedTargetIds = const [1]}) {
  return pb.ListenResponse(
    documentDelete: pb.DocumentDelete(document: name, removedTargetIds: removedTargetIds),
  );
}

pb.ListenResponse documentRemove(String name, {List<int> removedTargetIds = const [1]}) {
  return pb.ListenResponse(
    documentRemove: pb.DocumentRemove(document: name, removedTargetIds: removedTargetIds),
  );
}

pb.ListenResponse existenceFilter(int count, {int targetId = 1}) {
  return pb.ListenResponse(
    filter: pb.ExistenceFilter(targetId: targetId, count: count),
  );
}

pb.Value str(String v) => pb.Value(stringValue: v);
pb.Value integer(int v) => pb.Value(integerValue: Int64(v));
pb.Value boolean(bool v) => pb.Value(booleanValue: v);
