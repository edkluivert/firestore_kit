import 'dart:async';

import 'package:collection/collection.dart';

import '../logging/firestore_logger.dart';
import '../query/query.dart';
import '../references/document_reference.dart';
import '../snapshots/document_snapshot.dart';
import '../snapshots/query_snapshot.dart';
import 'listener_registry.dart';

const _collectionEquality = DeepCollectionEquality();

/// Manages HTTP-polling realtime snapshot streams for documents and queries.
///
/// Used when no gRPC transport is configured, and as the fallback when a gRPC
/// Listen stream is exhausted.
class SnapshotStreamManager {
  const SnapshotStreamManager._();

  /// Creates a realtime [Stream] for a [DocumentReference].
  static Stream<DocumentSnapshot<T>> createDocumentStream<T>(
    DocumentReference<T> ref, {
    Duration? pollInterval,
    bool registerListener = true,
  }) {
    final firestore = ref.firestore;
    final effectiveInterval = pollInterval ?? const Duration(seconds: 2);
    late StreamController<DocumentSnapshot<T>> controller;
    Timer? timer;
    bool hasEmittedFirst = false;
    DocumentSnapshot<T>? lastSnapshot;
    ActiveListener? listener;
    bool inFlight = false;

    Future<void> checkUpdate() async {
      if (controller.isClosed || inFlight) return;
      if (!firestore.client.networkEnabled) return;
      inFlight = true;
      try {
        final snapshot = await ref.get();
        if (controller.isClosed) return;

        final docChanged = !hasEmittedFirst ||
            snapshot.exists != lastSnapshot?.exists ||
            !_collectionEquality.equals(snapshot.data(), lastSnapshot?.data());

        if (docChanged) {
          hasEmittedFirst = true;
          lastSnapshot = snapshot;
          controller.add(snapshot);
        }
        if (listener != null && !snapshot.metadata.isFromCache) {
          firestore.listenerRegistry.markSynced(listener!);
        }
      } catch (e, st) {
        if (!controller.isClosed) {
          controller.addError(e, st);
        }
      } finally {
        inFlight = false;
      }
    }

    void startTimer() {
      timer?.cancel();
      checkUpdate();
      timer = Timer.periodic(effectiveInterval, (_) => checkUpdate());
    }

    controller = StreamController<DocumentSnapshot<T>>.broadcast(
      onListen: () {
        if (registerListener) {
          listener = firestore.listenerRegistry.register(
            onCancel: () => controller.close(),
            onPause: () => timer?.cancel(),
            onResume: startTimer,
          );
        }
        startTimer();
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
        if (listener != null) {
          firestore.listenerRegistry.unregister(listener!);
          listener = null;
        }
      },
    );

    return controller.stream;
  }

  /// Creates a realtime [Stream] for a [Query].
  static Stream<QuerySnapshot<T>> createQueryStream<T>(
    Query<T> query, {
    Duration? pollInterval,
    bool registerListener = true,
  }) {
    final firestore = query.firestore;
    final effectiveInterval = pollInterval ?? const Duration(seconds: 3);
    late StreamController<QuerySnapshot<T>> controller;
    Timer? timer;
    List<QueryDocumentSnapshot<T>>? previousDocs;
    ActiveListener? listener;
    bool inFlight = false;

    Future<void> checkUpdate() async {
      if (controller.isClosed || inFlight) return;
      if (!firestore.client.networkEnabled) return;
      inFlight = true;
      try {
        final snapshot = await query.get();
        if (controller.isClosed) return;

        if (previousDocs == null) {
          previousDocs = snapshot.docs;
          controller.add(snapshot);
        } else {
          final changes = computeDocumentChanges(previousDocs!, snapshot.docs);
          if (changes.isNotEmpty) {
            previousDocs = snapshot.docs;
            controller.add(QuerySnapshot<T>(
              docs: snapshot.docs,
              docChanges: changes,
              metadata: snapshot.metadata,
            ));
          }
        }
        if (listener != null) {
          firestore.listenerRegistry.markSynced(listener!);
        }
      } catch (e, st) {
        if (!controller.isClosed) {
          controller.addError(e, st);
        }
      } finally {
        inFlight = false;
      }
    }

    void startTimer() {
      timer?.cancel();
      checkUpdate();
      timer = Timer.periodic(effectiveInterval, (_) => checkUpdate());
    }

    controller = StreamController<QuerySnapshot<T>>.broadcast(
      onListen: () {
        if (registerListener) {
          listener = firestore.listenerRegistry.register(
            onCancel: () => controller.close(),
            onPause: () => timer?.cancel(),
            onResume: startTimer,
          );
        }
        firestore.logger?.log(LogLevel.debug, 'Polling query ${query.path}');
        startTimer();
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
        if (listener != null) {
          firestore.listenerRegistry.unregister(listener!);
          listener = null;
        }
      },
    );

    return controller.stream;
  }
}

/// Computes the [DocumentChange]s between two ordered result sets.
List<DocumentChange<T>> computeDocumentChanges<T>(
  List<QueryDocumentSnapshot<T>> oldDocs,
  List<QueryDocumentSnapshot<T>> newDocs,
) {
  final changes = <DocumentChange<T>>[];
  final oldMap = {
    for (int i = 0; i < oldDocs.length; i++) oldDocs[i].reference.path: (i, oldDocs[i])
  };
  final newMap = {
    for (int i = 0; i < newDocs.length; i++) newDocs[i].reference.path: (i, newDocs[i])
  };

  for (final oldEntry in oldMap.entries) {
    if (!newMap.containsKey(oldEntry.key)) {
      changes.add(DocumentChange<T>(
        type: DocumentChangeType.removed,
        doc: oldEntry.value.$2,
        oldIndex: oldEntry.value.$1,
        newIndex: -1,
      ));
    }
  }

  for (final newEntry in newMap.entries) {
    final path = newEntry.key;
    final newIndex = newEntry.value.$1;
    final newDoc = newEntry.value.$2;

    if (!oldMap.containsKey(path)) {
      changes.add(DocumentChange<T>(
        type: DocumentChangeType.added,
        doc: newDoc,
        oldIndex: -1,
        newIndex: newIndex,
      ));
    } else {
      final oldIndex = oldMap[path]!.$1;
      final oldDoc = oldMap[path]!.$2;

      final isDataDifferent =
          !_collectionEquality.equals(oldDoc.data(), newDoc.data());
      if (isDataDifferent || oldIndex != newIndex) {
        changes.add(DocumentChange<T>(
          type: DocumentChangeType.modified,
          doc: newDoc,
          oldIndex: oldIndex,
          newIndex: newIndex,
        ));
      }
    }
  }

  return changes;
}
