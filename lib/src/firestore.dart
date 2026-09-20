import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:googleapis/firestore/v1.dart' as v1;

import 'batch/transaction.dart';
import 'batch/write_batch.dart';
import 'bundle/firestore_bundle.dart';
import 'bundle/load_bundle_task.dart';
import 'cache/cache_adapter.dart';
import 'cache/file_cache_adapter.dart';
import 'client/firestore_client.dart';
import 'codec/firestore_codec.dart';
import 'codec/local_write_applier.dart';
import 'exceptions.dart';
import 'grpc/firestore_grpc_transport.dart';
import 'logging/firestore_logger.dart';
import 'query/query.dart';
import 'queue/offline_write_queue.dart';
import 'references/collection_reference.dart';
import 'references/document_reference.dart';
import 'snapshots/query_snapshot.dart';
import 'streaming/listener_registry.dart';
import 'types/firebase_options.dart';
import 'types/options.dart';
import 'types/settings.dart';

/// A local mutation to mirror into the cache adapter after a write.
class LocalWriteOp {
  LocalWriteOp._(this.type, this.path, this.data, this.options);

  factory LocalWriteOp.set(String path, Map<String, dynamic> data, [SetOptions? options]) =>
      LocalWriteOp._('set', path, data, options);

  factory LocalWriteOp.update(String path, Map<String, dynamic> data) =>
      LocalWriteOp._('update', path, data, null);

  factory LocalWriteOp.delete(String path) => LocalWriteOp._('delete', path, null, null);

  final String type;
  final String path;
  final Map<String, dynamic>? data;
  final SetOptions? options;
}

class _InstanceConfig {
  _InstanceConfig({
    required this.projectId,
    required this.databaseId,
    this.apiKey,
    this.options,
    this.tokenProvider,
    this.cacheAdapter,
    this.logger,
    this.interceptors,
    this.useGrpcStreaming = false,
    this.grpcOptions,
    this.autoQueueOfflineWrites = true,
  });

  final String projectId;
  final String databaseId;
  final String? apiKey;
  final FirebaseOptions? options;
  final AuthTokenProvider? tokenProvider;
  final FirestoreCacheAdapter? cacheAdapter;
  final FirestoreLogger? logger;
  final List<FirestoreInterceptor>? interceptors;
  final bool useGrpcStreaming;
  final GrpcTransportOptions? grpcOptions;
  final bool autoQueueOfflineWrites;
}

/// The entry point for accessing Cloud Firestore on DartNative.
class FirebaseFirestore {
  FirebaseFirestore._(_InstanceConfig config)
      : projectId = config.projectId,
        databaseId = config.databaseId,
        apiKey = config.apiKey,
        options = config.options,
        tokenProvider = config.tokenProvider,
        logger = config.logger,
        interceptors = config.interceptors,
        useGrpcStreaming = config.useGrpcStreaming,
        grpcOptions = config.grpcOptions,
        autoQueueOfflineWrites = config.autoQueueOfflineWrites {
    cacheAdapter = config.cacheAdapter;
    _client = FirestoreClient(
      projectId: projectId,
      databaseId: databaseId,
      apiKey: apiKey,
      tokenProvider: _forwardToken,
      logger: logger,
      interceptors: interceptors,
    );

    offlineQueue = OfflineWriteQueueManager(cacheAdapter: cacheAdapter);

    if (useGrpcStreaming || grpcOptions != null) {
      grpcTransport = FirestoreGrpcTransport(
        firestore: this,
        options: grpcOptions,
      );
    }
  }

  final String projectId;
  final String databaseId;
  final String? apiKey;

  /// The [FirebaseOptions] this instance was created from, when known.
  final FirebaseOptions? options;

  /// Supplies the bearer token sent with every request (for example a Firebase
  /// Auth ID token). Can be set or replaced at any time:
  ///
  /// ```dart
  /// FirebaseFirestore.instance.tokenProvider =
  ///     () async => await FirebaseAuth.instance.currentUser?.getIdToken();
  /// ```
  AuthTokenProvider? tokenProvider;

  Future<String?> _forwardToken() async => tokenProvider?.call();

  final FirestoreLogger? logger;
  final List<FirestoreInterceptor>? interceptors;
  final bool useGrpcStreaming;
  final GrpcTransportOptions? grpcOptions;

  /// Whether writes that fail because the backend is unreachable are queued
  /// and replayed automatically (default `true`).
  final bool autoQueueOfflineWrites;

