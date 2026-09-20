import 'dart:convert';
import 'dart:typed_data';

import '../types/geo_point.dart';
import '../types/timestamp.dart';

/// Converts decoded Firestore document data (which may contain [Timestamp],
/// [GeoPoint], [DateTime], [Uint8List] and document references) into plain
/// JSON-encodable maps and back.
///
/// Storage engines that can only persist JSON (files, SharedPreferences,
/// Hive boxes of strings, Redis, ...) should run document data through this
/// codec inside their [FirestoreCacheAdapter] implementation. The built-in
/// [FileCacheAdapter] does so automatically.
class CacheJsonCodec {
  const CacheJsonCodec._();

  static const String _typeKey = r'$firestoreType';

  /// Encodes [data] into a JSON-safe map.
  static Map<String, dynamic> encode(Map<String, dynamic> data) {
    final result = <String, dynamic>{};
    for (final entry in data.entries) {
      result[entry.key] = encodeValue(entry.value);
    }
    return result;
  }

  /// Decodes a map previously produced by [encode].
  ///
  /// [refResolver] is invoked for stored document references with the stored
  /// path; when omitted the reference path is returned as a `String`.
  static Map<String, dynamic> decode(
    Map<String, dynamic> json, {
    Object Function(String path)? refResolver,
  }) {
    final result = <String, dynamic>{};
    for (final entry in json.entries) {
      result[entry.key] = decodeValue(entry.value, refResolver: refResolver);
    }
    return result;
  }

  /// Encodes a single value.
  static Object? encodeValue(Object? value) {
    if (value == null || value is bool || value is num || value is String) {
      return value;
    }
    if (value is Timestamp) {
      return {
        _typeKey: 'timestamp',
        'seconds': value.seconds,
        'nanoseconds': value.nanoseconds,
      };
    }
    if (value is DateTime) {
      return {_typeKey: 'datetime', 'iso': value.toUtc().toIso8601String()};
    }
    if (value is GeoPoint) {
      return {
        _typeKey: 'geopoint',
        'latitude': value.latitude,
        'longitude': value.longitude,
      };
    }
    if (value is Uint8List) {
      return {_typeKey: 'bytes', 'base64': base64.encode(value)};
    }
    if (value is List) {
      return value.map(encodeValue).toList();
    }
    if (value is Map) {
      final map = <String, dynamic>{};
      for (final entry in value.entries) {
        map[entry.key.toString()] = encodeValue(entry.value);
      }
      return map;
    }

    // Duck-typed DocumentReference (avoids a circular import).
    final dynamic dynVal = value;
    try {
      final path = dynVal.path;
      if (path is String) {
        return {_typeKey: 'reference', 'path': path};
      }
    } catch (_) {}

    return value.toString();
  }

  /// Decodes a single value.
  static Object? decodeValue(
    Object? value, {
    Object Function(String path)? refResolver,
  }) {
    if (value is List) {
      return value.map((e) => decodeValue(e, refResolver: refResolver)).toList();
    }
    if (value is Map) {
      final type = value[_typeKey];
      if (type is String) {
        switch (type) {
          case 'timestamp':
            return Timestamp(
              (value['seconds'] as num).toInt(),
              (value['nanoseconds'] as num).toInt(),
            );
          case 'datetime':
            return DateTime.parse(value['iso'] as String);
          case 'geopoint':
            return GeoPoint(
              (value['latitude'] as num).toDouble(),
              (value['longitude'] as num).toDouble(),
            );
          case 'bytes':
            return base64.decode(value['base64'] as String);
          case 'reference':
            final path = value['path'] as String;
            return refResolver != null ? refResolver(path) : path;
        }
      }
      final map = <String, dynamic>{};
      for (final entry in value.entries) {
        map[entry.key.toString()] =
            decodeValue(entry.value, refResolver: refResolver);
      }
      return map;
    }
    return value;
  }
}
