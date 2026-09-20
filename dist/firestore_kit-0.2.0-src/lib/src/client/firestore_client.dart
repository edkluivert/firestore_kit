import 'dart:async';
import 'dart:io';

import 'package:googleapis/firestore/v1.dart' as v1;
import 'package:grpc/grpc.dart' show GrpcError, StatusCode;
import 'package:http/http.dart' as http;

import '../exceptions.dart';
import '../logging/firestore_logger.dart';

/// Function signature for providing a dynamic auth token (e.g. Firebase Auth ID token).
typedef AuthTokenProvider = Future<String?> Function();

/// Authenticating HTTP client that intercepts outgoing Firestore requests.
class _FirestoreHttpClient extends http.BaseClient {
  _FirestoreHttpClient({
    required this.inner,
    this.apiKey,
    this.tokenProvider,
    this.isEmulator = false,
    this.logger,
    List<FirestoreInterceptor>? interceptors,
  }) : interceptors = interceptors ?? const [];

  final http.Client inner;
  final String? apiKey;
  final AuthTokenProvider? tokenProvider;
  final bool isEmulator;
  final FirestoreLogger? logger;
  final List<FirestoreInterceptor> interceptors;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (isEmulator) {
      request.headers['Authorization'] = 'Bearer owner';
    } else {
      if (apiKey != null && apiKey!.isNotEmpty) {
        request.headers['X-Goog-Api-Key'] = apiKey!;
      }
      if (tokenProvider != null) {
        try {
          final token = await tokenProvider!();
          if (token != null && token.isNotEmpty) {
            request.headers['Authorization'] = 'Bearer $token';
          }
        } catch (_) {
          // Token provider failure: proceed unauthenticated or let server reject
        }
      }
    }

    if (logger != null && logger!.level != LogLevel.none) {
      final sanitized = logger!.sanitizeHeaders(request.headers);
      logger!.log(
        LogLevel.debug,
        '--> ${request.method} ${request.url}\nHeaders: $sanitized',
      );
    }

    for (final interceptor in interceptors) {
      interceptor.onRequest(request);
    }

    final stopwatch = Stopwatch()..start();

    try {
      final response = await inner.send(request);
      stopwatch.stop();

      if (logger != null && logger!.level != LogLevel.none) {
        final level = response.statusCode >= 400 ? LogLevel.error : LogLevel.info;
        logger!.log(
          level,
          '<-- ${response.statusCode} ${request.method} ${request.url} (${stopwatch.elapsedMilliseconds}ms)',
        );
      }

      for (final interceptor in interceptors) {
        interceptor.onResponse(response, stopwatch.elapsed);
      }

      return response;
    } catch (e, st) {
      stopwatch.stop();
      logger?.log(
        LogLevel.error,
        'FAILED ${request.method} ${request.url} (${stopwatch.elapsedMilliseconds}ms)',
        e,
        st,
      );

      for (final interceptor in interceptors) {
        interceptor.onError(e, st);
      }

      rethrow;
    }
  }

  @override
  void close() {
    inner.close();
    super.close();
  }
}

/// Core networking client for Cloud Firestore.
class FirestoreClient {
  FirestoreClient({
    required this.projectId,
    this.databaseId = '(default)',
    this.apiKey,
    this.tokenProvider,
    this.emulatorHost,
    this.emulatorPort,
    this.logger,
    this.interceptors,
    http.Client? customClient,
  })  : _baseClient = customClient ?? http.Client(),
        isEmulator = emulatorHost != null {
    _httpClient = _FirestoreHttpClient(
      inner: _baseClient,
      apiKey: apiKey,
      tokenProvider: tokenProvider,
      isEmulator: isEmulator,
      logger: logger,
      interceptors: interceptors,
    );

    final String rootUrl;
    if (isEmulator) {
      rootUrl = 'http://$emulatorHost:$emulatorPort/';
    } else {
      rootUrl = 'https://firestore.googleapis.com/';
    }

    _api = v1.FirestoreApi(_httpClient, rootUrl: rootUrl);
  }

