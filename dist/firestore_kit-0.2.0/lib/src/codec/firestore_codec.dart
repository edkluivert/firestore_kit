import 'dart:convert';
import 'dart:typed_data';

import 'package:googleapis/firestore/v1.dart' as v1;

import '../types/field_path.dart';
import '../types/field_value.dart';
import '../types/geo_point.dart';
import '../types/options.dart';
import '../types/timestamp.dart';

/// Handles bidirectional conversion between Dart domain objects and Firestore API representations.
class FirestoreCodec {
  const FirestoreCodec._();

  /// Encodes a Dart value into a Firestore [v1.Value].
  static v1.Value encodeValue(Object? value, {String? databasePath}) {
    if (value == null) {
      return v1.Value(nullValue: 'NULL_VALUE');
    }

    if (value is bool) {
      return v1.Value(booleanValue: value);
    }

    if (value is int) {
      return v1.Value(integerValue: value.toString());
    }

    if (value is double) {
      return v1.Value(doubleValue: value);
    }

    if (value is String) {
      return v1.Value(stringValue: value);
    }

    if (value is Timestamp) {
      return v1.Value(timestampValue: value.toIso8601String());
    }

    if (value is DateTime) {
      return v1.Value(timestampValue: value.toUtc().toIso8601String());
    }

    if (value is GeoPoint) {
      return v1.Value(
        geoPointValue: v1.LatLng()
          ..latitude = value.latitude
          ..longitude = value.longitude,
      );
    }

    if (value is Uint8List) {
      return v1.Value(bytesValue: base64.encode(value));
    }

    if (value is List) {
      final values = value.map((e) => encodeValue(e, databasePath: databasePath)).toList();
      return v1.Value(arrayValue: v1.ArrayValue(values: values));
    }

    if (value is Map) {
      final fields = <String, v1.Value>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        // Skip FieldValue sentinels in map fields (they are handled as transforms)
        if (entry.value is! FieldValue) {
          fields[key] = encodeValue(entry.value, databasePath: databasePath);
        }
      }
      return v1.Value(mapValue: v1.MapValue(fields: fields));
    }

    // Dynamic duck-typing for DocumentReference to avoid circular dependencies
    final dynamic dynVal = value;
    try {
      final path = dynVal.path;
      if (path is String && databasePath != null) {
        return v1.Value(referenceValue: '$databasePath/documents/$path');
      }
    } catch (_) {}

