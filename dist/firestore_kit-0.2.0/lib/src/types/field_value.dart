import 'package:meta/meta.dart';

/// Sentinel values that can be used when writing document fields with `set()` or `update()`.
@immutable
abstract class FieldValue {
  const FieldValue._();

  /// Returns a sentinel used with `set()` or `update()` to include a server-generated timestamp.
  static FieldValue serverTimestamp() => const _ServerTimestampFieldValue();

  /// Returns a sentinel for use with `update()` to mark a field for deletion.
  static FieldValue delete() => const _DeleteFieldValue();

  /// Returns a special value that tells the server to increment the field's current value by the given value.
  static FieldValue increment(num value) => _IncrementFieldValue(value);

  /// Returns a special value that tells the server to union the given elements with any array value that already exists.
  static FieldValue arrayUnion(List<Object?> elements) =>
      _ArrayUnionFieldValue(List<Object?>.unmodifiable(elements));

  /// Returns a special value that tells the server to remove the given elements from any array value that already exists.
  static FieldValue arrayRemove(List<Object?> elements) =>
      _ArrayRemoveFieldValue(List<Object?>.unmodifiable(elements));
}

@immutable
class _ServerTimestampFieldValue extends FieldValue {
  const _ServerTimestampFieldValue() : super._();

  @override
  String toString() => 'FieldValue.serverTimestamp()';
}

@immutable
class _DeleteFieldValue extends FieldValue {
  const _DeleteFieldValue() : super._();

  @override
  String toString() => 'FieldValue.delete()';
}

@immutable
class _IncrementFieldValue extends FieldValue {
  const _IncrementFieldValue(this.operand) : super._();

  final num operand;

  @override
  String toString() => 'FieldValue.increment($operand)';
}

@immutable
class _ArrayUnionFieldValue extends FieldValue {
  const _ArrayUnionFieldValue(this.elements) : super._();

  final List<Object?> elements;

  @override
  String toString() => 'FieldValue.arrayUnion($elements)';
}

@immutable
class _ArrayRemoveFieldValue extends FieldValue {
  const _ArrayRemoveFieldValue(this.elements) : super._();

  final List<Object?> elements;

  @override
  String toString() => 'FieldValue.arrayRemove($elements)';
}

/// Internal helper accessors for FieldValue variants.
extension FieldValueInternal on FieldValue {
  bool get isServerTimestamp => this is _ServerTimestampFieldValue;
  bool get isDelete => this is _DeleteFieldValue;
  bool get isIncrement => this is _IncrementFieldValue;
  bool get isArrayUnion => this is _ArrayUnionFieldValue;
  bool get isArrayRemove => this is _ArrayRemoveFieldValue;

  num? get incrementOperand =>
      this is _IncrementFieldValue ? (this as _IncrementFieldValue).operand : null;

  List<Object?>? get arrayUnionElements =>
      this is _ArrayUnionFieldValue ? (this as _ArrayUnionFieldValue).elements : null;

  List<Object?>? get arrayRemoveElements =>
      this is _ArrayRemoveFieldValue ? (this as _ArrayRemoveFieldValue).elements : null;
}
