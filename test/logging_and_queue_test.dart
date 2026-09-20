import 'package:firestore_kit/firestore_kit.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

class TestInterceptor implements FirestoreInterceptor {
  int requestCount = 0;
  int responseCount = 0;
  int errorCount = 0;

  @override
  void onRequest(http.BaseRequest request) {
    requestCount++;
  }

  @override
  void onResponse(http.BaseResponse response, Duration latency) {
    responseCount++;
  }

  @override
  void onError(Object error, StackTrace? stackTrace) {
    errorCount++;
  }
}

void main() {
  group('FirestoreLogger & Header Sanitization', () {
    test('sanitizes sensitive Authorization and API key headers', () {
      final logger = FirestoreLogger(level: LogLevel.debug);

      final headers = {
        'Authorization': 'Bearer secret_user_token_123',
        'X-Goog-Api-Key': 'secret_google_api_key_456',
        'Content-Type': 'application/json',
      };

      final sanitized = logger.sanitizeHeaders(headers);

      expect(sanitized['Authorization'], equals('Bearer ***REDACTED***'));
      expect(sanitized['X-Goog-Api-Key'], equals('***REDACTED***'));
      expect(sanitized['Content-Type'], equals('application/json'));
    });

    test('custom LogPrinter receives structured log output', () {
      final logs = <String>[];
      final logger = FirestoreLogger(
        level: LogLevel.info,
        printer: (level, msg, [err, st]) {
          logs.add('${level.name}: $msg');
        },
      );

      logger.log(LogLevel.info, 'Database connection ready');
      logger.log(LogLevel.debug, 'Debug internal state'); // Should be filtered out

      expect(logs.length, equals(1));
      expect(logs.first, equals('info: Database connection ready'));
    });
  });

  group('Offline Write Queueing & Flushing', () {
    test('stores and flushes pending writes via cache adapter', () async {
      final cache = MemoryCacheAdapter();
      final firestore = FirebaseFirestore.instanceFor(
        projectId: 'offline-queue-proj',
        cacheAdapter: cache,
      );

      final queue = firestore.offlineQueue;
      expect(queue, isNotNull);

      // Enqueue pending write
      await queue.enqueueWrite(PendingWrite(
        id: 'write_1',
        type: 'set',
        path: 'tasks/task_1',
        data: {'title': 'Offline Task', 'done': false},
      ));

      final pendingBefore = await queue.getPendingWrites();
      expect(pendingBefore.length, equals(1));
      expect(pendingBefore.first.path, equals('tasks/task_1'));

      // Flush queue (will attempt set or clear)
      await queue.clearQueue();
      final pendingAfter = await queue.getPendingWrites();
      expect(pendingAfter, isEmpty);
    });
  });
}
