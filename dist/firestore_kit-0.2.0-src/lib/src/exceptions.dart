/// An exception thrown when a Firestore operation fails.
class FirebaseFirestoreException implements Exception {
  /// Creates a [FirebaseFirestoreException].
  const FirebaseFirestoreException({
    required this.code,
    required this.message,
    this.plugin = 'cloud_firestore',
    this.stackTrace,
  });

  /// The error code (e.g., 'not-found', 'permission-denied', 'unavailable').
  final String code;

  /// The human-readable error message.
  final String message;

  /// The plugin that threw the exception.
  final String plugin;

  /// The stack trace if available.
  final StackTrace? stackTrace;

  /// Whether this error means the backend could not be reached (offline,
  /// network disabled, connection refused, timeout).
  bool get isOffline => code == 'unavailable' || code == 'deadline-exceeded';

  /// Whether a retry could reasonably succeed.
  bool get isRetryable =>
      isOffline || code == 'aborted' || code == 'resource-exhausted' || code == 'internal';

  @override
  String toString() => '[$plugin/$code] $message';
}
