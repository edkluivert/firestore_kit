// A minimal reader for Apple binary property lists (`bplist00`).
//
// Xcode converts XML plists to this format when it copies them into an app
// bundle, so the GoogleService-Info.plist an iOS app ships is binary even
// though the file downloaded from the Firebase console is XML.
// (Shared, byte for byte, with firestore_kit's lib/src/types/binary_plist.dart.)
import 'dart:convert';
import 'dart:typed_data';

/// Whether [bytes] start with the binary plist magic.
bool isBinaryPlist(Uint8List bytes) =>
    bytes.length > 8 && String.fromCharCodes(bytes.sublist(0, 6)) == 'bplist';

/// Parses a binary plist and returns its top-level object (a `Map<String,
/// Object?>` for a dictionary). Supports the types a configuration file uses:
/// strings, booleans, integers, reals, dates (as [DateTime]), data
/// (as [Uint8List]), arrays and dictionaries.
Object? parseBinaryPlist(Uint8List bytes) {
  if (!isBinaryPlist(bytes) || bytes.length < 40) {
    throw const FormatException('not a binary plist');
  }
  final data = ByteData.sublistView(bytes);
  final trailer = bytes.length - 32;
  final offsetIntSize = data.getUint8(trailer + 6);
  final objectRefSize = data.getUint8(trailer + 7);
  final numObjects = data.getUint64(trailer + 8);
  final topObject = data.getUint64(trailer + 16);
  final offsetTableOffset = data.getUint64(trailer + 24);
  if (numObjects <= 0 || offsetTableOffset + numObjects * offsetIntSize > bytes.length) {
    throw const FormatException('corrupt binary plist trailer');
  }

  int readSized(int position, int size) {
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | data.getUint8(position + i);
    }
    return value;
  }

  int objectOffset(int index) =>
      readSized(offsetTableOffset + index * offsetIntSize, offsetIntSize);

  Object? readObject(int index, int depth) {
    if (depth > 64) throw const FormatException('binary plist nesting too deep');
    var position = objectOffset(index);
    final marker = data.getUint8(position);
    final type = marker >> 4;
    var count = marker & 0x0F;
    position += 1;

    int readCount() {
      if (count != 0x0F) return count;
      final intMarker = data.getUint8(position);
      final size = 1 << (intMarker & 0x0F);
      position += 1;
      final value = readSized(position, size);
      position += size;
      return value;
    }

    switch (type) {
      case 0x0:
        switch (marker) {
          case 0x00:
            return null;
          case 0x08:
            return false;
          case 0x09:
            return true;
          default:
            return null;
        }
      case 0x1:
        final size = 1 << count;
        final value = readSized(position, size);
        if (size == 8 && (value & (1 << 63)) != 0) return value.toSigned(64);
        return value;
      case 0x2:
        final size = 1 << count;
        if (size == 4) return data.getFloat32(position);
        return data.getFloat64(position);
      case 0x3:
        final seconds = data.getFloat64(position);
        return DateTime.utc(2001).add(Duration(microseconds: (seconds * 1e6).round()));
      case 0x4:
        final length = readCount();
        return Uint8List.sublistView(bytes, position, position + length);
      case 0x5:
        final length = readCount();
        return ascii.decode(bytes.sublist(position, position + length), allowInvalid: true);
      case 0x6:
        final length = readCount();
        final units = <int>[];
        for (var i = 0; i < length; i++) {
          units.add(data.getUint16(position + i * 2));
        }
        return String.fromCharCodes(units);
      case 0x8:
        final size = count + 1;
        return readSized(position, size);
      case 0xA:
      case 0xC:
        final length = readCount();
        final items = <Object?>[];
        for (var i = 0; i < length; i++) {
          items.add(readObject(readSized(position + i * objectRefSize, objectRefSize), depth + 1));
        }
        return items;
      case 0xD:
        final length = readCount();
        final result = <String, Object?>{};
        for (var i = 0; i < length; i++) {
          final keyRef = readSized(position + i * objectRefSize, objectRefSize);
          final valueRef = readSized(position + (length + i) * objectRefSize, objectRefSize);
          final key = readObject(keyRef, depth + 1);
          result['$key'] = readObject(valueRef, depth + 1);
        }
        return result;
      default:
        throw FormatException('unsupported binary plist type 0x${type.toRadixString(16)}');
    }
  }

  return readObject(topObject, 0);
}

/// The string values of a plist, whether XML or binary: booleans become
/// `true` / `false`, numbers their decimal form, other types are skipped.
Map<String, String> plistStrings(Uint8List bytes) {
  if (isBinaryPlist(bytes)) {
    final top = parseBinaryPlist(bytes);
    final result = <String, String>{};
    if (top is Map) {
      for (final entry in top.entries) {
        final value = entry.value;
        if (value is String || value is bool || value is num) {
          result['${entry.key}'] = '$value';
        }
      }
    }
    return result;
  }
  return xmlPlistStrings(utf8.decode(bytes, allowMalformed: true));
}

/// The string, integer and boolean values of an XML plist's top-level dict.
Map<String, String> xmlPlistStrings(String xml) {
  final result = <String, String>{};
  final pattern = RegExp(
    r'<key>\s*([^<]+?)\s*</key>\s*<(string|integer|real|true|false)\s*/?>(?:([^<]*)</\2>)?',
    multiLine: true,
  );
  for (final match in pattern.allMatches(xml)) {
    final key = match.group(1)!;
    final type = match.group(2)!;
    final value = match.group(3);
    result[key] = switch (type) {
      'true' => 'true',
      'false' => 'false',
      _ => _unescapeXml(value ?? ''),
    };
  }
  return result;
}

String _unescapeXml(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