  /// The active cache adapter, if any. Installed by `enablePersistence()`
  /// when none was configured up front.
  FirestoreCacheAdapter? get cacheAdapter => _cacheAdapter;
  set cacheAdapter(FirestoreCacheAdapter? adapter) {
    _cacheAdapter = adapter;
    _guardedCache = adapter == null
        ? null
        : GuardedCacheAdapter(adapter, onError: (op, e, st) {
            logger?.log(LogLevel.error, 'Cache adapter failed during $op', e, st);
          });
  }

  FirestoreCacheAdapter? _cacheAdapter;
  GuardedCacheAdapter? _guardedCache;

  /// [cacheAdapter] wrapped so storage failures are logged, never thrown.
  /// Internal reads and writes go through this.
  FirestoreCacheAdapter? get guardedCache => _guardedCache;

  /// Queue of writes waiting for the backend. Persisted through [cacheAdapter]
  /// when one is configured, in memory otherwise.
  late OfflineWriteQueueManager offlineQueue;

  FirestoreGrpcTransport? grpcTransport;

  /// Registry of active `snapshots()` listeners.
  final SnapshotListenerRegistry listenerRegistry = SnapshotListenerRegistry();

  late FirestoreClient _client;
  FirestoreBundle? _bundle;
  Settings _settings = const Settings();
  bool _terminated = false;

  /// Internal getter for the network client.
  FirestoreClient get client => _client;

  String get _instanceKey => '$projectId/$databaseId';

  static final Map<String, FirebaseFirestore> _instances = {};
  static final Map<String, _InstanceConfig> _configs = {};
  static String? _defaultProjectId;
  static String _defaultDatabaseId = '(default)';

  /// Sets the default project configuration used by `FirebaseFirestore.instance`.
  ///
  /// The project can be given as [projectId], as [options], or left out
  /// entirely to be discovered from `--dart-define`s, environment variables or
  /// the `GoogleService-Info.plist` / `google-services.json` shipped with the
  /// app (see [FirebaseOptions.discover]). Calling this is optional:
  /// `FirebaseFirestore.instance` performs the same discovery on first use.
  static void initialize({
    String? projectId,
    FirebaseOptions? options,
    String? databaseId,
    String? apiKey,
    AuthTokenProvider? tokenProvider,
    FirestoreCacheAdapter? cacheAdapter,
    FirestoreLogger? logger,
    List<FirestoreInterceptor>? interceptors,
    bool useGrpcStreaming = false,
    GrpcTransportOptions? grpcOptions,
    bool autoQueueOfflineWrites = true,
  }) {
    final resolved = options ??
        (projectId != null
            ? FirebaseOptions(projectId: projectId, apiKey: apiKey, databaseId: databaseId ?? '(default)')
            : _discoverOptions());
    final effectiveProjectId = projectId ?? resolved.projectId;
    final effectiveDatabaseId = databaseId ?? resolved.databaseId;
    _defaultProjectId = effectiveProjectId;
    _defaultDatabaseId = effectiveDatabaseId;
    final config = _InstanceConfig(
      projectId: effectiveProjectId,
      databaseId: effectiveDatabaseId,
      apiKey: apiKey ?? resolved.apiKey,
      options: resolved,
      tokenProvider: tokenProvider,
      cacheAdapter: cacheAdapter,
      logger: logger,
      interceptors: interceptors,
      useGrpcStreaming: useGrpcStreaming,
      grpcOptions: grpcOptions,
      autoQueueOfflineWrites: autoQueueOfflineWrites,
    );
    final key = '$effectiveProjectId/$effectiveDatabaseId';
    _configs[key] = config;
    _instances.remove(key);
    _instances[key] = FirebaseFirestore._(config);
  }

  static FirebaseOptions _discoverOptions() {
    final discovered = FirebaseOptions.discover();
    if (discovered != null) return discovered;
    throw const FirebaseFirestoreException(
      code: 'failed-precondition',
      message: 'No Firebase project configured. Either call '
          'FirebaseFirestore.initialize(projectId: ...), pass '
          '--dart-define=FIREBASE_PROJECT_ID=<id> when building, set the '
          'FIREBASE_PROJECT_ID / GOOGLE_CLOUD_PROJECT environment variable, or '
          'ship GoogleService-Info.plist / google-services.json with the app.',
    );
  }

