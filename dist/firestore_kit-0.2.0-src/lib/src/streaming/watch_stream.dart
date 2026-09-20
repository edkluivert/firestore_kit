import 'dart:async';
import 'dart:math' as math;

import 'package:googleapis/firestore/v1.dart' as v1;
import 'package:grpc/grpc.dart' show GrpcError;

import '../client/firestore_client.dart';
import '../exceptions.dart';
import '../grpc/firestore_grpc_transport.dart';
import '../grpc/generated/google/firestore/v1/firestore.pb.dart' as pb;
import '../grpc/grpc_codec.dart';
import '../logging/firestore_logger.dart';

/// What a [FirestoreWatch] listens to: a single document or a query.
class WatchTarget {
  WatchTarget.document(this.documentName)
      : parent = null,
        structuredQuery = null;

  WatchTarget.query({
    required this.parent,
    required this.structuredQuery,
  }) : documentName = null;

  final String? documentName;
  final String? parent;
  final v1.StructuredQuery? structuredQuery;

  bool get isDocument => documentName != null;

  /// Builds the protobuf `Target` for this watch.
  pb.Target toProto(int targetId, {List<int>? resumeToken}) {
    final target = pb.Target(targetId: targetId);
    if (isDocument) {
      target.documents = pb.Target_DocumentsTarget(documents: [documentName!]);
    } else {
      target.query = pb.Target_QueryTarget(
        parent: parent,
        structuredQuery: GrpcCodec.structuredQueryToProto(structuredQuery!),
      );
    }
    if (resumeToken != null && resumeToken.isNotEmpty) {
      target.resumeToken = resumeToken;
    }
    return target;
  }
}

/// A consistent view of the watched target as of [readTime].
class WatchSnapshot {
  WatchSnapshot({required this.documents, this.readTime});

  /// The documents currently matching the target (unordered).
  final List<v1.Document> documents;

  /// The backend read time this snapshot is consistent at.
  final DateTime? readTime;
}

/// Raised on the watch stream when reconnection attempts are exhausted.
class WatchExhaustedException implements Exception {
  WatchExhaustedException(this.cause);

  /// The last error encountered.
  final FirebaseFirestoreException cause;

  @override
  String toString() => 'WatchExhaustedException($cause)';
}

/// Implements the Firestore `Listen` (Watch) protocol on top of a gRPC
/// bidirectional stream: target bookkeeping, consistent snapshot detection,
/// resume tokens, existence-filter resyncs and reconnection with backoff.
class FirestoreWatch {
  FirestoreWatch({
    required this.transport,
    required this.target,
    this.logger,
    this.targetId = 1,
    bool startPaused = false,
  }) : _paused = startPaused;

  final FirestoreGrpcTransport transport;
  final WatchTarget target;
  final FirestoreLogger? logger;
  final int targetId;

  final Map<String, v1.Document> _docs = {};
  List<int>? _resumeToken;
  bool _current = false;
  bool _cancelled = false;
  bool _paused;
  int _attempts = 0;
  String? _lastSignature;
  Timer? _backoffTimer;

  StreamController<pb.ListenRequest>? _requests;
  StreamSubscription<pb.ListenResponse>? _responses;
  StreamController<WatchSnapshot>? _controller;

  static const Set<String> _terminalCodes = {
    'permission-denied',
    'unauthenticated',
    'invalid-argument',
    'not-found',
    'failed-precondition',
    'unimplemented',
    'out-of-range',
    'already-exists',
    'data-loss',
  };

  /// The most recent resume token received from the backend.
  List<int>? get resumeToken => _resumeToken;

  /// Whether the watch is currently paused (network disabled).
  bool get isPaused => _paused;

  /// The snapshot stream. Single-subscription.
  Stream<WatchSnapshot> get stream {
    _controller ??= StreamController<WatchSnapshot>(
      onListen: _connect,
      onCancel: cancel,
    );
    return _controller!.stream;
  }

  GrpcTransportOptions get _options => transport.options;

  void _connect() {
    if (_cancelled || _paused || _requests != null) return;

    final requests = StreamController<pb.ListenRequest>();
    _requests = requests;
    _current = false;

    logger?.log(LogLevel.debug,
        'Opening Listen stream for ${target.documentName ?? target.parent} (attempt ${_attempts + 1})');

    try {
      _responses = transport.listen(requests.stream).listen(
            _onResponse,
            onError: _onError,
            onDone: _onDone,
            cancelOnError: true,
          );
    } catch (e, st) {
      _onError(e, st);
      return;
    }

    requests.add(pb.ListenRequest(
      database: transport.firestore.client.databasePath,
      addTarget: target.toProto(targetId, resumeToken: _resumeToken),
    ));
  }