    throw ArgumentError.value(value, 'value', 'Unsupported value type for Firestore encoding');
  }

  /// Decodes a Firestore [v1.Value] into a Dart domain object.
  static Object? decodeValue(v1.Value? value, {Object Function(String refPath)? refResolver}) {
    if (value == null) return null;

    if (value.nullValue != null) return null;
    if (value.booleanValue != null) return value.booleanValue;
    if (value.integerValue != null) return int.parse(value.integerValue!);
    if (value.doubleValue != null) return value.doubleValue;
    if (value.stringValue != null) return value.stringValue;

    if (value.timestampValue != null) {
      return Timestamp.parse(value.timestampValue!);
    }

    if (value.geoPointValue != null) {
      return GeoPoint(
        value.geoPointValue!.latitude ?? 0.0,
        value.geoPointValue!.longitude ?? 0.0,
      );
    }

    if (value.bytesValue != null) {
      return base64.decode(value.bytesValue!);
    }

    if (value.referenceValue != null) {
      final refStr = value.referenceValue!;
      if (refResolver != null) {
        return refResolver(refStr);
      }
      return refStr;
    }

    if (value.arrayValue != null) {
      final values = value.arrayValue!.values ?? [];
      return values.map((e) => decodeValue(e, refResolver: refResolver)).toList();
    }

    if (value.mapValue != null) {
      final fields = value.mapValue!.fields ?? {};
      final map = <String, dynamic>{};
      for (final entry in fields.entries) {
        map[entry.key] = decodeValue(entry.value, refResolver: refResolver);
      }
      return map;
    }

    return null;
  }

  /// Expands dot-separated keys (e.g. `'profile.email': 'foo'`) into nested maps (e.g. `{'profile': {'email': 'foo'}}`).
  static Map<String, dynamic> expandDotPaths(Map<String, dynamic> input) {
    final result = <String, dynamic>{};
    for (final entry in input.entries) {
      final key = entry.key;
      final value = entry.value;
      final parts = key.split('.');
      if (parts.length == 1) {
        if (value is Map<String, dynamic>) {
          result[key] = expandDotPaths(value);
        } else {
          result[key] = value;
        }
      } else {
        Map<String, dynamic> current = result;
        for (int i = 0; i < parts.length - 1; i++) {
          final part = parts[i];
          if (!current.containsKey(part) || current[part] is! Map<String, dynamic>) {
            current[part] = <String, dynamic>{};
          }
          current = current[part] as Map<String, dynamic>;
        }
        final lastPart = parts.last;
        if (value is Map<String, dynamic>) {
          current[lastPart] = expandDotPaths(value);
        } else {
          current[lastPart] = value;
        }
      }
    }
    return result;
  }

  /// Encodes a map of data into a Firestore [v1.Document].
  static v1.Document encodeDocument(Map<String, dynamic> data, {String? databasePath}) {
    final expanded = expandDotPaths(data);
    final fields = <String, v1.Value>{};
    for (final entry in expanded.entries) {
      if (entry.value is! FieldValue) {
        fields[entry.key] = encodeValue(entry.value, databasePath: databasePath);
      }
    }
    return v1.Document(fields: fields);
  }

  /// Decodes a Firestore [v1.Document] into a Dart `Map<String, dynamic>`.
  static Map<String, dynamic> decodeDocument(v1.Document document, {Object Function(String refPath)? refResolver}) {
    final fields = document.fields ?? {};
    final map = <String, dynamic>{};
    for (final entry in fields.entries) {
      map[entry.key] = decodeValue(entry.value, refResolver: refResolver);
    }
    return map;
  }

  /// Extracts [v1.FieldTransform] list for any [FieldValue] sentinels inside [data].
  static List<v1.FieldTransform> extractFieldTransforms(
    Map<String, dynamic> data, {
    String? databasePath,
  }) {
    final transforms = <v1.FieldTransform>[];

    void scan(Map<String, dynamic> current, List<String> pathSegments) {
      for (final entry in current.entries) {
        final key = entry.key;
        final value = entry.value;
        final currentPath = [...pathSegments, key];
        final fieldPathStr = FieldPath(currentPath).toCanonicalPath();

        if (value is FieldValue) {
          if (value.isServerTimestamp) {
            transforms.add(
              v1.FieldTransform()
                ..fieldPath = fieldPathStr
                ..setToServerValue = 'REQUEST_TIME',
            );
          } else if (value.isIncrement) {
            final operand = value.incrementOperand!;
            transforms.add(
              v1.FieldTransform()
                ..fieldPath = fieldPathStr
                ..increment = encodeValue(operand, databasePath: databasePath),
            );
          } else if (value.isArrayUnion) {
            final elements = value.arrayUnionElements!;
            transforms.add(
              v1.FieldTransform()
                ..fieldPath = fieldPathStr
                ..appendMissingElements = v1.ArrayValue(
                  values: elements
                      .map((e) => encodeValue(e, databasePath: databasePath))
                      .toList(),
                ),
            );
          } else if (value.isArrayRemove) {
            final elements = value.arrayRemoveElements!;
            transforms.add(
              v1.FieldTransform()
                ..fieldPath = fieldPathStr
                ..removeAllFromArray = v1.ArrayValue(
                  values: elements
                      .map((e) => encodeValue(e, databasePath: databasePath))
                      .toList(),
                ),
            );
          }
        } else if (value is Map<String, dynamic>) {
          scan(value, currentPath);
        }
      }
    }

    scan(data, []);
    return transforms;
  }

  /// Extracts the field paths of any fields marked with [FieldValue.delete()].
  static List<String> extractDeletePaths(Map<String, dynamic> data) {
    final deletePaths = <String>[];

    void scan(Map<String, dynamic> current, List<String> pathSegments) {
      for (final entry in current.entries) {
        final currentPath = [...pathSegments, entry.key];
        final val = entry.value;
        if (val is FieldValue && val.isDelete) {
          deletePaths.add(FieldPath(currentPath).toCanonicalPath());
        } else if (val is Map<String, dynamic>) {
          scan(val, currentPath);
        }
      }
    }

    scan(data, []);
    return deletePaths;
  }

  /// Builds the `Write` protos for a `set()` of [data] on [documentName].
  static List<v1.Write> buildSetWrites({
    required String documentName,
    required Map<String, dynamic> data,
    SetOptions? options,
    String? databasePath,
  }) {
    final writes = <v1.Write>[];
    final transforms = extractFieldTransforms(data, databasePath: databasePath);
    final deletePaths = extractDeletePaths(data);

    final docProto = encodeDocument(data, databasePath: databasePath);
    docProto.name = documentName;

    final updateMaskFields = <String>[];
    if (options?.merge == true) {
      for (final key in data.keys) {
        if (data[key] is! FieldValue) {
          updateMaskFields.add(FieldPath(key.split('.')).toCanonicalPath());
        }
      }
      updateMaskFields.addAll(deletePaths);
    } else if (options?.mergeFields != null) {
      for (final f in options!.mergeFields!) {
        if (f is FieldPath) {
          updateMaskFields.add(f.toCanonicalPath());
        } else {
          updateMaskFields.add(f.toString());
        }
      }
    }

    final write = v1.Write(update: docProto);
    if (updateMaskFields.isNotEmpty) {
      write.updateMask = v1.DocumentMask(fieldPaths: updateMaskFields);
    }
    writes.add(write);

    if (transforms.isNotEmpty) {
      writes.add(v1.Write(
        transform: v1.DocumentTransform(
          document: documentName,
          fieldTransforms: transforms,
        ),
      ));
    }
    return writes;
  }

  /// Builds the `Write` protos for an `update()` of [data] on [documentName].
  ///
  /// [data] keys may be dot-separated paths or canonical [FieldPath] strings.
  static List<v1.Write> buildUpdateWrites({
    required String documentName,
    required Map<String, dynamic> data,
    String? databasePath,
  }) {
    final writes = <v1.Write>[];
    final transforms = extractFieldTransforms(data, databasePath: databasePath);
    final deletePaths = extractDeletePaths(data);

    final docProto = encodeDocument(data, databasePath: databasePath);
    docProto.name = documentName;

    final updateMaskFields = <String>[];
    for (final key in data.keys) {
      if (data[key] is! FieldValue) {
        updateMaskFields.add(key);
      }
    }
    updateMaskFields.addAll(deletePaths);

    writes.add(v1.Write(
      update: docProto,
      updateMask: v1.DocumentMask(fieldPaths: updateMaskFields),
      currentDocument: v1.Precondition(exists: true),
    ));

    if (transforms.isNotEmpty) {
      writes.add(v1.Write(
        transform: v1.DocumentTransform(
          document: documentName,
          fieldTransforms: transforms,
        ),
      ));
    }
    return writes;
  }

  /// Builds the `Write` proto that deletes [documentName].
  static v1.Write buildDeleteWrite(String documentName) =>
      v1.Write(delete: documentName);

  /// Normalizes an `update()` payload whose keys may be [FieldPath]s.
  static Map<String, dynamic> normalizeUpdateData(Map<Object, Object?> data) {
    final strMap = <String, dynamic>{};
    for (final entry in data.entries) {
      final key = entry.key;
      strMap[key is FieldPath ? key.toCanonicalPath() : key.toString()] =
          entry.value;
    }
    return strMap;
  }
}
