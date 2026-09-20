import 'dart:io';

import 'package:meta/meta.dart';

/// Specifies custom configurations for a [FirebaseFirestore] instance,
/// mirroring `cloud_firestore`'s `Settings`.
@immutable
class Settings {
  /// Creates a [Settings] instance.
  const Settings({
    this.persistenceEnabled,
    this.host,
    this.sslEnabled,
    this.cacheSizeBytes,
    this.ignoreUndefinedProperties = false,
  });

  /// Constant used to indicate the LRU garbage collection should be disabled.
  static const int CACHE_SIZE_UNLIMITED = -1; // ignore: constant_identifier_names

  /// Whether local persistence is enabled.
  ///
  /// On `firestore_kit`, enabling persistence installs a [FileCacheAdapter]
  /// when no cache adapter was configured, see `FirebaseFirestore.enablePersistence`.
  final bool? persistenceEnabled;

  /// The hostname (and optional port, `host:port`) to connect to.
  final String? host;

  /// Whether to use SSL when connecting to [host].
  final bool? sslEnabled;

  /// An approximate cache size threshold. Retained for API compatibility; the
  /// pluggable cache adapters decide their own eviction policy.
  final int? cacheSizeBytes;

  /// Whether to skip nested properties that are set to `null` during object
  /// serialization. Retained for API compatibility.
  final bool ignoreUndefinedProperties;

  /// Returns a copy with the given fields replaced.
  Settings copyWith({
    bool? persistenceEnabled,
    String? host,
    bool? sslEnabled,
    int? cacheSizeBytes,
    bool? ignoreUndefinedProperties,
  }) {
    return Settings(
      persistenceEnabled: persistenceEnabled ?? this.persistenceEnabled,
      host: host ?? this.host,
      sslEnabled: sslEnabled ?? this.sslEnabled,
      cacheSizeBytes: cacheSizeBytes ?? this.cacheSizeBytes,
      ignoreUndefinedProperties:
          ignoreUndefinedProperties ?? this.ignoreUndefinedProperties,
    );
  }

  /// Serializes the settings to a map.
  Map<String, dynamic> get asMap => {
        'persistenceEnabled': persistenceEnabled,
        'host': host,
        'sslEnabled': sslEnabled,
        'cacheSizeBytes': cacheSizeBytes,
        'ignoreUndefinedProperties': ignoreUndefinedProperties,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Settings &&
          runtimeType == other.runtimeType &&
          persistenceEnabled == other.persistenceEnabled &&
          host == other.host &&
          sslEnabled == other.sslEnabled &&
          cacheSizeBytes == other.cacheSizeBytes &&
          ignoreUndefinedProperties == other.ignoreUndefinedProperties;

  @override
  int get hashCode => Object.hash(
      persistenceEnabled, host, sslEnabled, cacheSizeBytes, ignoreUndefinedProperties);

  @override
  String toString() => 'Settings($asMap)';
}

/// Settings passed to `FirebaseFirestore.enablePersistence`.
@immutable
class PersistenceSettings {
  /// Creates a [PersistenceSettings] instance.
  const PersistenceSettings({
    this.synchronizeTabs = false,
    this.cacheDirectory,
  });

  /// Retained for API compatibility with the web SDK; has no effect here.
  final bool synchronizeTabs;

  /// The directory used by the built-in [FileCacheAdapter] when persistence is
  /// enabled without an explicit cache adapter. Defaults to
  /// `.firestore_kit_cache/<projectId>/<databaseId>` under the current directory.
  final Directory? cacheDirectory;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PersistenceSettings &&
          runtimeType == other.runtimeType &&
          synchronizeTabs == other.synchronizeTabs &&
          cacheDirectory?.path == other.cacheDirectory?.path;

  @override
  int get hashCode => Object.hash(synchronizeTabs, cacheDirectory?.path);
}
