import 'package:meta/meta.dart';

/// An immutable point representing a geographic location in Firestore.
///
/// Latitude ranges between -90 and 90 degrees inclusive.
/// Longitude ranges between -180 and 180 degrees inclusive.
@immutable
class GeoPoint {
  /// Creates a [GeoPoint] with the specified latitude and longitude.
  const GeoPoint(this.latitude, this.longitude)
      : assert(latitude >= -90 && latitude <= 90,
            'latitude must be between -90 and 90'),
        assert(longitude >= -180 && longitude <= 180,
            'longitude must be between -180 and 180');

  /// The latitude in degrees.
  final double latitude;

  /// The longitude in degrees.
  final double longitude;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeoPoint &&
          runtimeType == other.runtimeType &&
          latitude == other.latitude &&
          longitude == other.longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'GeoPoint(latitude=$latitude, longitude=$longitude)';
}
