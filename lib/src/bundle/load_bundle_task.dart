import 'dart:async';

/// The state of a [LoadBundleTask].
enum LoadBundleTaskState { running, success, error }

/// A snapshot of the progress of a [LoadBundleTask].
class LoadBundleTaskSnapshot {
  const LoadBundleTaskSnapshot({
    required this.taskState,
    required this.bytesLoaded,
    required this.totalBytes,
    required this.documentsLoaded,
    required this.totalDocuments,
  });

  /// The current state of the task.
  final LoadBundleTaskState taskState;

  /// How many bytes have been loaded.
  final int bytesLoaded;

  /// How many bytes are in the bundle.
  final int totalBytes;

  /// How many documents have been loaded.
  final int documentsLoaded;

  /// How many documents are in the bundle.
  final int totalDocuments;

  @override
  String toString() =>
      'LoadBundleTaskSnapshot($taskState, $documentsLoaded/$totalDocuments docs, $bytesLoaded/$totalBytes bytes)';
}

/// Represents the task of loading a Firestore bundle.
class LoadBundleTask {
  LoadBundleTask(this._stream);

  final Stream<LoadBundleTaskSnapshot> _stream;
  Future<LoadBundleTaskSnapshot>? _future;

  /// Progress snapshots; the final event has `taskState == success`. Errors
  /// are delivered as stream errors after an `error` snapshot.
  Stream<LoadBundleTaskSnapshot> get stream => _stream;

  /// Completes with the final snapshot once the bundle is loaded.
  Future<LoadBundleTaskSnapshot> get future => _future ??= _stream.last;
}
