import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cache_adapter.dart';
import 'cache_codec.dart';

/// A persistent file-system-based cache adapter that stores Firestore documents
/// as JSON files on disk.
///
/// Each document path is mapped to a file inside [cacheDirectory] using
/// URL-safe Base64 encoding of the path, so deeply nested collection paths
/// work reliably across all operating systems. Document data is run through
/// [CacheJsonCodec] so [Timestamp], [GeoPoint], bytes and references survive
/// a round trip to disk. Writes are atomic (temp file + rename).
///
/// ```dart
/// final adapter = FileCacheAdapter(
///   cacheDirectory: Directory('.firestore_cache'),
/// );
/// FirebaseFirestore.initialize(
///   projectId: 'my-project',
///   cacheAdapter: adapter,
/// );
/// ```
class FileCacheAdapter implements FirestoreCacheAdapter {
  FileCacheAdapter({
    required this.cacheDirectory,
  });

  /// The directory on disk where cached documents are stored.
  final Directory cacheDirectory;

  static const String _extension = '.json';
  int _writeSequence = 0;

  String _filePathForDocument(String documentPath) {
    // URL-safe Base64 so we don't have to worry about path separators
    final encoded = base64Url.encode(utf8.encode(documentPath));
    return '${cacheDirectory.path}${Platform.pathSeparator}$encoded$_extension';
  }

  Future<void> _ensureDirectory() async {
    if (!cacheDirectory.existsSync()) {
      await cacheDirectory.create(recursive: true);
    }
  }

  @override
  Future<Map<String, dynamic>?> getDocument(String documentPath) async {
    final file = File(_filePathForDocument(documentPath));
    if (!file.existsSync()) return null;

    try {
      final contents = await file.readAsString();
      final decoded = jsonDecode(contents);
      if (decoded is Map<String, dynamic>) return CacheJsonCodec.decode(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> putDocument(
      String documentPath, Map<String, dynamic> data) async {
    await _ensureDirectory();
    final target = File(_filePathForDocument(documentPath));
    // Unique temp file per write so concurrent writes to one path never race.
    final tmp = File('${target.path}.${_writeSequence++}.tmp');
    final jsonStr = jsonEncode(CacheJsonCodec.encode(data));
    await tmp.writeAsString(jsonStr, flush: true);
    await tmp.rename(target.path);
  }

  @override
  Future<void> deleteDocument(String documentPath) async {
    final file = File(_filePathForDocument(documentPath));
    if (file.existsSync()) {
      await file.delete();
    }
  }

  @override
  Future<void> clear() async {
    if (!cacheDirectory.existsSync()) return;
    await for (final entity in cacheDirectory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith(_extension)) {
        await entity.delete();
      }
    }
  }

  /// Returns the document paths currently cached on disk.
  Future<List<String>> keys() async {
    if (!cacheDirectory.existsSync()) return const [];
    final result = <String>[];
    await for (final entity in cacheDirectory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith(_extension)) continue;
      final name = entity.uri.pathSegments.last;
      final encoded = name.substring(0, name.length - _extension.length);
      try {
        result.add(utf8.decode(base64Url.decode(encoded)));
      } catch (_) {
        // Not one of ours; skip.
      }
    }
    return result;
  }
}
