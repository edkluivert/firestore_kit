import 'dart:async';

/// Abstract adapter interface for custom local storage caching engines
/// (e.g. Hive, SharedPreferences, FlutterSecureStorage, Memory, Isar, Redis).
abstract class FirestoreCacheAdapter {
  /// Retrieves raw cached document data for [documentPath].
  Future<Map<String, dynamic>?> getDocument(String documentPath);

  /// Saves raw document data to cache for [documentPath].
  Future<void> putDocument(String documentPath, Map<String, dynamic> data);

  /// Deletes cached document data for [documentPath].
  Future<void> deleteDocument(String documentPath);

  /// Clears the entire document cache.
  Future<void> clear();
}

/// Simple thread-safe in-memory cache adapter implementation.
class MemoryCacheAdapter implements FirestoreCacheAdapter {
  final Map<String, Map<String, dynamic>> _storage = {};

  @override
  Future<Map<String, dynamic>?> getDocument(String documentPath) async {
    final data = _storage[documentPath];
    if (data == null) return null;
    return Map<String, dynamic>.from(data);
  }

  @override
  Future<void> putDocument(String documentPath, Map<String, dynamic> data) async {
    _storage[documentPath] = Map<String, dynamic>.from(data);
  }

  @override
  Future<void> deleteDocument(String documentPath) async {
    _storage.remove(documentPath);
  }

  @override
  Future<void> clear() async {
    _storage.clear();
  }
}

/// Wraps a [FirestoreCacheAdapter] so that storage failures are logged via
/// [onError] instead of failing reads, writes or realtime streams. Cache
/// misses are the worst outcome of a broken cache.
class GuardedCacheAdapter implements FirestoreCacheAdapter {
  GuardedCacheAdapter(this.inner, {this.onError});

  final FirestoreCacheAdapter inner;
  final void Function(String operation, Object error, StackTrace stackTrace)? onError;

  @override
  Future<Map<String, dynamic>?> getDocument(String documentPath) async {
    try {
      return await inner.getDocument(documentPath);
    } catch (e, st) {
      onError?.call('getDocument($documentPath)', e, st);
      return null;
    }
  }

  @override
  Future<void> putDocument(String documentPath, Map<String, dynamic> data) async {
    try {
      await inner.putDocument(documentPath, data);
    } catch (e, st) {
      onError?.call('putDocument($documentPath)', e, st);
    }
  }

  @override
  Future<void> deleteDocument(String documentPath) async {
    try {
      await inner.deleteDocument(documentPath);
    } catch (e, st) {
      onError?.call('deleteDocument($documentPath)', e, st);
    }
  }

  @override
  Future<void> clear() => inner.clear();
}
