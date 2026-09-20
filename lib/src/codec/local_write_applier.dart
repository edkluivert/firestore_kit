import 'package:collection/collection.dart';

import '../types/field_path.dart';
import '../types/field_value.dart';
import '../types/options.dart';
import '../types/timestamp.dart';
import 'firestore_codec.dart';

const _deepEquality = DeepCollectionEquality();

/// Applies `set` / `update` / `delete` mutations to locally cached document
/// data, resolving [FieldValue] sentinels the same way the backend would
/// (server timestamps become an estimate of "now").
///
/// Used to keep the cache adapter consistent after writes, including writes
/// that were queued while offline.
class LocalWriteApplier {
  const LocalWriteApplier._();

  /// Result of a `set` with the given [options] on top of [existing].
  static Map<String, dynamic> applySet(
    Map<String, dynamic>? existing,
    Map<String, dynamic> data, [
    SetOptions? options,
  ]) {
    final expanded = FirestoreCodec.expandDotPaths(data);
    final base = existing == null ? <String, dynamic>{} : _deepCopy(existing);

    if (options?.merge == true) {
      return _merge(base, expanded);
    }

    if (options?.mergeFields != null) {
      final picked = <String, dynamic>{};
      for (final f in options!.mergeFields!) {
        final segments = f is FieldPath ? f.components : f.toString().split('.');
        final value = _lookup(expanded, segments);
        if (value == null && !_contains(expanded, segments)) continue;
        _put(picked, segments, value);
      }
      return _merge(base, picked);
    }

    return _merge(<String, dynamic>{}, expanded);
  }

  /// Result of an `update` with the given [data] on top of [existing].
  static Map<String, dynamic> applyUpdate(
    Map<String, dynamic>? existing,
    Map<String, dynamic> data,
  ) {
    final expanded = FirestoreCodec.expandDotPaths(data);
    final base = existing == null ? <String, dynamic>{} : _deepCopy(existing);
    return _merge(base, expanded);
  }

  static Map<String, dynamic> _merge(
    Map<String, dynamic> base,
    Map<String, dynamic> incoming,
  ) {
    for (final entry in incoming.entries) {
      final key = entry.key;
      final value = entry.value;
      final current = base[key];

      if (value is FieldValue) {
        final resolved = _resolveFieldValue(value, current);
        if (value.isDelete) {
          base.remove(key);
        } else {
          base[key] = resolved;
        }
      } else if (value is Map<String, dynamic>) {
        final target = current is Map<String, dynamic>
            ? current
            : <String, dynamic>{};
        base[key] = _merge(target, value);
      } else if (value is Map) {
        final target = current is Map<String, dynamic>
            ? current
            : <String, dynamic>{};
        base[key] = _merge(target, value.cast<String, dynamic>());
      } else {
        base[key] = _deepCopyValue(value);
      }
    }
    return base;
  }

  static Object? _resolveFieldValue(FieldValue value, Object? current) {
    if (value.isServerTimestamp) return Timestamp.now();
    if (value.isIncrement) {
      final operand = value.incrementOperand!;
      final currentNum = current is num ? current : 0;
      final result = currentNum + operand;
      return (currentNum is int && operand is int) ? result.toInt() : result;
    }
    if (value.isArrayUnion) {
      final list = current is List ? List<Object?>.from(current) : <Object?>[];
      for (final element in value.arrayUnionElements!) {
        if (!list.any((e) => _deepEquality.equals(e, element))) {
          list.add(element);
        }
      }
      return list;
    }
    if (value.isArrayRemove) {
      final list = current is List ? List<Object?>.from(current) : <Object?>[];
      list.removeWhere((e) =>
          value.arrayRemoveElements!.any((r) => _deepEquality.equals(e, r)));
      return list;
    }
    return null;
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> source) {
    final copy = <String, dynamic>{};
    for (final entry in source.entries) {
      copy[entry.key] = _deepCopyValue(entry.value);
    }
    return copy;
  }

  static Object? _deepCopyValue(Object? value) {
    if (value is Map<String, dynamic>) return _deepCopy(value);
    if (value is Map) return _deepCopy(value.cast<String, dynamic>());
    if (value is List) return value.map(_deepCopyValue).toList();
    return value;
  }

  static Object? _lookup(Map<String, dynamic> map, List<String> segments) {
    Object? current = map;
    for (final s in segments) {
      if (current is Map<String, dynamic> && current.containsKey(s)) {
        current = current[s];
      } else {
        return null;
      }
    }
    return current;
  }

  static bool _contains(Map<String, dynamic> map, List<String> segments) {
    Object? current = map;
    for (final s in segments) {
      if (current is Map<String, dynamic> && current.containsKey(s)) {
        current = current[s];
      } else {
        return false;
      }
    }
    return true;
  }

  static void _put(Map<String, dynamic> map, List<String> segments, Object? value) {
    var current = map;
    for (var i = 0; i < segments.length - 1; i++) {
      final next = current[segments[i]];
      if (next is Map<String, dynamic>) {
        current = next;
      } else {
        final created = <String, dynamic>{};
        current[segments[i]] = created;
        current = created;
      }
    }
    current[segments.last] = value;
  }
}
