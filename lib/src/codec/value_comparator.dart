import 'dart:convert';

import 'package:googleapis/firestore/v1.dart' as v1;

import '../types/field_path.dart';

/// Orders Firestore values the way the backend does, so realtime query
/// results delivered over the Listen stream (which are unordered) can be
/// sorted locally according to the query's `orderBy` clauses.
///
/// Type order: null < boolean < number < timestamp < string < bytes <
/// reference < geopoint < array < map.
class FirestoreValueComparator {
  const FirestoreValueComparator._();

  static int _typeOrder(v1.Value? v) {
    if (v == null || v.nullValue != null) return 0;
    if (v.booleanValue != null) return 1;
    if (v.integerValue != null || v.doubleValue != null) return 2;
    if (v.timestampValue != null) return 3;
    if (v.stringValue != null) return 4;
    if (v.bytesValue != null) return 5;
    if (v.referenceValue != null) return 6;
    if (v.geoPointValue != null) return 7;
    if (v.arrayValue != null) return 8;
    if (v.mapValue != null) return 9;
    return 0;
  }

  /// Compares two Firestore [v1.Value]s.
  static int compare(v1.Value? a, v1.Value? b) {
    final ta = _typeOrder(a);
    final tb = _typeOrder(b);
    if (ta != tb) return ta.compareTo(tb);

    switch (ta) {
      case 0:
        return 0;
      case 1:
        return (a!.booleanValue! ? 1 : 0).compareTo(b!.booleanValue! ? 1 : 0);
      case 2:
        return _compareNumbers(_asNum(a!), _asNum(b!));
      case 3:
        return DateTime.parse(a!.timestampValue!)
            .compareTo(DateTime.parse(b!.timestampValue!));
      case 4:
        return _compareStrings(a!.stringValue!, b!.stringValue!);
      case 5:
        return _compareBytes(
            base64.decode(a!.bytesValue!), base64.decode(b!.bytesValue!));
      case 6:
        return compareReferences(a!.referenceValue!, b!.referenceValue!);
      case 7:
        final ga = a!.geoPointValue!;
        final gb = b!.geoPointValue!;
        final lat = (ga.latitude ?? 0).compareTo(gb.latitude ?? 0);
        if (lat != 0) return lat;
        return (ga.longitude ?? 0).compareTo(gb.longitude ?? 0);
      case 8:
        final la = a!.arrayValue!.values ?? const [];
        final lb = b!.arrayValue!.values ?? const [];
        for (var i = 0; i < la.length && i < lb.length; i++) {
          final c = compare(la[i], lb[i]);
          if (c != 0) return c;
        }
        return la.length.compareTo(lb.length);
      case 9:
        final ma = a!.mapValue!.fields ?? const {};
        final mb = b!.mapValue!.fields ?? const {};
        final ka = ma.keys.toList()..sort(_compareStrings);
        final kb = mb.keys.toList()..sort(_compareStrings);
        for (var i = 0; i < ka.length && i < kb.length; i++) {
          final kc = _compareStrings(ka[i], kb[i]);
          if (kc != 0) return kc;
          final vc = compare(ma[ka[i]], mb[kb[i]]);
          if (vc != 0) return vc;
        }
        return ka.length.compareTo(kb.length);
    }
    return 0;
  }

  static num _asNum(v1.Value v) =>
      v.integerValue != null ? int.parse(v.integerValue!) : v.doubleValue!;

  static int _compareNumbers(num a, num b) {
    final aNan = a is double && a.isNaN;
    final bNan = b is double && b.isNaN;
    if (aNan && bNan) return 0;
    if (aNan) return -1;
    if (bNan) return 1;
    return a.compareTo(b);
  }

  static int _compareStrings(String a, String b) {
    // Firestore orders strings by UTF-8 bytes; comparing code points matches
    // that for all well-formed strings.
    final ra = a.runes.iterator;
    final rb = b.runes.iterator;
    while (true) {
      final ha = ra.moveNext();
      final hb = rb.moveNext();
      if (!ha && !hb) return 0;
      if (!ha) return -1;
      if (!hb) return 1;
      if (ra.current != rb.current) return ra.current.compareTo(rb.current);
    }
  }

  static int _compareBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return a.length.compareTo(b.length);
  }

  /// Compares two document resource names segment by segment.
  static int compareReferences(String a, String b) {
    final sa = a.split('/');
    final sb = b.split('/');
    for (var i = 0; i < sa.length && i < sb.length; i++) {
      final c = _compareStrings(sa[i], sb[i]);
      if (c != 0) return c;
    }
    return sa.length.compareTo(sb.length);
  }

  /// Extracts the value at [path] from [doc], or null when missing.
  static v1.Value? valueAt(v1.Document doc, FieldPath path) {
    if (path.components.length == 1 && path.components.first == '__name__') {
      return v1.Value(referenceValue: doc.name);
    }
    Map<String, v1.Value>? fields = doc.fields;
    v1.Value? current;
    for (final segment in path.components) {
      if (fields == null) return null;
      current = fields[segment];
      if (current == null) return null;
      fields = current.mapValue?.fields;
    }
    return current;
  }
}
