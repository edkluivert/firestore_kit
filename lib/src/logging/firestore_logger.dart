import 'package:http/http.dart' as http;

/// Log levels for Firestore network operations.
enum LogLevel { none, error, warning, info, debug }

/// Signature for custom log handler outputs.
typedef LogPrinter = void Function(
  LogLevel level,
  String message, [
  Object? error,
  StackTrace? stackTrace,
]);

/// Safe, secure logger for Cloud Firestore networking operations.
class FirestoreLogger {
  FirestoreLogger({
    this.level = LogLevel.none,
    this.printer,
    this.redactSensitiveHeaders = true,
  });

  /// The active minimum log level filter.
  LogLevel level;

  /// Custom log printer callback.
  LogPrinter? printer;

  /// Whether to automatically sanitize authorization tokens and API keys in headers.
  bool redactSensitiveHeaders;

  /// Writes a log message if [messageLevel] meets the configured [level].
  void log(
    LogLevel messageLevel,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (messageLevel.index > level.index || level == LogLevel.none) return;

    if (printer != null) {
      printer!(messageLevel, message, error, stackTrace);
    } else {
      final prefix = '[firestore_kit][${messageLevel.name.toUpperCase()}]';
      final output = '$prefix $message';
      if (error != null) {
        // ignore: avoid_print
        print('$output | Error: $error');
      } else {
        // ignore: avoid_print
        print(output);
      }
    }
  }

  /// Sanitizes request headers to prevent leaking sensitive tokens or API keys in logs.
  Map<String, String> sanitizeHeaders(Map<String, String> headers) {
    if (!redactSensitiveHeaders) return headers;
    final sanitized = Map<String, String>.from(headers);

    for (final key in sanitized.keys) {
      final lowerKey = key.toLowerCase();
      if (lowerKey == 'authorization' ||
          lowerKey == 'x-goog-api-key' ||
          lowerKey == 'api-key') {
        final val = sanitized[key]!;
        if (val.startsWith('Bearer ')) {
          sanitized[key] = 'Bearer ***REDACTED***';
        } else {
          sanitized[key] = '***REDACTED***';
        }
      }
    }

    return sanitized;
  }
}

/// Interceptor interface for monitoring outgoing HTTP requests, responses, and network errors.
abstract class FirestoreInterceptor {
  /// Called immediately before sending an HTTP request.
  void onRequest(http.BaseRequest request);

  /// Called after receiving an HTTP response.
  void onResponse(http.BaseResponse response, Duration latency);

  /// Called when an HTTP request fails with an exception.
  void onError(Object error, StackTrace? stackTrace);
}