  /// Returns the default [FirebaseFirestore] singleton instance.
  ///
  /// Works with zero configuration when the project can be discovered (see
  /// [initialize]); otherwise throws a `failed-precondition` error explaining
  /// how to configure it.
  static FirebaseFirestore get instance {
    if (_defaultProjectId == null) initialize();
    return instanceFor(projectId: _defaultProjectId, databaseId: _defaultDatabaseId);
  }

  /// The options discovered or supplied for the default instance, if any.
  static FirebaseOptions? get defaultOptions {
    final pid = _defaultProjectId;
    if (pid == null) return null;
    return _configs['$pid/$_defaultDatabaseId']?.options;
  }

  /// Forgets the default configuration (mainly for tests).
  static void resetDefaultConfiguration() {
    _defaultProjectId = null;
    _defaultDatabaseId = '(default)';
  }

  /// Returns a [FirebaseFirestore] instance for a specific project and database.
  ///
  /// Configuration arguments only apply the first time an instance is created
  /// for a given project/database pair (or after `terminate()`).
  static FirebaseFirestore instanceFor({
    String? projectId,
    String databaseId = '(default)',
    String? apiKey,
    AuthTokenProvider? tokenProvider,
    FirestoreCacheAdapter? cacheAdapter,
    FirestoreLogger? logger,
    List<FirestoreInterceptor>? interceptors,
    bool useGrpcStreaming = false,
    GrpcTransportOptions? grpcOptions,
    bool autoQueueOfflineWrites = true,
  }) {
    final effectiveProjectId = projectId ?? _defaultProjectId ?? 'default-project';
    final key = '$effectiveProjectId/$databaseId';

    return _instances.putIfAbsent(key, () {
      final config = _configs.putIfAbsent(
        key,
        () => _InstanceConfig(
          projectId: effectiveProjectId,
          databaseId: databaseId,
          apiKey: apiKey,
          tokenProvider: tokenProvider,
          cacheAdapter: cacheAdapter,
          logger: logger,
          interceptors: interceptors,
          useGrpcStreaming: useGrpcStreaming,
          grpcOptions: grpcOptions,
          autoQueueOfflineWrites: autoQueueOfflineWrites,
        ),
      );
      return FirebaseFirestore._(config);
    });
  }

  // ---------------------------------------------------------------------------
  // Settings & persistence
  // ---------------------------------------------------------------------------

  /// The current [Settings] for this instance.
  Settings get settings => _settings;

  /// Applies [Settings]. `host` + `sslEnabled: false` routes traffic to an
  /// emulator; `persistenceEnabled: true` enables local persistence.
  set settings(Settings settings) {
    _settings = settings;
    final host = settings.host;
    if (host != null && host.isNotEmpty) {
      final parts = host.split(':');
      final port = parts.length > 1 ? int.tryParse(parts.last) : null;
      useFirestoreEmulator(
        parts.first,
        port ?? (settings.sslEnabled == false ? 8080 : 443),
        sslEnabled: settings.sslEnabled ?? false,
      );
    }
    if (settings.persistenceEnabled == true) {
      _installPersistence(null);
    }
  }

  /// Whether local persistence is enabled.
  bool get persistenceEnabled => cacheAdapter != null;

  /// Enables persistent storage.
  ///
  /// When a [cacheAdapter] was supplied at initialization this is a no-op.
  /// Otherwise a [FileCacheAdapter] is installed, rooted at
  /// `PersistenceSettings.cacheDirectory` or
  /// `.firestore_kit_cache/<projectId>/<databaseId>`.
  Future<void> enablePersistence([PersistenceSettings? persistenceSettings]) async {
    _checkNotTerminated();
    await _installPersistence(persistenceSettings);
  }

  Future<void> _installPersistence(PersistenceSettings? persistenceSettings) async {
    _settings = _settings.copyWith(persistenceEnabled: true);
    if (cacheAdapter != null) return;

    final safeDb = databaseId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    final dir = persistenceSettings?.cacheDirectory ??
        Directory('.firestore_kit_cache${Platform.pathSeparator}$projectId${Platform.pathSeparator}$safeDb');
    cacheAdapter = FileCacheAdapter(cacheDirectory: dir);

    final previous = offlineQueue;
    offlineQueue = OfflineWriteQueueManager(cacheAdapter: cacheAdapter);
    await previous.migrateTo(offlineQueue);
    logger?.log(LogLevel.info, 'Persistence enabled at ${dir.path}');
  }

