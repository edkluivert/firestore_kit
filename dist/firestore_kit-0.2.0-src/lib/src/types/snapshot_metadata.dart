import 'package:meta/meta.dart';

/// Metadata about a snapshot, describing the state of the snapshot.
@immutable
class SnapshotMetadata {
  /// Creates a [SnapshotMetadata] instance.
  const SnapshotMetadata({
    required this.hasPendingWrites,
    required this.isFromCache,
  });

  /// Whether the snapshot contains the result of local writes that have not yet
  /// been committed to the backend.
  final bool hasPendingWrites;

  /// Whether the snapshot was created from cached data rather than guaranteed
  /// up-to-date server data.
  final bool isFromCache;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SnapshotMetadata &&
          runtimeType == other.runtimeType &&
          hasPendingWrites == other.hasPendingWrites &&
          isFromCache == other.isFromCache;

  @override
  int get hashCode => Object.hash(hasPendingWrites, isFromCache);

  @override
  String toString() =>
      'SnapshotMetadata(hasPendingWrites: $hasPendingWrites, isFromCache: $isFromCache)';
}
