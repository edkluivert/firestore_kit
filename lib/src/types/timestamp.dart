import 'package:meta/meta.dart';

/// A Timestamp represents a point in time independent of any time zone or calendar,
/// represented as seconds and fractions of seconds at nanosecond resolution in UTC
/// Epoch time.
@immutable
class Timestamp implements Comparable<Timestamp> {
  /// Creates a [Timestamp] from [seconds] and [nanoseconds].
  const Timestamp(this.seconds, this.nanoseconds)
      : assert(nanoseconds >= 0 && nanoseconds < 1000000000,
            'nanoseconds must be in range [0, 1000000000)'),
        assert(seconds >= -62135596800 && seconds <= 253402300799,
            'seconds must be in range [-62135596800, 253402300799]');

  /// Constructs a new [Timestamp] instance with the current time.
  factory Timestamp.now() {
    return Timestamp.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch);
  }

  /// Constructs a new [Timestamp] from a [DateTime].
  factory Timestamp.fromDate(DateTime date) {
    return Timestamp.fromMicrosecondsSinceEpoch(date.microsecondsSinceEpoch);
  }

  /// Constructs a new [Timestamp] from milliseconds since the Unix epoch.
  factory Timestamp.fromMillisecondsSinceEpoch(int milliseconds) {
    final int seconds = (milliseconds / 1000).floor();
    final int nanoseconds = ((milliseconds % 1000) * 1000000).toInt();
    return Timestamp(seconds, nanoseconds);
  }

  /// Constructs a new [Timestamp] from microseconds since the Unix epoch.
  factory Timestamp.fromMicrosecondsSinceEpoch(int microseconds) {
    final int seconds = (microseconds / 1000000).floor();
    final int nanoseconds = ((microseconds % 1000000) * 1000).toInt();
    return Timestamp(seconds, nanoseconds);
  }

  /// The number of seconds since the Unix epoch (1970-01-01T00:00:00Z).
  final int seconds;

  /// The non-negative fractions of a second at nanosecond resolution.
  final int nanoseconds;

  /// Returns the number of milliseconds since the Unix epoch.
  int get millisecondsSinceEpoch =>
      seconds * 1000 + (nanoseconds / 1000000).floor();

  /// Returns the number of microseconds since the Unix epoch.
  int get microsecondsSinceEpoch =>
      seconds * 1000000 + (nanoseconds / 1000).floor();

  /// Converts this [Timestamp] into a [DateTime] in UTC or local timezone.
  DateTime toDate({bool toLocal = false}) {
    final date =
        DateTime.fromMicrosecondsSinceEpoch(microsecondsSinceEpoch, isUtc: true);
    return toLocal ? date.toLocal() : date;
  }

  /// Converts this [Timestamp] to an RFC 3339 string with full nanosecond
  /// precision (`2024-01-01T00:00:00.123456789Z`), as Firestore expects.
  String toIso8601String() {
    final whole = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    final y = whole.year.toString().padLeft(4, '0');
    final mo = whole.month.toString().padLeft(2, '0');
    final d = whole.day.toString().padLeft(2, '0');
    final h = whole.hour.toString().padLeft(2, '0');
    final mi = whole.minute.toString().padLeft(2, '0');
    final sec = whole.second.toString().padLeft(2, '0');
    final frac = nanoseconds.toString().padLeft(9, '0');
    return '$y-$mo-${d}T$h:$mi:$sec.${frac}Z';
  }

  /// Parses an RFC 3339 timestamp, keeping nanosecond precision that
  /// [DateTime.parse] would truncate.
  static Timestamp parse(String input) {
    final match = RegExp(r'^(.*?)(?:\.(\d{1,9}))?(Z|[+-]\d{2}:?\d{2})$').firstMatch(input.trim());
    if (match == null) return Timestamp.fromDate(DateTime.parse(input));
    final base = DateTime.parse('${match.group(1)}${match.group(3)}');
    var seconds = base.millisecondsSinceEpoch ~/ 1000;
    if (base.millisecondsSinceEpoch < 0 && base.millisecondsSinceEpoch % 1000 != 0) seconds -= 1;
    final fraction = match.group(2);
    final nanos = fraction == null ? 0 : int.parse(fraction.padRight(9, '0'));
    return Timestamp(seconds, nanos);
  }

  @override
  int compareTo(Timestamp other) {
    if (seconds == other.seconds) {
      return nanoseconds.compareTo(other.nanoseconds);
    }
    return seconds.compareTo(other.seconds);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Timestamp &&
          runtimeType == other.runtimeType &&
          seconds == other.seconds &&
          nanoseconds == other.nanoseconds;

  @override
  int get hashCode => Object.hash(seconds, nanoseconds);

  @override
  String toString() =>
      'Timestamp(seconds=$seconds, nanoseconds=$nanoseconds)';
}
