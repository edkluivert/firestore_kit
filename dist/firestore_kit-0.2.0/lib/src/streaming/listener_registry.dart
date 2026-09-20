import 'dart:async';

/// An active `snapshots()` subscription known to the registry.
class ActiveListener {
  ActiveListener({
    required this.onCancel,
    this.onPause,
    this.onResume,
  });

  /// Tears the listener down (called by `terminate()`).
  final FutureOr<void> Function() onCancel;

  /// Suspends network activity (called by `disableNetwork()`).
  final FutureOr<void> Function()? onPause;

  /// Resumes network activity (called by `enableNetwork()`).
  final FutureOr<void> Function()? onResume;

  /// Whether the listener has delivered a snapshot consistent with the
  /// backend since it (re)started.
  bool synced = false;
}

/// Tracks every active snapshot listener of a Firestore instance so the
/// instance can implement `snapshotsInSync()`, `disableNetwork()`,
/// `enableNetwork()` and `terminate()`.
class SnapshotListenerRegistry {
  final Set<ActiveListener> _listeners = {};
  final StreamController<void> _inSync = StreamController<void>.broadcast();
  bool _emitScheduled = false;

  /// Currently active listeners.
  int get length => _listeners.length;

  /// Whether every active listener is in sync (vacuously true when none).
  bool get allSynced => _listeners.every((l) => l.synced);

  /// Registers a listener.
  ActiveListener register({
    required FutureOr<void> Function() onCancel,
    FutureOr<void> Function()? onPause,
    FutureOr<void> Function()? onResume,
  }) {
    final listener = ActiveListener(
      onCancel: onCancel,
      onPause: onPause,
      onResume: onResume,
    );
    _listeners.add(listener);
    return listener;
  }

  /// Unregisters a listener.
  void unregister(ActiveListener listener) {
    _listeners.remove(listener);
    _scheduleEmit();
  }

  /// Marks a listener as having delivered an up-to-date snapshot.
  void markSynced(ActiveListener listener) {
    listener.synced = true;
    _scheduleEmit();
  }

  /// Marks a listener as reconnecting / behind the backend.
  void markStale(ActiveListener listener) {
    listener.synced = false;
  }

  void _scheduleEmit() {
    if (_emitScheduled || _inSync.isClosed) return;
    _emitScheduled = true;
    scheduleMicrotask(() {
      _emitScheduled = false;
      if (!_inSync.isClosed && allSynced) _inSync.add(null);
    });
  }

  /// A stream that fires whenever all active listeners are in sync with the
  /// backend. Fires immediately on subscription if that is already the case.
  Stream<void> snapshotsInSync() {
    late StreamController<void> controller;
    StreamSubscription<void>? sub;
    controller = StreamController<void>(
      onListen: () {
        sub = _inSync.stream.listen(controller.add, onDone: controller.close);
        if (allSynced) {
          scheduleMicrotask(() {
            if (!controller.isClosed) controller.add(null);
          });
        }
      },
      onCancel: () => sub?.cancel(),
    );
    return controller.stream;
  }

  /// Suspends all listeners.
  Future<void> pauseAll() async {
    for (final l in _listeners.toList()) {
      l.synced = false;
      await l.onPause?.call();
    }
  }

  /// Resumes all listeners.
  Future<void> resumeAll() async {
    for (final l in _listeners.toList()) {
      await l.onResume?.call();
    }
  }

  /// Cancels every listener and closes the in-sync stream.
  Future<void> cancelAll() async {
    for (final l in _listeners.toList()) {
      await l.onCancel();
    }
    _listeners.clear();
    await _inSync.close();
  }
}