  final String projectId;
  final String databaseId;
  final String? apiKey;
  final AuthTokenProvider? tokenProvider;
  final String? emulatorHost;
  final int? emulatorPort;
  final bool isEmulator;
  final FirestoreLogger? logger;
  final List<FirestoreInterceptor>? interceptors;

  final http.Client _baseClient;
  late final _FirestoreHttpClient _httpClient;
  late final v1.FirestoreApi _api;

  /// Whether network access is currently enabled (see `disableNetwork()`).
  bool networkEnabled = true;

  /// Whether the owning Firestore instance has been terminated.
  bool terminated = false;

  final Set<Future<void>> _inFlightWrites = {};

  /// Write commits that have been sent but not yet acknowledged.
  List<Future<void>> get inFlightWrites => List.unmodifiable(_inFlightWrites);

  /// Returns the underlying FirestoreApi instance.
  v1.FirestoreApi get api => _api;

  /// Returns the underlying HTTP client.
  http.Client get httpClient => _httpClient;

  /// Formats the database resource path: `projects/{projectId}/databases/{databaseId}`.
  String get databasePath => 'projects/$projectId/databases/$databaseId';

  /// Formats a document resource path.
  String documentPath(String relativePath) {
    final cleanPath = relativePath.startsWith('/')
        ? relativePath.substring(1)
        : relativePath;
    return '$databasePath/documents/$cleanPath';
  }