  /// Clears the persistent storage: cached documents, queued writes and
  /// loaded bundles.
  Future<void> clearPersistence() async {
    await cacheAdapter?.clear();
    await offlineQueue.clearQueue();
    _bundle?.reset();
  }

  // ---------------------------------------------------------------------------
  // Writes & offline queue
  // ---------------------------------------------------------------------------

  /// Commits [writes] atomically. If the backend is unreachable and
  /// [autoQueueOfflineWrites] is on, the writes are queued instead and the
  /// future completes normally. [localOps] are mirrored into the cache either
  /// way. Returns `true` when the backend acknowledged the write.
  Future<bool> commitWrites(
    List<v1.Write> writes, {
    List<LocalWriteOp> localOps = const [],
  }) async {
    var committed = true;
    try {
      await _client.commit(writes);
    } on FirebaseFirestoreException catch (e) {
      if (!e.isOffline || !autoQueueOfflineWrites) rethrow;
      committed = false;
      final first = localOps.isEmpty ? null : localOps.first;
      await offlineQueue.enqueueWrite(PendingWrite(
        id: offlineQueue.nextId(),
        type: localOps.length == 1 ? first!.type : 'batch',
        path: first?.path ?? '',
        writes: [
          for (final w in writes)
            jsonDecode(jsonEncode(w.toJson())) as Map<String, dynamic>,
        ],
      ));
      logger?.log(LogLevel.warning,
          'Backend unreachable (${e.code}); queued ${writes.length} write(s) for later sync');
    }

    for (final op in localOps) {
      await applyLocalWrite(op, queued: !committed);
    }
    return committed;
  }

  /// Mirrors a write into the cache adapter.
  Future<void> applyLocalWrite(LocalWriteOp op, {bool queued = false}) async {
    final adapter = guardedCache;
    if (adapter == null) return;
    switch (op.type) {
      case 'set':
        final existing = await adapter.getDocument(op.path);
        await adapter.putDocument(
            op.path, LocalWriteApplier.applySet(existing, op.data!, op.options));
        break;
      case 'update':
        final existing = await adapter.getDocument(op.path);
        // Only synthesize a partial document when the write is still pending;
        // a committed update on an uncached document will be refreshed on read.
        if (existing == null && !queued) return;
        await adapter.putDocument(
            op.path, LocalWriteApplier.applyUpdate(existing, op.data!));
        break;
      case 'delete':
        await adapter.deleteDocument(op.path);
        break;
    }
  }

  /// Number of writes waiting to be synced.
  Future<int> get pendingWriteCount => offlineQueue.length;

  /// Whether a queued write touches [documentPath].
  Future<bool> hasPendingWritesFor(String documentPath) =>
      offlineQueue.hasPendingWritesFor(documentPath);

  /// Attempts to sync queued offline writes to the backend, in order.
  ///
  /// Stops at the first write that fails because the backend is unreachable.
  /// Writes rejected by the backend for other reasons (permission denied,
  /// failed precondition, ...) are dropped and logged, matching the
  /// behaviour of the native SDKs. Returns the number of flushed entries.
  Future<int> flushPendingWrites() async {
    if (_terminated || !_client.networkEnabled) return 0;

    final pending = await offlineQueue.getPendingWrites();
    if (pending.isEmpty) return 0;

    int flushedCount = 0;
    for (final item in pending) {
      try {
        await _client.commit(_writesFor(item));
        await offlineQueue.removeWrite(item.id);
        flushedCount++;
      } on FirebaseFirestoreException catch (e) {
        if (e.isOffline) {
          logger?.log(LogLevel.info,
              'Flush paused: backend unreachable (${e.code}); $flushedCount write(s) synced');
          break;
        }
        logger?.log(LogLevel.error,
            'Dropping queued write ${item.id} (${item.type} ${item.path}) rejected by backend', e);
        await offlineQueue.removeWrite(item.id);
      }
    }

    return flushedCount;
  }

  List<v1.Write> _writesFor(PendingWrite item) {
    if (item.hasProtoWrites) return item.toProtoWrites();
    final docName = _client.documentPath(item.path);
    switch (item.type) {
      case 'set':
        return FirestoreCodec.buildSetWrites(
          documentName: docName,
          data: item.data ?? const {},
          options: item.options == null
              ? null
              : SetOptions(
                  merge: item.options!['merge'] as bool?,
                  mergeFields: (item.options!['mergeFields'] as List?)?.cast<Object>(),
                ),
          databasePath: _client.databasePath,
        );
      case 'update':
        return FirestoreCodec.buildUpdateWrites(
          documentName: docName,
          data: item.data ?? const {},
          databasePath: _client.databasePath,
        );
      case 'delete':
        return [FirestoreCodec.buildDeleteWrite(docName)];
    }
    throw FirebaseFirestoreException(
      code: 'invalid-argument',
      message: 'Unknown pending write type "${item.type}"',
    );
  }