  void _onResponse(pb.ListenResponse response) {
    if (_cancelled) return;
    switch (response.whichResponseType()) {
      case pb.ListenResponse_ResponseType.targetChange:
        _handleTargetChange(response.targetChange);
        break;
      case pb.ListenResponse_ResponseType.documentChange:
        final change = response.documentChange;
        if (change.targetIds.contains(targetId)) {
          _docs[change.document.name] =
              GrpcCodec.documentFromProto(change.document);
        } else if (change.removedTargetIds.contains(targetId)) {
          _docs.remove(change.document.name);
        }
        break;
      case pb.ListenResponse_ResponseType.documentDelete:
        final delete = response.documentDelete;
        if (delete.removedTargetIds.isEmpty ||
            delete.removedTargetIds.contains(targetId)) {
          _docs.remove(delete.document);
        }
        break;
      case pb.ListenResponse_ResponseType.documentRemove:
        final remove = response.documentRemove;
        if (remove.removedTargetIds.isEmpty ||
            remove.removedTargetIds.contains(targetId)) {
          _docs.remove(remove.document);
        }
        break;
      case pb.ListenResponse_ResponseType.filter:
        final filter = response.filter;
        if (filter.targetId == targetId && filter.count != _docs.length) {
          logger?.log(LogLevel.info,
              'Existence filter mismatch (server=${filter.count}, local=${_docs.length}); resyncing target');
          _resync();
        }
        break;
      case pb.ListenResponse_ResponseType.notSet:
        break;
    }
  }

  void _handleTargetChange(pb.TargetChange change) {
    final affectsUs =
        change.targetIds.isEmpty || change.targetIds.contains(targetId);
    if (!affectsUs) return;

    if (change.resumeToken.isNotEmpty) {
      _resumeToken = List<int>.from(change.resumeToken);
    }

    switch (change.targetChangeType) {
      case pb.TargetChange_TargetChangeType.NO_CHANGE:
        // A NO_CHANGE with an empty target list is a global snapshot marker.
        if (change.targetIds.isEmpty && _current && change.hasReadTime()) {
          _emit(change.readTime.toDateTime());
        }
        break;
      case pb.TargetChange_TargetChangeType.ADD:
        break;
      case pb.TargetChange_TargetChangeType.REMOVE:
        final cause = change.hasCause() ? change.cause : null;
        final error = FirestoreClient.mapException(
          GrpcError.custom(cause?.code ?? 2, cause?.message ?? 'Target removed by server'),
        );
        _closeConnection();
        _failOrReconnect(error);
        break;
      case pb.TargetChange_TargetChangeType.CURRENT:
        _current = true;
        _attempts = 0;
        if (change.hasReadTime()) {
          _emit(change.readTime.toDateTime());
        }
        break;
      case pb.TargetChange_TargetChangeType.RESET:
        _docs.clear();
        _current = false;
        _lastSignature = null;
        break;
    }
  }

  void _emit(DateTime? readTime) {
    final controller = _controller;
    if (controller == null || controller.isClosed) return;

    final names = _docs.keys.toList()..sort();
    final signature =
        names.map((n) => '$n@${_docs[n]!.updateTime ?? ''}').join('|');
    if (_lastSignature != null && signature == _lastSignature) return;
    _lastSignature = signature;

    controller.add(WatchSnapshot(
      documents: _docs.values.toList(growable: false),
      readTime: readTime,
    ));
  }

  void _resync() {
    final requests = _requests;
    if (requests == null || requests.isClosed) return;
    _docs.clear();
    _current = false;
    _resumeToken = null;
    _lastSignature = null;
    requests.add(pb.ListenRequest(
      database: transport.firestore.client.databasePath,
      removeTarget: targetId,
    ));
    requests.add(pb.ListenRequest(
      database: transport.firestore.client.databasePath,
      addTarget: target.toProto(targetId),
    ));
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (_cancelled) return;
    _closeConnection();
    _failOrReconnect(FirestoreClient.mapException(error, stackTrace));
  }

  void _onDone() {
    if (_cancelled || _paused || _requests == null) return;
    _closeConnection();
    _failOrReconnect(const FirebaseFirestoreException(
      code: 'unavailable',
      message: 'The Listen stream was closed by the server.',
    ));
  }

  void _failOrReconnect(FirebaseFirestoreException error) {
    final controller = _controller;
    if (controller == null || controller.isClosed) return;

    if (_terminalCodes.contains(error.code)) {
      logger?.log(LogLevel.error, 'Listen stream failed permanently', error);
      controller.addError(error, error.stackTrace);
      controller.close();
      return;
    }

    _attempts++;
    if (_attempts > _options.maxReconnectAttempts) {
      logger?.log(LogLevel.error,
          'Listen stream exhausted after ${_options.maxReconnectAttempts} reconnection attempts',
          error);
      controller.addError(WatchExhaustedException(error));
      controller.close();
      return;
    }

    final backoffMs = math.min(
      _options.initialBackoff.inMilliseconds * math.pow(2, _attempts - 1),
      _options.maxBackoff.inMilliseconds.toDouble(),
    ).toInt();
    logger?.log(LogLevel.warning,
        'Listen stream error (${error.code}); reconnecting in ${backoffMs}ms', error);
    _backoffTimer?.cancel();
    _backoffTimer = Timer(Duration(milliseconds: backoffMs), _connect);
  }

  void _closeConnection() {
    _backoffTimer?.cancel();
    _backoffTimer = null;
    final responses = _responses;
    final requests = _requests;
    _responses = null;
    _requests = null;
    responses?.cancel();
    if (requests != null && !requests.isClosed) requests.close();
  }

  /// Suspends the stream, keeping the resume token for later.
  void pause() {
    if (_paused) return;
    _paused = true;
    _closeConnection();
  }

  /// Resumes a paused stream.
  void resume() {
    if (!_paused || _cancelled) return;
    _paused = false;
    _attempts = 0;
    _connect();
  }

  /// Stops the watch permanently.
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _closeConnection();
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
}
