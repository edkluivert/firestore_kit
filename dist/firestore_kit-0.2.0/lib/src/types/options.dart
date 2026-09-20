import 'package:meta/meta.dart';

/// An options object that configures how documents are retrieved using `get()`.
@immutable
class GetOptions {
  /// Creates a [GetOptions] instance.
  const GetOptions({this.source = Source.serverAndCache});

  /// The source to query. Defaults to [Source.serverAndCache].
  final Source source;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GetOptions &&
          runtimeType == other.runtimeType &&
          source == other.source;

  @override
  int get hashCode => source.hashCode;
}

/// The source from which a document or query is retrieved.
enum Source {
  /// Causes Firestore to try to retrieve an up-to-date document from the server.
  /// If the server is unreachable, attempts to return cache data.
  serverAndCache,

  /// Causes Firestore to avoid the cache, generating an error if the server is unreachable.
  server,

  /// Causes Firestore to immediately return a value from the cache, or an error if nothing is cached.
  cache,
}

/// An options object that configures the behavior of `set()` calls.
@immutable
class SetOptions {
  /// Creates a [SetOptions] instance with optional merge parameters.
  const SetOptions({this.merge, this.mergeFields});

  /// Whether to merge the provided data into existing documents.
  final bool? merge;

  /// The list of fields to merge.
  final List<Object>? mergeFields;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SetOptions &&
          runtimeType == other.runtimeType &&
          merge == other.merge &&
          mergeFields == other.mergeFields;

  @override
  int get hashCode => Object.hash(merge, mergeFields);
}