  /// Waits until every write issued so far has been acknowledged by the
  /// backend, replaying queued offline writes as needed.
  ///
  /// Like the native SDKs this keeps waiting while the backend is unreachable
  /// or the network is disabled. Pass [timeout] to give up with a
  /// `deadline-exceeded` error instead. Throws `failed-precondition` if the
  /// instance is terminated while waiting.
  Future<void> waitForPendingWrites({Duration? timeout}) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    var backoff = const Duration(milliseconds: 250);

    while (true) {
      _checkNotTerminated();
      await Future.wait(_client.inFlightWrites);
      if (_client.networkEnabled) {
        await flushPendingWrites();
      }
      if (await pendingWriteCount == 0 && _client.inFlightWrites.isEmpty) return;

      if (deadline != null) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          throw FirebaseFirestoreException(
            code: 'deadline-exceeded',
            message: 'Timed out waiting for ${await pendingWriteCount} pending write(s).',
          );
        }
        await Future<void>.delayed(backoff < remaining ? backoff : remaining);
      } else {
        await Future<void>.delayed(backoff);
      }
      backoff = Duration(
        milliseconds: math.min(backoff.inMilliseconds * 2, 30000),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Network & lifecycle
  // ---------------------------------------------------------------------------

  void _checkNotTerminated() {
    if (_terminated) {
      throw const FirebaseFirestoreException(
        code: 'failed-precondition',
        message: 'The client has already been terminated.',
      );
    }
  }

  /// Whether `terminate()` has been called.
  bool get isTerminated => _terminated;

  /// Whether network access is enabled.
  bool get networkEnabled => _client.networkEnabled;

  /// Disables network access. Reads are served from the cache adapter, writes
  /// are queued, and active listeners are suspended.
  Future<void> disableNetwork() async {
    _checkNotTerminated();
    if (!_client.networkEnabled) return;
    _client.networkEnabled = false;
    await listenerRegistry.pauseAll();
    logger?.log(LogLevel.info, 'Network disabled');
  }

  /// Re-enables network access, resumes listeners and syncs queued writes.
  Future<void> enableNetwork() async {
    _checkNotTerminated();
    if (_client.networkEnabled) return;
    _client.networkEnabled = true;
    logger?.log(LogLevel.info, 'Network enabled');
    await listenerRegistry.resumeAll();
    await flushPendingWrites();
  }

  /// Terminates this instance: cancels listeners, closes network connections
  /// and releases it from the instance registry. Queued offline writes are
  /// kept in the cache adapter. Any further use of this instance throws a
  /// `failed-precondition` error; `FirebaseFirestore.instance` returns a
  /// fresh instance.
  Future<void> terminate() async {
    if (_terminated) return;
    _terminated = true;
    _client.terminated = true;
    _instances.remove(_instanceKey);
    try {
      await listenerRegistry.cancelAll().timeout(const Duration(seconds: 5));
      await grpcTransport?.close().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      logger?.log(LogLevel.warning, 'Timed out waiting for connections to close during terminate()');
    } finally {
      _client.close();
    }
    logger?.log(LogLevel.info, 'Firestore instance terminated');
  }

  /// A stream that fires whenever all active `snapshots()` listeners are in
  /// sync with the backend. Fires immediately on subscription when that is
  /// already the case (including when there are no listeners).
  Stream<void> snapshotsInSync() => listenerRegistry.snapshotsInSync();

  /// Configures Firestore to use an emulator host and port.
  void useFirestoreEmulator(
    String host,
    int port, {
    bool sslEnabled = false,
  }) {
    final networkEnabled = _client.networkEnabled;
    _client.close();
    _client = FirestoreClient(
      projectId: projectId,
      databaseId: databaseId,
      apiKey: apiKey,
      tokenProvider: tokenProvider,
      emulatorHost: host,
      emulatorPort: port,
      logger: logger,
      interceptors: interceptors,
    )..networkEnabled = networkEnabled;

    final transport = grpcTransport;
    if (transport != null) {
      unawaited(transport.close());
      grpcTransport = FirestoreGrpcTransport(
        firestore: this,
        options: transport.options.forEmulator(host, port),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Bundles
  // ---------------------------------------------------------------------------

  FirestoreBundle get _bundleManager => _bundle ??= FirestoreBundle(firestore: this);

  /// Loads a Firestore bundle into the local cache.
  LoadBundleTask loadBundle(Uint8List bundle) {
    _checkNotTerminated();
    return _bundleManager.load(bundle);
  }

  /// Executes a named query loaded from a bundle.
  Future<QuerySnapshot<Map<String, dynamic>>> namedQueryGet(
    String name, {
    GetOptions options = const GetOptions(),
  }) {
    _checkNotTerminated();
    return _bundleManager.namedQueryGet<Map<String, dynamic>>(name, options: options);
  }

  /// Executes a named query loaded from a bundle, converting documents with
  /// the supplied converters.
  Future<QuerySnapshot<T>> namedQueryWithConverterGet<T>(
    String name, {
    GetOptions options = const GetOptions(),
    required FromFirestore<T> fromFirestore,
    required ToFirestore<T> toFirestore,
  }) {
    _checkNotTerminated();
    return _bundleManager.namedQueryGet<T>(
      name,
      options: options,
      fromFirestore: fromFirestore,
      toFirestore: toFirestore,
    );
  }

  // ---------------------------------------------------------------------------
  // References, batches, transactions
  // ---------------------------------------------------------------------------

  /// Gets a [CollectionReference] instance that refers to the collection at the specified path.
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    final cleanPath = collectionPath.startsWith('/')
        ? collectionPath.substring(1)
        : collectionPath;
    final colId = cleanPath.split('/').last;

    return CollectionReference<Map<String, dynamic>>(
      firestore: this,
      path: cleanPath,
      collectionId: colId,
    );
  }

  /// Creates and returns a new [Query] that includes all documents in the database
  /// that are contained in a collection or subcollection with the given [collectionId].
  Query<Map<String, dynamic>> collectionGroup(String collectionId) {
    return Query<Map<String, dynamic>>(
      firestore: this,
      path: '',
      collectionId: collectionId,
      isCollectionGroup: true,
    );
  }

  /// Gets a [DocumentReference] instance that refers to the document at the specified path.
  DocumentReference<Map<String, dynamic>> doc(String documentPath) {
    final cleanPath = documentPath.startsWith('/')
        ? documentPath.substring(1)
        : documentPath;

    return DocumentReference<Map<String, dynamic>>(
      firestore: this,
      path: cleanPath,
    );
  }

  /// Creates a write batch, used for performing multiple writes as a single atomic operation.
  WriteBatch batch() => WriteBatch(firestore: this);

  /// Executes the given [updateFunction] and then attempts to commit the changes applied
  /// within the transaction.
  Future<T> runTransaction<T>(
    TransactionHandler<T> updateFunction, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    int attempts = 0;
    while (attempts < maxAttempts) {
      attempts++;
      String? transactionToken;
      try {
        final beginRes = await _client.run((api) => api.projects.databases.documents
            .beginTransaction(v1.BeginTransactionRequest(), _client.databasePath));
        transactionToken = beginRes.transaction!;
        final transaction = Transaction(
          firestore: this,
          transactionToken: transactionToken,
        );

        final result = await updateFunction(transaction).timeout(timeout);
        await transaction.commit();
        return result;
      } catch (e, st) {
        final mapped = FirestoreClient.mapException(e, st);
        // Release the backend locks held by this attempt.
        if (transactionToken != null && !_terminated) {
          try {
            await _client.run((api) => api.projects.databases.documents.rollback(
                v1.RollbackRequest(transaction: transactionToken), _client.databasePath));
          } catch (_) {}
        }
        final retryable = mapped.code == 'aborted' || mapped.isOffline || mapped.code == 'internal';
        if (!retryable || attempts >= maxAttempts) {
          if (!retryable) throw mapped;
          throw FirebaseFirestoreException(
            code: 'aborted',
            message: 'Transaction failed after $maxAttempts attempts: $mapped',
            stackTrace: st,
          );
        }
        // Exponential backoff before retry
        await Future<void>.delayed(Duration(milliseconds: 100 * (1 << attempts)));
      }
    }
    throw const FirebaseFirestoreException(
      code: 'aborted',
      message: 'Transaction failed to complete.',
    );
  }
}
