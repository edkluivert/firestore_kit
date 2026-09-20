import 'dart:async';

import '../logging/firestore_logger.dart';
import '../query/query.dart';
import '../references/document_reference.dart';
import '../snapshots/document_snapshot.dart';
import '../snapshots/query_snapshot.dart';
import 'listener_registry.dart';
import 'snapshot_stream.dart';
import 'watch_stream.dart';

/// Realtime stream manager: gRPC `Listen` push streams with automatic HTTP
/// polling fallback.
class GrpcStreamManager {
  const GrpcStreamManager._();

  /// Listens to document updates using a gRPC Listen stream, or HTTP polling
  /// when no gRPC transport is configured.
  static Stream<DocumentSnapshot<T>> createDocumentStream<T>(
    DocumentReference<T> ref, {
    Duration? pollInterval,
    bool preferGrpc = true,
  }) {
    final firestore = ref.firestore;
    final transport = firestore.grpcTransport;

    if (!preferGrpc || transport == null) {
      return SnapshotStreamManager.createDocumentStream<T>(
        ref,
        pollInterval: pollInterval,
      );
    }

    late StreamController<DocumentSnapshot<T>> controller;
    FirestoreWatch? watch;
    StreamSubscription<WatchSnapshot>? watchSub;
    StreamSubscription<DocumentSnapshot<T>>? fallbackSub;
    ActiveListener? listener;
    bool fellBack = false;

    void startFallback() {
      fellBack = true;
      firestore.logger?.log(LogLevel.warning,
          'gRPC Listen exhausted for ${ref.path}; falling back to HTTP polling');
      fallbackSub = SnapshotStreamManager.createDocumentStream<T>(
        ref,
        pollInterval: pollInterval ?? transport.options.pollInterval,
        registerListener: false,
      ).listen(
        (snapshot) {
          controller.add(snapshot);
          if (listener != null && !snapshot.metadata.isFromCache) {
            firestore.listenerRegistry.markSynced(listener!);
          }
        },
        onError: controller.addError,
        onDone: controller.close,
      );
    }

    void startWatch() {
      watch = FirestoreWatch(
        transport: transport,
        target: WatchTarget.document(firestore.client.documentPath(ref.path)),
        logger: firestore.logger,
        startPaused: !firestore.client.networkEnabled,
      );
      watchSub = watch!.stream.listen(
        (ws) async {
          final doc = ws.documents.isEmpty ? null : ws.documents.first;
          final snapshot = await ref.snapshotFromServerDocument(doc);
          if (controller.isClosed) return;
          controller.add(snapshot);
          if (listener != null) firestore.listenerRegistry.markSynced(listener!);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (error is WatchExhaustedException) {
            if (transport.options.fallbackToPolling) {
              startFallback();
            } else {
              controller.addError(error.cause, stackTrace);
            }
            return;
          }
          controller.addError(error, stackTrace);
        },
        onDone: () {
          // Terminal error or cancellation: end the public stream too, unless
          // polling took over.
          if (!fellBack && !controller.isClosed) controller.close();
        },
      );
    }

    Future<void> emitCachedIfOffline() async {
      if (firestore.client.networkEnabled) return;
      final cached = await firestore.guardedCache?.getDocument(ref.path);
      if (cached != null && !controller.isClosed) {
        controller.add(await ref.buildSnapshot(cached, exists: true, isFromCache: true));
      }
    }

    controller = StreamController<DocumentSnapshot<T>>.broadcast(
      onListen: () {
        listener = firestore.listenerRegistry.register(
          onCancel: () => controller.close(),
          onPause: () {
            watch?.pause();
            fallbackSub?.pause();
          },
          onResume: () {
            if (fellBack) {
              fallbackSub?.resume();
            } else {
              watch?.resume();
            }
          },
        );
        emitCachedIfOffline();
        startWatch();
      },
      onCancel: () {
        watchSub?.cancel();
        watch?.cancel();
        fallbackSub?.cancel();
        if (listener != null) {
          firestore.listenerRegistry.unregister(listener!);
          listener = null;
        }
      },
    );

    return controller.stream;
  }

  /// Listens to query updates using a gRPC Listen stream, or HTTP polling
  /// when no gRPC transport is configured.
  static Stream<QuerySnapshot<T>> createQueryStream<T>(
    Query<T> query, {
    Duration? pollInterval,
    bool preferGrpc = true,
  }) {
    final firestore = query.firestore;
    final transport = firestore.grpcTransport;

    if (!preferGrpc || transport == null) {
      return SnapshotStreamManager.createQueryStream<T>(
        query,
        pollInterval: pollInterval,
      );
    }

    late StreamController<QuerySnapshot<T>> controller;
    FirestoreWatch? watch;
    StreamSubscription<WatchSnapshot>? watchSub;
    StreamSubscription<QuerySnapshot<T>>? fallbackSub;
    ActiveListener? listener;
    List<QueryDocumentSnapshot<T>>? previousDocs;
    bool fellBack = false;

    void startFallback() {
      fellBack = true;
      firestore.logger?.log(LogLevel.warning,
          'gRPC Listen exhausted for query on ${query.path}; falling back to HTTP polling');
      fallbackSub = SnapshotStreamManager.createQueryStream<T>(
        query,
        pollInterval: pollInterval ?? transport.options.pollInterval,
        registerListener: false,
      ).listen(
        (snapshot) {
          previousDocs = snapshot.docs;
          controller.add(snapshot);
          if (listener != null) firestore.listenerRegistry.markSynced(listener!);
        },
        onError: controller.addError,
        onDone: controller.close,
      );
    }

    void startWatch() {
      watch = FirestoreWatch(
        transport: transport,
        target: WatchTarget.query(
          parent: firestore.client.queryParent(query.path),
          structuredQuery: query.buildStructuredQuery(),
        ),
        logger: firestore.logger,
        startPaused: !firestore.client.networkEnabled,
      );
      watchSub = watch!.stream.listen(
        (ws) async {
          final ordered = query.orderDocuments(ws.documents);
          final snapshot = await query.buildQuerySnapshot(
            ordered,
            previous: previousDocs,
            isFromCache: false,
          );
          if (controller.isClosed) return;
          previousDocs = snapshot.docs;
          controller.add(snapshot);
          if (listener != null) firestore.listenerRegistry.markSynced(listener!);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (error is WatchExhaustedException) {
            if (transport.options.fallbackToPolling) {
              startFallback();
            } else {
              controller.addError(error.cause, stackTrace);
            }
            return;
          }
          controller.addError(error, stackTrace);
        },
        onDone: () {
          if (!fellBack && !controller.isClosed) controller.close();
        },
      );
    }

    controller = StreamController<QuerySnapshot<T>>.broadcast(
      onListen: () {
        listener = firestore.listenerRegistry.register(
          onCancel: () => controller.close(),
          onPause: () {
            watch?.pause();
            fallbackSub?.pause();
          },
          onResume: () {
            if (fellBack) {
              fallbackSub?.resume();
            } else {
              watch?.resume();
            }
          },
        );
        startWatch();
      },
      onCancel: () {
        watchSub?.cancel();
        watch?.cancel();
        fallbackSub?.cancel();
        if (listener != null) {
          firestore.listenerRegistry.unregister(listener!);
          listener = null;
        }
      },
    );

    return controller.stream;
  }
}