  /// The `parent` resource for `runQuery` / Listen query targets given a
  /// collection path: the documents root for top-level collections and
  /// collection-group queries, otherwise the parent document.
  String queryParent(String collectionPath) {
    final clean = collectionPath.startsWith('/') ? collectionPath.substring(1) : collectionPath;
    final segments = clean.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length <= 1) return '$databasePath/documents';
    return '$databasePath/documents/${segments.sublist(0, segments.length - 1).join('/')}';
  }

  /// Strips the database prefix from a fully-qualified document name.
  String relativePath(String fullName) {
    const marker = '/documents/';
    final idx = fullName.indexOf(marker);
    return idx == -1 ? fullName : fullName.substring(idx + marker.length);
  }

  /// Throws if the client cannot currently talk to the backend.
  void checkOnline() {
    if (terminated) {
      throw const FirebaseFirestoreException(
        code: 'failed-precondition',
        message: 'The client has already been terminated.',
      );
    }
    if (!networkEnabled) {
      throw const FirebaseFirestoreException(
        code: 'unavailable',
        message: 'Failed to reach the backend because the network is disabled.',
      );
    }
  }

  /// Runs an operation with standard Firestore error mapping.
  Future<R> run<R>(Future<R> Function(v1.FirestoreApi api) fn) async {
    checkOnline();
    try {
      return await fn(_api);
    } catch (e, st) {
      throw mapException(e, st);
    }
  }

  /// Commits [writes] atomically and tracks the request until it is
  /// acknowledged so `waitForPendingWrites()` can await it.
  Future<v1.CommitResponse> commit(List<v1.Write> writes, {String? transaction}) {
    final request = v1.CommitRequest(writes: writes, transaction: transaction);
    final future = run((api) =>
        api.projects.databases.documents.commit(request, databasePath));

    late final Future<void> tracked;
    tracked = future.then<void>((_) {}, onError: (Object _) {});
    _inFlightWrites.add(tracked);
    tracked.whenComplete(() => _inFlightWrites.remove(tracked));
    return future;
  }

  static const Map<int, String> _grpcCodeNames = {
    StatusCode.cancelled: 'cancelled',
    StatusCode.unknown: 'unknown',
    StatusCode.invalidArgument: 'invalid-argument',
    StatusCode.deadlineExceeded: 'deadline-exceeded',
    StatusCode.notFound: 'not-found',
    StatusCode.alreadyExists: 'already-exists',
    StatusCode.permissionDenied: 'permission-denied',
    StatusCode.resourceExhausted: 'resource-exhausted',
    StatusCode.failedPrecondition: 'failed-precondition',
    StatusCode.aborted: 'aborted',
    StatusCode.outOfRange: 'out-of-range',
    StatusCode.unimplemented: 'unimplemented',
    StatusCode.internal: 'internal',
    StatusCode.unavailable: 'unavailable',
    StatusCode.dataLoss: 'data-loss',
    StatusCode.unauthenticated: 'unauthenticated',
  };

  /// Maps API, gRPC and network errors into [FirebaseFirestoreException].
  static FirebaseFirestoreException mapException(Object error, [StackTrace? stackTrace]) {
    if (error is FirebaseFirestoreException) return error;

    if (error is GrpcError) {
      return FirebaseFirestoreException(
        code: _grpcCodeNames[error.code] ?? 'unknown',
        message: error.message ?? error.codeName,
        stackTrace: stackTrace,
      );
    }

    if (error is TimeoutException) {
      return FirebaseFirestoreException(
        code: 'deadline-exceeded',
        message: 'The operation timed out.',
        stackTrace: stackTrace,
      );
    }

    if (error is SocketException ||
        error is HandshakeException ||
        error is http.ClientException) {
      return FirebaseFirestoreException(
        code: 'unavailable',
        message: 'The Firestore backend could not be reached: $error',
        stackTrace: stackTrace,
      );
    }

    final str = error.toString().toLowerCase();
    if (str.contains('socketexception') ||
        str.contains('connection refused') ||
        str.contains('failed host lookup') ||
        str.contains('network is unreachable') ||
        str.contains('connection reset') ||
        str.contains('connection closed')) {
      return FirebaseFirestoreException(
        code: 'unavailable',
        message: 'The Firestore backend could not be reached: $error',
        stackTrace: stackTrace,
      );
    }
    if (str.contains('not found') || str.contains('not_found') || str.contains('404')) {
      return FirebaseFirestoreException(
        code: 'not-found',
        message: 'Some requested document was not found.',
        stackTrace: stackTrace,
      );
    }
    if (str.contains('permission denied') || str.contains('permission_denied') || str.contains('403')) {
      return FirebaseFirestoreException(
        code: 'permission-denied',
        message: 'Missing or insufficient permissions.',
        stackTrace: stackTrace,
      );
    }
    if (str.contains('unauthenticated') || str.contains('401')) {
      return FirebaseFirestoreException(
        code: 'unauthenticated',
        message: 'The request does not have valid authentication credentials.',
        stackTrace: stackTrace,
      );
    }
    if (str.contains('already exists') || str.contains('already_exists') || str.contains('409')) {
      return FirebaseFirestoreException(
        code: 'already-exists',
        message: 'Document already exists.',
        stackTrace: stackTrace,
      );
    }
    if (str.contains('failed precondition') || str.contains('failed_precondition')) {
      return FirebaseFirestoreException(
        code: 'failed-precondition',
        message: error.toString(),
        stackTrace: stackTrace,
      );
    }
    if (str.contains('invalid argument') || str.contains('invalid_argument') || str.contains('400')) {
      return FirebaseFirestoreException(
        code: 'invalid-argument',
        message: error.toString(),
        stackTrace: stackTrace,
      );
    }
    if (str.contains('resource exhausted') || str.contains('resource_exhausted') || str.contains('429')) {
      return FirebaseFirestoreException(
        code: 'resource-exhausted',
        message: 'Quota exceeded or rate limited.',
        stackTrace: stackTrace,
      );
    }
    if (str.contains('aborted')) {
      return FirebaseFirestoreException(
        code: 'aborted',
        message: error.toString(),
        stackTrace: stackTrace,
      );
    }
    if (str.contains('deadline exceeded') || str.contains('timeout')) {
      return FirebaseFirestoreException(
        code: 'deadline-exceeded',
        message: 'The transaction or query timed out.',
        stackTrace: stackTrace,
      );
    }
    if (str.contains('unavailable') || str.contains('503') || str.contains('502')) {
      return FirebaseFirestoreException(
        code: 'unavailable',
        message: 'The Firestore service is currently unavailable.',
        stackTrace: stackTrace,
      );
    }

    return FirebaseFirestoreException(
      code: 'unknown',
      message: error.toString(),
      stackTrace: stackTrace,
    );
  }

  /// Closes the client.
  void close() {
    _httpClient.close();
  }
}
